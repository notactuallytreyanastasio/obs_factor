// The run loop: paces arrivals, picks site and path, sends, records, backs off.
// Clock, sleep, randomness and the sender are injected (deps), so tests drive
// it on virtual time with a fake sender.

import { avoidIndex, avoided, pickSite, pickTarget } from './catalogue.mjs';
import { extractAssets } from './http.mjs';
import { Health, Pacer } from './shape.mjs';

const CLASSES = ['2xx', '3xx', '4xx', '5xx', 'err'];
const MAX_REDIRECT_HOPS = 3;
const MAX_ASSETS = 12;

/**
 * cfg:  { catalogue, plan, shape, scenario, rps, maxRps, durationS, concurrency,
 *         method, followRedirects, map, timeoutMs, think: [minS, maxS], health }
 * deps: { now() -> ms, sleep(ms) -> Promise, random() -> [0,1), send(req) -> Promise<result>,
 *         log(line), status?(line), statusEveryMs? }
 * Returns { done: Promise<summary>, stop(reason) }.
 */
export function createRun(cfg, deps) {
  const { plan, durationS, concurrency } = cfg;
  const map = cfg.map ?? new Map();
  const idx = avoidIndex(cfg.catalogue);
  const catHosts = new Set(cfg.catalogue.sites.map((s) => s.host));
  const reverse = new Map([...map].map(([prod, lab]) => [lab, prod]));
  const pacer = new Pacer({ shape: cfg.shape, random: deps.random, maxRps: cfg.maxRps });
  const health = new Health(cfg.health);
  const stats = new Stats(plan);
  const log = deps.log ?? (() => {});
  const t0 = deps.now();
  const elapsed = () => (deps.now() - t0) / 1000;

  let stopReason = null;
  let aborted = false;
  let finished = false;
  let wake;
  const stopped = new Promise((r) => { wake = r; });
  const stop = (reason = 'interrupted', isAbort = false) => {
    if (stopReason) return;
    stopReason = reason;
    aborted = isAbort;
    wake();
  };
  const nap = (ms) => Promise.race([deps.sleep(Math.max(0, ms)), stopped]);
  const inflight = new Set();
  const track = (p) => {
    inflight.add(p);
    p.then(() => inflight.delete(p), (e) => {
      inflight.delete(p);
      log(`internal error: ${e.message}`);
      stop(`internal error: ${e.message}`, true);
    });
    return p;
  };

  /** Waits for the next paced slot. false once the run is over. */
  async function gate() {
    if (stopReason) return false;
    pacer.multiplier = health.multiplier;
    const t = pacer.next(elapsed());
    if (t >= durationS) return false;
    await nap((t - elapsed()) * 1000);
    return !stopReason;
  }

  function onHealth(ev) {
    const pct = Math.round(ev.ratio * 100);
    if (ev.event === 'recover') {
      log(`recovered: ${pct}% bad in the last ${ev.n} responses; back to full rate`);
    } else if (ev.event === 'backoff') {
      log(`BACK-OFF ${ev.consecutive}/${health.maxBackoffs}: ${pct}% of the last ${ev.n} responses were 429/5xx/errors; rate cut to 10%`);
    } else {
      log(`ABORT: ${pct}% of the last ${ev.n} responses were 429/5xx/errors, ${ev.consecutive} back-offs in a row`);
      stop(`aborted after ${ev.consecutive} consecutive back-offs`, true);
    }
  }

  async function request(site, target, method, wantBody = false) {
    const epoch = health.epoch;
    stats.site(site.id).sent++;
    const res = await deps.send({ method, scheme: target.scheme, host: target.host, path: target.path, wantBody });
    stats.record(site.id, res);
    const ev = health.record(res, epoch);
    if (ev) onHealth(ev);
    return res;
  }

  /** Only with --follow-redirects, only to catalogue hosts, never to an avoided path, paced like everything else. */
  async function maybeFollow(site, target, res, hops) {
    if (!cfg.followRedirects || res.status < 300 || res.status >= 400 || !res.location) return;
    const s = stats.site(site.id);
    if (hops >= MAX_REDIRECT_HOPS) { s.redirectsRefused++; return; }
    let u;
    try { u = new URL(res.location, `${target.scheme}://${map.get(target.host) ?? target.host}${target.path}`); } catch { s.redirectsRefused++; return; }
    const h = u.hostname.toLowerCase();
    const host = catHosts.has(h) ? h : reverse.get(h);
    const path = u.pathname + u.search;
    if (!host || !/^https?:$/.test(u.protocol) || path.startsWith('//') || avoided(idx, host, path)) {
      s.redirectsRefused++;
      log(`not following ${res.status} from ${target.host}${target.path} to ${u.href}: off the catalogue or avoided`);
      return;
    }
    if (!(await gate())) return;
    const next = { host, scheme: u.protocol.slice(0, -1), path };
    const r2 = await request(site, next, 'GET');
    await maybeFollow(site, next, r2, hops + 1);
  }

  async function dispatcher() {
    while (await gate()) {
      if (inflight.size >= concurrency) { stats.skipped++; continue; }
      const site = pickSite(plan, deps.random());
      const target = pickTarget(site, deps.random());
      track((async () => {
        const res = await request(site, target, cfg.method);
        await maybeFollow(site, target, res, 0);
      })());
    }
  }

  async function visitor() {
    const [thinkMin, thinkMax] = cfg.think ?? [2, 5];
    while (!stopReason && elapsed() < durationS) {
      const site = pickSite(plan, deps.random());
      const page = pickTarget(site, deps.random());
      if (!(await gate())) break;
      stats.visits++;
      const res = await track(request(site, page, 'GET', true));
      const html = res.status >= 200 && res.status < 300 && res.body && (res.contentType == null || /html/i.test(res.contentType));
      if (html) {
        const hostHeader = map.get(page.host) ?? page.host;
        const assets = extractAssets(res.body, `${page.scheme}://${hostHeader}${page.path}`, new Set([page.host, hostHeader]), 500)
          .filter((p) => !avoided(idx, page.host, p))
          .slice(0, MAX_ASSETS);
        for (const path of assets) {
          if (!(await gate())) break;
          await track(request(site, { host: page.host, scheme: page.scheme, path }, 'GET'));
        }
      }
      await nap((thinkMin + deps.random() * (thinkMax - thinkMin)) * 1000);
    }
  }

  async function ticker() {
    if (!deps.status) return;
    let lastSent = 0;
    let lastT = 0;
    while (!finished) {
      await deps.sleep(deps.statusEveryMs ?? 1000);
      if (finished) break;
      const t = elapsed();
      const tot = stats.totals();
      deps.status(formatStatus(t, tot, (tot.sent - lastSent) / Math.max(1e-3, t - lastT), stats.recentPercentiles(), health.multiplier));
      lastSent = tot.sent;
      lastT = t;
    }
  }

  const done = (async () => {
    const visitors = Math.max(1, Math.min(concurrency, Math.ceil(cfg.rps)));
    const workers = cfg.scenario === 'visit' ? Array.from({ length: visitors }, visitor) : [dispatcher()];
    ticker();
    await Promise.race([Promise.all(workers), stopped]);
    if (!stopReason) await nap((durationS - elapsed()) * 1000);
    // Let in-flight requests land: a full timeout at the natural end, 2 s after a stop.
    await Promise.race([Promise.allSettled([...inflight]), deps.sleep(stopReason ? 2000 : (cfg.timeoutMs ?? 10000))]);
    finished = true;
    return stats.summary({
      scenario: cfg.scenario, rps: cfg.rps, durationS, elapsedS: elapsed(), aborted,
      stopReason, backoffs: health.total, visits: cfg.scenario === 'visit' ? stats.visits : undefined,
    });
  })();

  return { done, stop, stats, health, pacer };
}

