import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { buildPlan, loadCatalogue } from '../lib/catalogue.mjs';
import { createRun, formatSummary } from '../lib/engine.mjs';
import { extractAssets, makeSender } from '../lib/http.mjs';
import { makeShape, mulberry32 } from '../lib/shape.mjs';
import { maxInAnyWindow, virtualClock } from './helpers.mjs';

const catalogue = loadCatalogue(fileURLToPath(new URL('./fixture.json', import.meta.url)));

/** Runs the engine on virtual time with a fake sender: respond(req, i) -> result (+ optional latency ms). */
async function simulate({ select = { all: true }, scenario = 'steady', rps = 5, durationS = 60, concurrency = 8, maxRps = 20,
  method = 'GET', followRedirects = false, map = new Map(), respond = () => ({ status: 200 }), latency = 20, seed = 1, stopAt } = {}) {
  const clock = virtualClock();
  const plan = buildPlan(catalogue, { ...select, visit: scenario === 'visit' });
  const sent = [];
  const logs = [];
  let inflight = 0;
  let maxInflight = 0;
  const send = async (req) => {
    const i = sent.length;
    sent.push({ ...req, t: clock.now() / 1000 });
    inflight++;
    maxInflight = Math.max(maxInflight, inflight);
    const r = respond(req, i);
    await clock.sleep(r.latency ?? latency);
    inflight--;
    return { ms: r.latency ?? latency, bytes: 0, ...r };
  };
  const run = createRun({
    catalogue, plan, scenario, shape: makeShape(scenario, rps), rps, maxRps, durationS, concurrency, method, followRedirects, map, timeoutMs: 10000,
  }, { now: clock.now, sleep: clock.sleep, random: mulberry32(seed), send, log: (l) => logs.push(l) });
  if (stopAt != null) clock.sleep(stopAt * 1000).then(() => run.stop('test stop'));
  const summary = await clock.runUntil(run.done);
  return { summary, sent, logs, maxInflight, endS: clock.now() / 1000 };
}

test('steady run: count near rps x duration, split across sites, only GET', async () => {
  const { summary, sent } = await simulate({ rps: 5, durationS: 60, select: { site: ['blimp-blog', 'blinks'], weights: 'blimp-blog=3,blinks=1' } });
  assert.ok(sent.length > 250 && sent.length < 350, `sent ${sent.length}`);
  assert.equal(summary.totals.sent, sent.length);
  assert.equal(summary.totals['2xx'], sent.length);
  assert.ok(sent.every((r) => r.method === 'GET'));
  assert.ok(sent.every((r) => catalogue.sites.some((s) => s.host === r.host)));
  const blog = summary.sites.find((s) => s.id === 'blimp-blog').sent;
  assert.ok(blog / sent.length > 0.68 && blog / sent.length < 0.82, `blog share ${blog / sent.length}`);
  assert.ok(sent.every((r) => r.t < 60));
  assert.equal(summary.aborted, false);
  assert.match(formatSummary(summary), /TOTAL/);
});

test('HEAD method passes through; nothing else can be sent', async () => {
  const { sent } = await simulate({ method: 'HEAD', durationS: 10 });
  assert.ok(sent.length > 0 && sent.every((r) => r.method === 'HEAD'));
  const send = makeSender();
  assert.throws(() => send({ method: 'POST', host: 'bobbby.online', path: '/' }), /only GET and HEAD/);
  assert.throws(() => send({ method: 'DELETE', host: 'bobbby.online', path: '/' }), /only GET and HEAD/);
  send.close();
});

test('the 20 req/s cap holds in every 1 s window of a full-rate run', async () => {
  const { sent } = await simulate({ rps: 20, durationS: 60, latency: 1, concurrency: 64 });
  assert.ok(maxInAnyWindow(sent.map((r) => r.t)) <= 20, `max ${maxInAnyWindow(sent.map((r) => r.t))}`);
  assert.ok(sent.length > 1000);
});

test('concurrency cap: never more in flight than allowed, extra slots skipped', async () => {
  const { summary, maxInflight } = await simulate({ rps: 10, durationS: 20, concurrency: 2, latency: 3000 });
  assert.equal(maxInflight, 2);
  assert.ok(summary.totals.skipped > 100, `skipped ${summary.totals.skipped}`);
});

test('wave and burst shapes come through the engine', async () => {
  const wave = await simulate({ scenario: 'wave', rps: 10, durationS: 60 });
  const early = wave.sent.filter((r) => r.t < 5).length;
  const mid = wave.sent.filter((r) => r.t >= 27.5 && r.t < 32.5).length;
  assert.ok(mid > early * 3, `early ${early} mid ${mid}`);
  const burst = await simulate({ scenario: 'burst', rps: 10, durationS: 60 });
  assert.ok(burst.sent.every((r) => r.t % 20 < 3 + 0.1), 'idle between bursts');
  assert.ok(burst.sent.length > 60 && burst.sent.length < 120, `burst sent ${burst.sent.length}`);
});

test('all 5xx: backs off to 10%, says so, aborts after 3 consecutive back-offs', async () => {
  const { summary, sent, logs } = await simulate({ rps: 10, durationS: 300, respond: () => ({ status: 503 }) });
  assert.equal(summary.aborted, true);
  assert.equal(summary.backoffs, 3);
  assert.match(summary.stopReason, /3 consecutive back-offs/);
  assert.equal(logs.filter((l) => l.startsWith('BACK-OFF')).length, 2);
  assert.ok(logs.some((l) => l.startsWith('ABORT')));
  // ~10 at full rate (~1 s), then 10 + 10 at 1 req/s (~20 s): far short of 300 s x 10/s
  assert.ok(sent.length < 50, `sent ${sent.length}`);
  assert.ok(summary.elapsedS > 10 && summary.elapsedS < 60, `elapsed ${summary.elapsedS}`);
  const afterFirst = sent.filter((r) => r.t > 3 && r.t < 13).length;
  assert.ok(afterFirst < 25, `reduced rate after back-off: ${afterFirst} in 10 s`);
});

