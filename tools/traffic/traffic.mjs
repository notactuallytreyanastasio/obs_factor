#!/usr/bin/env node
// obs-factor traffic: light, real, owner-run traffic at chosen parts of the
// site, so the factory view shows activity. See README.md next to this file.
//
//   node tools/traffic/traffic.mjs list
//   node tools/traffic/traffic.mjs run --site blimp-blog --rps 2 --duration 60 --dry-run

import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { buildPlan, loadCatalogue, pickSite, pickTarget, UsageError } from './lib/catalogue.mjs';
import { createRun, formatSummary } from './lib/engine.mjs';
import { makeSender, parseBase, parseMap, USER_AGENT } from './lib/http.mjs';
import { checkRps, makeShape, mulberry32, resolveMaxRps } from './lib/shape.mjs';

const DEFAULT_CATALOGUE = fileURLToPath(new URL('./targets.json', import.meta.url));
const MAX_DURATION_S = 6 * 3600;

const HELP = `usage:
  traffic.mjs list [--catalogue FILE] [--json]
  traffic.mjs run  (--site ID ... | --host HOST ... | --all) [options]

selection (run)
  --site ID          factory node id; repeatable or comma list
  --host HOST        catalogue hostname; repeatable or comma list (with --site: both must match)
  --all              every site in the catalogue
  --kind KIND        page|asset|api|notfound|redirect; repeatable or comma list
  --path-match STR   only catalogue paths containing STR
  --path /P          request exactly these paths on the selected hosts (avoid rules still apply)

rate
  --rps N            peak total req/s across everything selected (default 1, cap 20)
  --weights a=3,b=1  split the rate unevenly between sites (default: evenly)
  --duration S       seconds, finite (default 60, at most ${MAX_DURATION_S})
  --concurrency N    in-flight cap (default 8); paced slots beyond it are skipped
  --scenario NAME    steady | burst | wave | visit (default steady)
  --period S         burst/wave cycle length (default burst 20, wave 60)
  --burst-len S      burst length within each period (default 3)
  --i-know-max-rps N raise the 20 req/s cap to N (absolute ceiling 100)

sending
  --method GET|HEAD  (default GET; visit always GETs)
  --timeout S        per request (default 10)
  --follow-redirects follow 3xx, at most 3 hops, only to catalogue hosts (default: count, don't follow)
  --base URL         lab mode: send everything to this loopback URL with the catalogue host as Host
  --map PROD=LAB     with --base: send PROD's requests with Host: LAB; repeatable or comma list
  --seed N           seed the randomness (reproducible plans and paths)

output
  --dry-run          print the plan and a sample of URLs; send nothing
  --json             final summary (or plan, or list) as JSON on stdout
  --quiet            no per-second status lines

exit: 0 done, 1 error, 2 refused/usage, 3 aborted by back-off, 130 interrupted`;

const OPTIONS = {
  catalogue: { type: 'string' }, json: { type: 'boolean' }, help: { type: 'boolean', short: 'h' },
  site: { type: 'string', multiple: true }, host: { type: 'string', multiple: true }, all: { type: 'boolean' },
  kind: { type: 'string', multiple: true }, 'path-match': { type: 'string' }, path: { type: 'string', multiple: true },
  rps: { type: 'string' }, weights: { type: 'string' }, duration: { type: 'string' }, concurrency: { type: 'string' },
  scenario: { type: 'string' }, period: { type: 'string' }, 'burst-len': { type: 'string' },
  'i-know-max-rps': { type: 'string' }, method: { type: 'string' }, timeout: { type: 'string' },
  'follow-redirects': { type: 'boolean' }, base: { type: 'string' }, map: { type: 'string', multiple: true },
  seed: { type: 'string' }, 'dry-run': { type: 'boolean' }, quiet: { type: 'boolean' },
};

function num(v, name, { def, min = -Infinity, max = Infinity, int = false } = {}) {
  if (v == null) return def;
  const n = Number(v);
  if (v === '' || !Number.isFinite(n) || n < min || n > max || (int && !Number.isInteger(n))) {
    throw new UsageError(`--${name} must be ${int ? 'an integer' : 'a finite number'} between ${min} and ${max}, got ${v}`);
  }
  return n;
}