// ---------------------------------------------------------------- stats

const RING = 10000;

class Stats {
  constructor(plan) {
    this.sites = new Map(plan.sites.map((s) => [s.id, {
      id: s.id, label: s.label, hosts: s.hosts, sent: 0, answered: 0, redirectsRefused: 0,
      ...Object.fromEntries(CLASSES.map((c) => [c, 0])), lat: [], errors: {},
    }]));
    this.skipped = 0;
    this.visits = 0;
    this.recent = [];
  }

  site(id) { return this.sites.get(id); }

  record(id, r) {
    const s = this.site(id);
    s.answered++;
    const c = r.status ? `${Math.min(5, Math.max(2, Math.floor(r.status / 100)))}xx` : 'err';
    s[c]++;
    if (r.status) {
      s.lat.push(r.ms);
      if (s.lat.length > RING) s.lat.shift();
      this.recent.push(r.ms);
      if (this.recent.length > 200) this.recent.shift();
    } else {
      s.errors[r.error ?? 'error'] = (s.errors[r.error ?? 'error'] ?? 0) + 1;
    }
  }

  totals() {
    const t = { sent: 0, ok: 0, ...Object.fromEntries(CLASSES.map((c) => [c, 0])) };
    for (const s of this.sites.values()) {
      t.sent += s.sent;
      for (const c of CLASSES) t[c] += s[c];
    }
    t.ok = t['2xx'] + t['3xx'];
    return t;
  }

