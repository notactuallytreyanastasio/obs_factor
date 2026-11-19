// End to end: the real CLI, real sockets, against a local node:http stub via --base.
// Nothing here leaves 127.0.0.1.

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import http from 'node:http';
import { after, before, test } from 'node:test';
import { fileURLToPath } from 'node:url';

const CLI = fileURLToPath(new URL('../traffic.mjs', import.meta.url));
const FIXTURE = fileURLToPath(new URL('./fixture.json', import.meta.url));
const UA = 'obs-factor-traffic/1 (owner load test)';

let server;
let base;
let seen = [];
let handler = (req, res) => res.end('ok');

before(async () => {
  server = http.createServer((req, res) => {
    seen.push({ method: req.method, host: req.headers.host, url: req.url, ua: req.headers['user-agent'] });
    handler(req, res);
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => server.close());

function cli(args, { killAfterMs } = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [CLI, ...args], { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    if (killAfterMs) setTimeout(() => child.kill('SIGINT'), killAfterMs);
    child.on('close', (code) => resolve({ code, stdout, stderr }));
  });
}

const run = (...extra) => ['run', '--catalogue', FIXTURE, '--base', base, ...extra];

test('lab mode: catalogue (and mapped) Host headers, GET only, honest UA, count in range', async () => {
  seen = [];
  handler = (req, res) => res.end('ok');
  const r = await cli(run('--all', '--rps', '10', '--duration', '2', '--map', 'bobbby.online=blog.lab.test', '--json', '--seed', '5'));
  assert.equal(r.code, 0, r.stderr);
  const sum = JSON.parse(r.stdout);
  const allowed = new Set(['blog.lab.test', 'www.bobbby.online', 'links.bobbby.online', 'deciduous.dev']);
  assert.ok(seen.length >= 8 && seen.length <= 40, `received ${seen.length}`);
  assert.equal(sum.totals.sent, seen.length);
  assert.equal(sum.totals['2xx'], seen.length);
  assert.ok(seen.every((s) => allowed.has(s.host)), JSON.stringify([...new Set(seen.map((s) => s.host))]));
  assert.ok(!seen.some((s) => s.host === 'bobbby.online'), 'mapped host replaced');
  assert.ok(seen.every((s) => s.method === 'GET'));
  assert.ok(seen.every((s) => s.ua === UA));
  assert.ok(!seen.some((s) => s.url.startsWith('/dtree-ai')));
});

test('HEAD runs send HEAD', async () => {
  seen = [];
  const r = await cli(run('--site', 'blinks', '--rps', '10', '--duration', '1', '--method', 'head', '--quiet'));
  assert.equal(r.code, 0, r.stderr);
  assert.ok(seen.length > 0 && seen.every((s) => s.method === 'HEAD'));
  assert.match(r.stdout, /TOTAL/);
});

test('redirects off the catalogue are counted, never followed', async () => {
  seen = [];
  handler = (req, res) => { res.writeHead(302, { location: 'http://evil.example/steal' }); res.end(); };
  const r = await cli(run('--site', 'blinks', '--rps', '10', '--duration', '1', '--json', '--follow-redirects'));
  const sum = JSON.parse(r.stdout);
  assert.equal(sum.totals['3xx'], seen.length);
  assert.ok(seen.every((s) => s.host === 'links.bobbby.online'));
  assert.ok(sum.sites[0].redirectsRefused > 0);
});

test('a failing server: back-off announced, abort after 3, exit 3', async () => {
  seen = [];
  handler = (req, res) => { res.statusCode = 503; res.end('down'); };
  const r = await cli(run('--site', 'blinks', '--rps', '100', '--i-know-max-rps', '100', '--duration', '30', '--json'));
  assert.equal(r.code, 3, r.stderr);
  assert.match(r.stderr, /BACK-OFF 1\/3/);
  assert.match(r.stderr, /ABORT/);
  const sum = JSON.parse(r.stdout);
  assert.equal(sum.aborted, true);
  assert.ok(sum.elapsedS < 10, `aborted at ${sum.elapsedS}s`);
});

test('SIGINT stops cleanly and still prints the summary', async () => {
  seen = [];
  handler = (req, res) => res.end('ok');
  const r = await cli(run('--site', 'blinks', '--rps', '5', '--duration', '60', '--json'), { killAfterMs: 1500 });
  assert.equal(r.code, 130, r.stderr);
  const sum = JSON.parse(r.stdout);
  assert.match(sum.stopReason, /SIGINT/);
  assert.equal(sum.totals.sent, seen.length);
  assert.ok(sum.elapsedS < 5);
});

test('refusals: exit 2 and nothing sent', async () => {
  seen = [];
  const cases = [
    [run('--all', '--rps', '25'), /20 req\/s cap/],
    [run('--all', '--rps', '150', '--i-know-max-rps', '150'), /absolute ceiling of 100/],
    [run('--all', '--duration', 'Infinity'), /--duration must be/],
    [run('--all', '--duration', '0'), /--duration must be/],
    [['run', '--catalogue', FIXTURE, '--all', '--base', 'http://203.0.113.9/'], /must point at this machine/],
    [run('--site', 'blimp-blog', '--path', '/dtree-ai/generate'), /refused: .*avoid pattern \/dtree-ai\/\*/],
    [run('--site', 'blimp-blog', '--path', 'https://evil.example/'), /plain absolute path/],
    [run('--all', '--method', 'POST'), /only GET and HEAD/],
    [run('--rps', '1'), /--site <id>, --host <hostname> or --all/],
    [run('--host', 'evil.example'), /not in the catalogue/],
    [['run', '--catalogue', FIXTURE, '--all', '--map', 'bobbby.online=x.test'], /--map only works with --base/],
    [run('--all', '--url', 'https://evil.example/'), /Unknown option '--url'/],
  ];
  for (const [args, re] of cases) {
    const r = await cli(args);
    assert.equal(r.code, 2, `${args.join(' ')}\n${r.stderr}`);
    assert.match(r.stderr, re);
  }
  assert.equal(seen.length, 0);
});

test('dry-run prints the plan and sends nothing; list prints the catalogue', async () => {
  seen = [];
  const r = await cli(run('--site', 'blimp-blog,blinks', '--rps', '2', '--weights', 'blimp-blog=3,blinks=1', '--scenario', 'wave', '--dry-run', '--json'));
  assert.equal(r.code, 0, r.stderr);
  const p = JSON.parse(r.stdout);
  assert.deepEqual(p.sites.map((s) => [s.id, s.peakRps]), [['blimp-blog', 1.5], ['blinks', 0.5]]);
  assert.equal(p.averageRps, 1.1);
  assert.equal(p.sample.length, 10);
  const text = await cli(['run', '--catalogue', FIXTURE, '--all', '--dry-run']);
  assert.match(text.stdout, /DRY RUN/);
  assert.match(text.stdout, /https:\/\/bobbby\.online\//);
  const list = await cli(['list', '--catalogue', FIXTURE]);
  assert.match(list.stdout, /AVOID +\/dtree-ai\/\*/);
  assert.equal(seen.length, 0);
});