test('connection errors count as bad; a recovering site gets its rate back', async () => {
  const { summary, logs } = await simulate({ rps: 10, durationS: 60, respond: (_, i) => (i < 12 ? { status: 0, error: 'ECONNREFUSED' } : { status: 200 }) });
  assert.equal(summary.aborted, false);
  assert.equal(summary.backoffs, 1);
  assert.ok(logs.some((l) => l.startsWith('recovered')));
  assert.ok(summary.totals.sent > 300, `full rate again: ${summary.totals.sent}`);
});

test('redirects: counted, never followed by default; with --follow-redirects only to catalogue hosts and not to avoided paths', async () => {
  const toEvil = await simulate({ durationS: 10, respond: () => ({ status: 301, location: 'https://evil.example/' }) });
  assert.ok(toEvil.sent.every((r) => r.host !== 'evil.example'));
  assert.equal(toEvil.summary.totals['3xx'], toEvil.sent.length);

  const off = await simulate({ durationS: 10, followRedirects: true, respond: (r) => (r.host === 'evil.example' ? { status: 200 } : { status: 302, location: 'https://evil.example/x' }) });
  assert.ok(off.sent.every((r) => r.host !== 'evil.example'));
  assert.ok(off.summary.sites.reduce((a, s) => a + s.redirectsRefused, 0) > 0);

  const avoidedLoc = await simulate({ durationS: 10, followRedirects: true, select: { site: ['blinks'] },
    respond: (r) => (r.host === 'links.bobbby.online' ? { status: 302, location: 'https://bobbby.online/dtree-ai/run' } : { status: 200 }) });
  assert.ok(avoidedLoc.sent.every((r) => !r.path.startsWith('/dtree-ai')));

  const ok = await simulate({ durationS: 10, followRedirects: true, select: { site: ['blinks'] },
    respond: (r) => (r.host === 'links.bobbby.online' ? { status: 301, location: 'https://bobbby.online/' } : { status: 200 }) });
  assert.ok(ok.sent.some((r) => r.host === 'bobbby.online' && r.path === '/' && r.method === 'GET'));

  const loop = await simulate({ durationS: 20, rps: 5, followRedirects: true, select: { site: ['blinks'] },
    respond: () => ({ status: 302, location: '/' }) });
  assert.ok(loop.summary.sites[0].redirectsRefused > 0, 'redirect loop stopped at 3 hops');
});

test('visit: page, then its same-origin assets (GET, at most 12, avoid rules applied), then think time', async () => {
  const imgs = Array.from({ length: 15 }, (_, i) => `<img src="/img/${i}.png">`).join('');
  const html = `<html><head><link rel="stylesheet" href="/app.css"><link rel="canonical" href="/canonical">
    <script src="https://cdn.other.example/x.js"></script><script src="/dtree-ai/widget.js"></script>
    <link rel=icon href=//bobbby.online/favicon.ico></head><body>${imgs}<img src="data:image/png;base64,AAA"></body></html>`;
  const { sent, summary } = await simulate({ scenario: 'visit', rps: 5, concurrency: 1, durationS: 20, select: { site: ['blimp-blog'] },
    respond: (r) => (r.path === '/' || r.path === '/posts' ? { status: 200, body: html, contentType: 'text/html' } : { status: 200 }) });
  assert.ok(sent.every((r) => r.method === 'GET'));
  assert.ok(sent.every((r) => ['bobbby.online', 'www.bobbby.online'].includes(r.host)), 'same origin only');
  assert.ok(!sent.some((r) => r.path.startsWith('/dtree-ai') || r.path === '/canonical'));
  const pages = sent.filter((r) => r.wantBody);
  assert.ok(pages.length >= 2 && pages.length === summary.visits);
  const firstVisit = sent.slice(0, sent.indexOf(pages[1]));
  assert.ok(pages[1].t - firstVisit.at(-1).t >= 2, 'a think pause of 2-5 s between visits');
  assert.equal(firstVisit.length, 13, '1 page + 12 assets');
  assert.deepEqual(firstVisit.slice(1, 3).map((r) => r.path), ['/app.css', '/favicon.ico']);
  assert.ok(maxInAnyWindow(sent.map((r) => r.t)) <= 20);
});

test('extractAssets resolves relative URLs and honours the mapped lab host', () => {
  const a = extractAssets('<script src="js/a.js"></script><img src="http://blog.lab.test/i.png"><img src="https://bobbby.online/j.png?v=1">',
    'http://blog.lab.test/posts/', new Set(['bobbby.online', 'blog.lab.test']));
  assert.deepEqual(a, ['/posts/js/a.js', '/i.png', '/j.png?v=1']);
});

test('stop() ends the run early with a summary', async () => {
  const { summary, endS } = await simulate({ durationS: 600, stopAt: 5 });
  assert.equal(summary.stopReason, 'test stop');
  assert.equal(summary.aborted, false);
  assert.ok(endS < 10, `ended at ${endS}`);
  assert.ok(summary.totals.sent > 10 && summary.totals.sent < 45);
});