  recentPercentiles() {
    return { p50: percentile(this.recent, 50), p95: percentile(this.recent, 95) };
  }

  summary(meta) {
    const sites = [...this.sites.values()].map((s) => ({
      id: s.id, label: s.label, hosts: s.hosts, sent: s.sent, ok: s['2xx'] + s['3xx'],
      ...Object.fromEntries(CLASSES.map((c) => [c, s[c]])),
      unanswered: s.sent - s.answered, redirectsRefused: s.redirectsRefused,
      p50Ms: round(percentile(s.lat, 50)), p95Ms: round(percentile(s.lat, 95)),
      maxMs: round(s.lat.length ? Math.max(...s.lat) : null), errors: s.errors,
    }));
    const tot = this.totals();
    const all = [...this.sites.values()].flatMap((s) => s.lat);
    return {
      ...meta, elapsedS: round(meta.elapsedS, 2),
      totals: { ...tot, skipped: this.skipped, p50Ms: round(percentile(all, 50)), p95Ms: round(percentile(all, 95)),
        actualRps: round(tot.sent / Math.max(1e-3, meta.elapsedS), 2) },
      sites,
    };
  }
}

export function percentile(arr, p) {
  if (!arr.length) return null;
  const s = [...arr].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.max(0, Math.ceil((p / 100) * s.length) - 1))];
}

const round = (x, d = 0) => (x == null ? null : Math.round(x * 10 ** d) / 10 ** d);
const ms = (x) => (x == null ? '-' : `${Math.round(x)}ms`);

export function formatStatus(t, tot, rps, pct, multiplier) {
  return `${t.toFixed(0).padStart(4)}s  sent ${tot.sent}  ok ${tot.ok}  `
    + `2xx ${tot['2xx']} 3xx ${tot['3xx']} 4xx ${tot['4xx']} 5xx ${tot['5xx']} err ${tot.err}  `
    + `${rps.toFixed(1)} req/s  p50 ${ms(pct.p50)} p95 ${ms(pct.p95)}`
    + (multiplier < 1 ? '  [BACKED OFF to 10%]' : '');
}

export function formatSummary(sum) {
  const head = ['site', 'sent', 'ok', '2xx', '3xx', '4xx', '5xx', 'err', 'p50', 'p95', 'max'];
  const row = (s) => [s.id, s.sent, s.ok, s['2xx'], s['3xx'], s['4xx'], s['5xx'], s.err, ms(s.p50Ms), ms(s.p95Ms), ms(s.maxMs)].map(String);
  const t = sum.totals;
  const rows = [head, ...sum.sites.map(row),
    ['TOTAL', t.sent, t.ok, t['2xx'], t['3xx'], t['4xx'], t['5xx'], t.err, ms(t.p50Ms), ms(t.p95Ms), ''].map(String)];
  const w = head.map((_, i) => Math.max(...rows.map((r) => r[i].length)));
  const line = (r) => r.map((c, i) => (i === 0 ? c.padEnd(w[i]) : c.padStart(w[i]))).join('  ');
  const out = [line(rows[0]), w.map((n) => '-'.repeat(n)).join('  '), ...rows.slice(1, -1).map(line), w.map((n) => '-'.repeat(n)).join('  '), line(rows.at(-1))];
  const notes = [`${sum.scenario}, ${sum.rps} req/s peak, ${sum.elapsedS}s of ${sum.durationS}s, ${t.actualRps} req/s actual`];
  if (sum.visits != null) notes.push(`${sum.visits} visits`);
  if (t.skipped) notes.push(`${t.skipped} slots skipped (concurrency cap)`);
  if (sum.backoffs) notes.push(`${sum.backoffs} back-off(s)`);
  const refused = sum.sites.reduce((a, s) => a + s.redirectsRefused, 0);
  if (refused) notes.push(`${refused} redirects not followed (off-catalogue/avoided/too many hops)`);
  const unanswered = sum.sites.reduce((a, s) => a + s.unanswered, 0);
  if (unanswered) notes.push(`${unanswered} requests still in flight at exit`);
  if (sum.stopReason) notes.push(sum.aborted ? `ABORTED: ${sum.stopReason}` : `stopped: ${sum.stopReason}`);
  const errs = sum.sites.flatMap((s) => Object.entries(s.errors).map(([e, n]) => `${s.id} ${e} x${n}`));
  if (errs.length) notes.push(`errors: ${errs.join(', ')}`);
  return [...out, '', ...notes].join('\n');
}