/** Everything a run needs, validated. Exported for tests. */
export function configure(values) {
  const catalogue = loadCatalogue(values.catalogue ?? DEFAULT_CATALOGUE);
  const scenario = values.scenario ?? 'steady';
  const maxRps = resolveMaxRps(values['i-know-max-rps']);
  const rps = num(values.rps, 'rps', { def: 1, min: 0.001, max: 1e9 });
  checkRps(rps, maxRps);
  const durationS = num(values.duration, 'duration', { def: 60, min: 0.1, max: MAX_DURATION_S });
  const concurrency = num(values.concurrency, 'concurrency', { def: 8, min: 1, max: 64, int: true });
  const timeoutMs = num(values.timeout, 'timeout', { def: 10, min: 0.1, max: 60 }) * 1000;
  const method = (values.method ?? 'GET').toUpperCase();
  if (method !== 'GET' && method !== 'HEAD') throw new UsageError(`--method ${method}: only GET and HEAD are allowed`);
  const shape = makeShape(scenario, rps, {
    period: num(values.period, 'period', { min: 1, max: 86400 }),
    burstLen: num(values['burst-len'], 'burst-len', { min: 0.1, max: 86400 }),
  });
  const plan = buildPlan(catalogue, {
    all: values.all, site: values.site, host: values.host, kind: values.kind,
    pathMatch: values['path-match'], path: values.path, weights: values.weights, visit: scenario === 'visit',
  });
  const base = parseBase(values.base);
  const map = parseMap(values.map, new Set(catalogue.sites.map((s) => s.host)), base);
  const seed = values.seed == null ? (Date.now() ^ (process.pid << 16)) >>> 0 : num(values.seed, 'seed', { int: true, min: 0, max: 2 ** 32 - 1 });
  return { catalogue, plan, scenario, shape, rps, maxRps, durationS, concurrency, timeoutMs, method, base, map, seed,
    followRedirects: !!values['follow-redirects'], think: [2, 5] };
}

const urlOf = (cfg, t) => (cfg.base
  ? `${cfg.base.origin}${cfg.base.pathname.replace(/\/$/, '')}${t.path}  [Host: ${cfg.map.get(t.host) ?? t.host}]`
  : `${t.scheme}://${t.host}${t.path}`);

export function describePlan(cfg) {
  const avg = cfg.shape.average(cfg.durationS);
  const random = mulberry32(cfg.seed);
  const sample = Array.from({ length: 10 }, () => {
    const s = pickSite(cfg.plan, random());
    const t = pickTarget(s, random());
    return { site: s.id, kind: t.kind, url: urlOf(cfg, t) };
  });
  return {
    scenario: cfg.scenario, peakRps: cfg.rps, averageRps: Math.round(avg * 1000) / 1000, capRps: cfg.maxRps,
    durationS: cfg.durationS, expectedRequests: cfg.scenario === 'visit' ? null : Math.round(avg * cfg.durationS),
    concurrency: cfg.concurrency, method: cfg.method, followRedirects: cfg.followRedirects, timeoutS: cfg.timeoutMs / 1000,
    target: cfg.base ? { base: cfg.base.href, map: Object.fromEntries(cfg.map) } : 'real hosts from the catalogue',
    userAgent: USER_AGENT,
    sites: cfg.plan.sites.map((s) => ({
      id: s.id, label: s.label, hosts: s.hosts, share: Math.round(s.share * 1000) / 1000,
      peakRps: Math.round(s.share * cfg.rps * 1000) / 1000, averageRps: Math.round(s.share * avg * 1000) / 1000,
      paths: s.targets.length,
    })),
    sample, warnings: cfg.plan.warnings,
  };
}

function formatPlan(p) {
  const lines = [`DRY RUN: nothing will be sent`, `${p.scenario}: peak ${p.peakRps} req/s, average ~${p.averageRps} req/s for ${p.durationS}s`
    + (p.expectedRequests != null ? ` (~${p.expectedRequests} requests)` : ' (visit: real rate depends on pages, assets and think time; at most the peak)'),
  `cap ${p.capRps} req/s, concurrency ${p.concurrency}, ${p.method}, timeout ${p.timeoutS}s, redirects ${p.followRedirects ? 'followed (catalogue hosts only)' : 'counted, not followed'}`,
  `target: ${typeof p.target === 'string' ? p.target : `${p.target.base} with catalogue Host headers${Object.keys(p.target.map).length ? `, mapped ${JSON.stringify(p.target.map)}` : ''}`}`, ''];
  for (const s of p.sites) lines.push(`  ${s.id.padEnd(20)} ${String(Math.round(s.share * 100)).padStart(3)}%  peak ${s.peakRps} req/s  avg ${s.averageRps} req/s  ${s.paths} paths  ${s.hosts.join(', ')}`);
  lines.push('', 'sample:', ...p.sample.map((x) => `  ${x.site.padEnd(20)} ${x.kind.padEnd(8)} ${x.url}`));
  for (const w of p.warnings) lines.push(`warning: ${w}`);
  return lines.join('\n');
}

function list(values, out) {
  const cat = loadCatalogue(values.catalogue ?? DEFAULT_CATALOGUE);
  if (values.json) return out.write(`${JSON.stringify(cat, null, 2)}\n`);
  const lines = [];
  for (const s of cat.sites) {
    lines.push(`${s.id}  (${s.label})  ${s.scheme}://${s.host}`);
    for (const p of s.paths) lines.push(`    ${p.kind.padEnd(8)} w${String(p.weight).padEnd(3)} ${p.path}${p.note ? `   ${p.note}` : ''}`);
    for (const a of s.avoid) lines.push(`    AVOID          ${a.pattern}${a.why ? `   ${a.why}` : ''}`);
  }
  out.write(`${lines.join('\n')}\n`);
}

export async function main(argv, io = { stdout: process.stdout, stderr: process.stderr }) {
  const { stdout, stderr } = io;
  let parsed;
  try {
    parsed = parseArgs({ args: argv, options: OPTIONS, allowPositionals: true, strict: true });
  } catch (e) {
    stderr.write(`${e.message}\n\n${HELP}\n`);
    return 2;
  }
  const { values, positionals } = parsed;
  const cmd = positionals[0];
  if (values.help || !cmd) { stdout.write(`${HELP}\n`); return cmd || values.help ? 0 : 2; }
  try {
    if (cmd === 'list') { list(values, stdout); return 0; }
    if (cmd !== 'run') throw new UsageError(`unknown command "${cmd}" (list | run)`);
    const cfg = configure(values);
    if (values['dry-run']) {
      const p = describePlan(cfg);
      stdout.write(values.json ? `${JSON.stringify(p, null, 2)}\n` : `${formatPlan(p)}\n`);
      return 0;
    }
    return await execute(cfg, values, io);
  } catch (e) {
    if (e instanceof UsageError) { stderr.write(`traffic: ${e.message}\n`); return 2; }
    stderr.write(`traffic: ${e.stack || e.message}\n`);
    return 1;
  }
}

async function execute(cfg, values, { stdout, stderr }) {
  for (const w of cfg.plan.warnings) stderr.write(`warning: ${w}\n`);
  const hosts = [...new Set(cfg.plan.sites.flatMap((s) => s.hosts))];
  stderr.write(cfg.base
    ? `lab mode: ${cfg.base.href} with Host ${hosts.map((h) => cfg.map.get(h) ?? h).join(', ')}\n`
    : `REAL traffic to ${hosts.join(', ')}\n`);
  stderr.write(`${cfg.scenario} at ${cfg.rps} req/s peak for ${cfg.durationS}s (seed ${cfg.seed}); Ctrl-C stops and prints the summary\n`);
  const send = makeSender({ base: cfg.base, map: cfg.map, timeoutMs: cfg.timeoutMs, concurrency: cfg.concurrency });
  const showStatus = !values.quiet && stderr.isTTY;
  const run = createRun(cfg, {
    now: () => performance.now(),
    sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
    random: mulberry32(cfg.seed),
    send,
    log: (l) => stderr.write(`${l}\n`),
    status: showStatus ? (l) => stderr.write(`${l}\n`) : null,
  });
  let interrupts = 0;
  const onSigint = () => {
    if (++interrupts > 1) { stderr.write('second Ctrl-C: exiting now\n'); process.exit(130); }
    stderr.write('\nstopping: letting in-flight requests land (Ctrl-C again to quit now)\n');
    run.stop('interrupted (SIGINT)');
  };
  process.on('SIGINT', onSigint);
  const sum = await run.done;
  process.off('SIGINT', onSigint);
  send.close();
  stdout.write(values.json ? `${JSON.stringify(sum, null, 2)}\n` : `\n${formatSummary(sum)}\n`);
  if (sum.aborted) return 3;
  return sum.stopReason ? 130 : 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main(process.argv.slice(2)).then((code) => process.exit(code));
}
