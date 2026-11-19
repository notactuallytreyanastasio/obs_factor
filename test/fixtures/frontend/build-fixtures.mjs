// Builds the frontend fixtures (box.json, bad-day.json) to docs/contract.md.
// Test tooling only: nothing under priv/static reads these.
//
//   node test/fixtures/frontend/build-fixtures.mjs
//
// Numbers marked "capture" come from test/fixtures/box/capture.json
// (2026-11-18T22:34:47Z). The rest are hand-picked to the same scale: the
// capture has stats for five containers and no Caddy metrics.

import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const AT = "2026-11-18T22:34:47Z";
const MB = 1024 * 1024;
const GB = 1024 * MB;

const HOST = {
  cores: 4, // capture
  cpu_used_cores: 0.076, // capture: /proc/stat diff
  load1: 0.04, // capture
  mem_used_bytes: 4786737152, // capture: MemTotal - MemAvailable
  mem_total_bytes: 16368988160, // capture
  disk_used_bytes: 160970244096 - 5112029 * 4096, // capture: total - f_bavail*frsize = 87%
  disk_total_bytes: 160970244096, // capture
};

const platforms = [
  { id: "outside", label: "outside" },
  { id: "main", label: "bobbby.online" },
  { id: "host", label: "the box" },
  { id: "static", label: "static sites" },
];

// app/relay/proxy/db nodes: [id, label, kind, service, pos, hosts, via, databases, probe, mem, cpu, upDays, memLimit]
const apps = [
  ["caddy", "Caddy", "proxy", "caddy", [0, 2], [], [], [], null, 30470144, 0.0018, 2, null],
  ["blimp-blog", "Blimp blog", "app", "blimp-blog", [1, 1], ["bobbby.online", "www.bobbby.online"], [], ["blog_prod"], "http://blimp-blog:4100/", 361529344, 0.0067, 13, 1610612736],
  ["app", "Phoenix blog", "app", "app", [1, 2], ["old.bobbby.online"], ["bobbby.online/hotel-carbon*", "bobbby.online/tennis-potatoes*"], ["blog_prod"], "http://app:4000/", 318140416, 0.0037, 9, null],
  ["blinks", "Blinks", "app", "blinks", [1, 3], ["links.bobbby.online", "bobbbys.link", "www.bobbbys.link"], [], ["blinks_backend_prod"], "http://blinks:4000/", 212 * MB, 0.004, 90, null],
  ["marginalia", "Marginalia", "app", "marginalia", [2, 0], ["marginalia.bobbby.online"], [], ["marginalia_prod"], "http://marginalia:4000/", 251 * MB, 0.009, 56, null],
  ["tyler", "Tyler", "app", "tyler", [2, 1], ["tyler.bobbby.online"], [], ["tyler_prod"], "http://tyler:4000/", 148 * MB, 0.002, 42, null],
  ["dave", "Dave", "app", "dave", [2, 3], ["dave.bobbby.online"], [], ["dave_prod"], "http://dave:4000/", 139 * MB, 0.0015, 28, null],
  ["nathan", "Gifmaker", "app", "nathan", [2, 4], ["gifmaker.bobbby.online"], [], ["nathan_for_us_prod"], "http://nathan:4001/", 302 * MB, 0.012, 92, null],
  ["deciduous-mcp", "deciduous MCP", "app", "deciduous-mcp", [1, 0], [], ["bobbby.online/deciduous-mcp/*"], ["deciduous_mcp_prod"], "http://deciduous-mcp:4000/", 188 * MB, 0.006, 49, null],
  ["skyfeed", "Sky feeds", "app", "skyfeed", [1, 4], ["bskymapfeeds.bobbby.online"], [], [], "http://skyfeed:4000/", 176 * MB, 0.021, 8, null],
  ["dtree-ai", "dtree AI", "app", "dtree-ai", [3, 0], [], ["bobbby.online/dtree-ai/*"], [], "http://dtree-ai:8080/health", 61 * MB, 0.0004, 14, null],
  ["soldat", "Arena", "app", "soldat", [3, 1], [], ["bobbby.online/arena/*"], [], "http://soldat:8901/", 118 * MB, 0.031, 61, null],
  ["slides-relay", "Slides relay", "relay", "slides-relay", [3, 3], [], ["slides.bobbby.online/relay"], [], null, 9658368, 0.0, 120, null],
  ["skee-relay", "Skee relay", "relay", "skee-relay", [3, 4], [], ["bobbby.online/skee-host/*"], [], null, 41 * MB, 0.0002, 15, null],
  ["lumines", "Lumines relay", "relay", "lumines", [2, 5], [], ["lumines.bobbby.online/ws"], [], null, 44 * MB, 0.0003, 61, null],
  ["db", "Postgres", "db", "db", [3, 2], [], [], [], null, 771993600, 0.011, 133, null],
];

// rps per host, hand-picked; avg_ms hand-picked.
const RPS = {
  "bobbby.online": [3.2, 0.0, 8.1], "www.bobbby.online": [0.1, 0, 2.0],
  "old.bobbby.online": [0.08, 0, 21.0], "links.bobbby.online": [0.4, 0, 14.2],
  "bobbbys.link": [0.2, 0, 11.8], "www.bobbbys.link": [0.01, 0, 3.0],
  "marginalia.bobbby.online": [0.3, 0.0, 33.0], "tyler.bobbby.online": [0.05, 0, 18.0],
  "dave.bobbby.online": [0.02, 0, 25.0], "gifmaker.bobbby.online": [0.6, 0.02, 140.0],
  "bskymapfeeds.bobbby.online": [1.8, 0, 46.0],
  "deciduous.dev": [0.4, 0, 1.2], "www.deciduous.dev": [0.02, 0, 1.0],
  "soldat.bobbby.online": [0.05, 0, 1.1], "downloader.bobbby.online": [0.0, 0, null],
  "donny.bobbby.online": [0.01, 0, 0.9], "blimp.bobbby.online": [0.1, 0, 1.3],
  "gaming.bobbby.online": [0.03, 0, 1.0], "slides.bobbby.online": [0.02, 0, 1.4],
  "lumines.bobbby.online": [0.04, 0, 1.2], "phishjamexplorer.com": [0.7, 0, 2.2],
  "www.phishjamexplorer.com": [0.02, 0, 1.0], "padmac.bobbby.online": [0.0, 0, null],
};

// commits/s per database (hand-picked); size from capture pg_stat_database.
const DBS = {
  blog_prod: [2594723507, 2.1], nathan_for_us_prod: [1413494451, 0.4],
  archive_classifier_prod: [39237299, 0.1], blinks_backend_prod: [8787635, 0.1],
  marginalia_prod: [67385011, 5.4], deciduous_mcp_prod: [185169587, 1.2],
  tyler_prod: [83818163, 0.08], dave_prod: [8836787, 0.03], postgres: [7689907, 0.0],
};

// static: [id, label, site, pos, hosts, bytes]
const statics = [
  ["site-deciduous", "deciduous.dev", "deciduous", [0, 0], ["deciduous.dev", "www.deciduous.dev"], 48 * MB],
  ["site-soldat", "Soldat landing", "soldat-landing", [1, 0], ["soldat.bobbby.online"], 6 * MB],
  ["site-downloader", "Downloader", "downloader", [2, 0], ["downloader.bobbby.online"], 2 * MB],
  ["site-donny", "Donny", "donny", [0, 1], ["donny.bobbby.online"], 31 * MB],
  ["site-blimp", "Blimp docs", "blimp", [1, 1], ["blimp.bobbby.online"], 12 * MB],
  ["site-gaming", "Gaming", "gaming", [2, 1], ["gaming.bobbby.online"], 410 * MB],
  ["site-slides", "Slides", "slides", [0, 2], ["slides.bobbby.online"], 88 * MB],
  ["site-lumines", "Lumines", "lumines", [1, 2], ["lumines.bobbby.online"], 23 * MB],
  ["site-phstats", "Phish jam explorer", "phstats", [2, 2], ["phishjamexplorer.com", "www.phishjamexplorer.com"], 1.4 * GB],
  ["site-padmac", "padmac", "padmac", [0, 3], ["padmac.bobbby.online"], 3 * MB],
];

// Which building the browser draws for a node (docs/contract.md, Per-subdomain detail).
const STYLE = {
  "blimp-blog": "press", app: "foundry", blinks: "switchyard", marginalia: "library",
  dave: "conservatory", nathan: "studio", "deciduous-mcp": "greenhouse", skyfeed: "observatory",
  "dtree-ai": "lab", soldat: "arena", "slides-relay": "stage", "skee-relay": "arcade", lumines: "arcade",
  "site-deciduous": "greenhouse", "site-soldat": "arena", "site-blimp": "press", "site-gaming": "arcade",
  "site-slides": "stage", "site-lumines": "arcade", "site-phstats": "conservatory",
};

// Share of each host's requests by status class, hand-picked: [3xx, 4xx, other]; 5xx is the
// err column of RPS, the rest is 2xx. Bytes per response hand-picked per host.
const MIX = {
  "bobbby.online": [0.06, 0.03, 0.01, 15000], "old.bobbby.online": [0.2, 0.05, 0, 9000],
  "links.bobbby.online": [0.5, 0.04, 0, 600], "bobbbys.link": [0.9, 0.05, 0, 300],
  "gifmaker.bobbby.online": [0.02, 0.02, 0.03, 220000], "bskymapfeeds.bobbby.online": [0, 0.01, 0, 4200],
  "marginalia.bobbby.online": [0.05, 0.02, 0.04, 11000], "phishjamexplorer.com": [0.02, 0.08, 0, 64000],
  "deciduous.dev": [0.03, 0.1, 0, 18000],
};
const IN_FLIGHT = { "bobbby.online": 2, "gifmaker.bobbby.online": 1, "marginalia.bobbby.online": 3, "bskymapfeeds.bobbby.online": 1 };
const CLASSES = ["2xx", "3xx", "4xx", "5xx", "other"];
const sumCodes = (rows) => rows.length === 0 || rows.some((r) => r.codes == null) ? null
  : Object.fromEntries(CLASSES.map((k) => [k, r2(rows.reduce((a, r) => a + r.codes[k], 0))]));

// Access log (docs/contract.md, Access log): busiest paths over 300 s, hand-picked.
// [path, count, errors, p95_ms]
const ROUTES = {
  "blimp-blog": [["/", 412, 0, 14.2], ["/post/the-factory-must-grow", 138, 0, 11.0], ["/feed.xml", 96, 0, 6.1], ["/pinball", 71, 0, 9.4], ["/static/app.css", 64, 0, 1.2], ["/gallery", 40, 0, 88.0], ["/__nope", 9, 0, 0.9]],
  app: [["/hotel-carbon", 14, 0, 31.0], ["/", 9, 0, 240.0], ["/tennis-potatoes", 4, 0, 44.0]],
  marginalia: [["/", 48, 0, 30.1], ["/cases", 22, 3, 410.0], ["/assets/app.js", 20, 0, 2.2]],
  nathan: [["/gifs", 120, 4, 180.0], ["/", 44, 0, 61.0], ["/robots.txt", 16, 2, 1.0]],
  skyfeed: [["/xrpc/app.bsky.feed.getFeedSkeleton", 510, 0, 52.0], ["/", 28, 0, 9.0]],
  soldat: [["/arena/", 66, 0, 4.0], ["/arena/state.json", 240, 0, 2.1]],
  "dtree-ai": [["/dtree-ai/health", 12, 0, 1.4]],
  "deciduous-mcp": [["/deciduous-mcp/health", 30, 0, 2.0], ["/deciduous-mcp/mcp", 18, 0, 620.0]],
  "skee-relay": [["/skee-host/health", 6, 0, 1.1]],
  "site-phstats": [["/", 150, 0, 2.4], ["/assets/index.js", 60, 0, 3.0]],
  "site-deciduous": [["/", 90, 0, 1.3], ["/docs/", 30, 0, 1.1], ["/nope", 12, 0, 0.8]],
};
const LAT = (rows) => {
  if (!rows?.length) return null;
  const count = rows.reduce((a, r) => a + r[1], 0);
  const p95 = Math.max(...rows.map((r) => r[3]));
  return { p50_ms: r2(p95 * 0.12), p95_ms: p95, p99_ms: r2(p95 * 2.3), count };
};
const routeRows = (id, ok) => !ok ? null : (ROUTES[id] ?? []).map(([path, count, errors, p95_ms]) => ({ path, count, rps: r2(count / 300), errors, p95_ms }));
const viaOf = (id, ok) => {
  if (!ok) return { via_rps: null, via_codes: null };
  const n = (ROUTES[id] ?? []).reduce((a, r) => a + r[1], 0) / 300;
  return { via_rps: r2(n), via_codes: { "2xx": r2(n * 0.97), "3xx": 0, "4xx": r2(n * 0.03), "5xx": 0, other: 0 } };
};

// Reports (docs/contract.md, Reports): what a sub-app says about its own inside. Hand-picked.
const lv = (name, route, sessions, mem) => ({
  kind: "liveview", name, route, count: sessions.length,
  gauges: { memory: sessions.length * mem, message_queue: 0 },
  members: sessions.map(([label, mins, events], i) => ({
    id: `${name.length.toString(16)}${i}a${mins}`, label, since: new Date(Date.parse(AT) - mins * 60000).toISOString().replace(/\.\d+Z$/, "Z"),
    gauges: { memory: Math.round(mem * (1.3 - i * 0.2)), message_queue: 0 }, counters: { events },
  })),
});
const beam = (app, phoenix, live, memMB, procs, up, units, streams) => ({
  ok: true, error: null, at: AT,
  runtime: {
    kind: "beam", versions: { otp: "28", elixir: "1.19.5", phoenix, phoenix_live_view: live, app: "0.1.0" }, uptime_s: up * 86400,
    gauges: { "memory.total": memMB * MB, "memory.processes": Math.round(memMB * 0.34 * MB), "memory.binary": Math.round(memMB * 0.18 * MB),
      "memory.ets": Math.round(memMB * 0.09 * MB), "memory.code": Math.round(memMB * 0.3 * MB), "memory.atom": Math.round(memMB * 0.02 * MB),
      "process.count": procs, "process.limit": 1048576, "port.count": 14 + units.length, "atom.count": 31240, "atom.limit": 1048576,
      "ets.count": 61, run_queue: 0, "schedulers.online": 4, "scheduler.utilization": 0.012 },
    rates: { reductions: 48211.4, "gc.count": 3.2, "io.in_bytes": 5120.0, "io.out_bytes": 20480.0, context_switches: 310.5 },
  },
  units,
  streams: streams.map(([kind, name, count, rate, err_rate, avg_ms]) => ({ kind, name, count, rate, err_rate, avg_ms })),
  truncated: { units: 0, members: 0, streams: 0 },
});
const INSIDE = {
  app: beam("blog", "1.7.19", "1.0.3", 212, 1420, 9, [
    lv("BlogWeb.HotelCarbonLive", "/hotel-carbon", [["/hotel-carbon", 42, 310], ["/hotel-carbon", 3, 12]], 410000),
    lv("BlogWeb.TennisPotatoesLive", "/tennis-potatoes", [["/tennis-potatoes", 8, 55]], 620000),
    lv("BlogWeb.PostLive.Show", "/post/:slug", [["/post/the-factory-must-grow", 1, 2], ["/post/pinball", 17, 4], ["/post/blimp", 60, 1]], 180000),
    lv("BlogWeb.CursorTrackerLive", "/cursor-tracker", [["/cursor-tracker", 5, 940]], 240000),
  ], [
    ["liveview.event", "BlogWeb.CursorTrackerLive#move", 88120, 3.1, 0, 0.4], ["db.query", "Blog.Repo", 991200, 2.1, 0, 1.8],
    ["http.route", "GET /hotel-carbon", 4410, 0.05, 0, 31.0], ["liveview.event", "BlogWeb.HotelCarbonLive#place", 3120, 0.04, 0, 6.2],
    ["outbound.http", "api.deepseek.com", 412, 0.01, 0.002, 1840.0], ["outbound.http", "api.github.com", 2880, 0.003, 0, 210.0],
    ["liveview.mount", "BlogWeb.PostLive.Show", 9120, 0.02, 0, 12.0], ["channel.join", "room:*", 120, 0, 0, null],
    ["custom", "work_log.poll", 2880, 0.003, 0, 220.0],
  ]),
  marginalia: beam("marginalia", "1.8.14", "1.2.11", 168, 980, 56, [
    lv("MarginaliaWeb.CaseLive.Show", "/cases/:id", [["/cases/41", 12, 31], ["/cases/7", 2, 3]], 520000),
    lv("MarginaliaWeb.StackLive", "/stacks", [["/stacks", 30, 88]], 330000),
  ], [
    ["db.query", "Marginalia.Repo", 2412000, 5.4, 0, 2.4], ["http.route", "GET /cases", 9120, 0.07, 0.01, 410.0],
    ["outbound.http", "api.deepseek.com", 1210, 0.02, 0, 2210.0], ["liveview.event", "MarginaliaWeb.CaseLive.Show#annotate", 4410, 0.03, 0, 9.1],
  ]),
  nathan: beam("nathan_for_us", "1.7.21", "1.0.17", 244, 1105, 92, [
    lv("NathanForUsWeb.GifLive", "/gifs/:id", [["/gifs/8812", 1, 6]], 2100000),
  ], [
    ["http.route", "GET /gifs", 88120, 0.4, 0.013, 180.0], ["db.query", "NathanForUs.Repo", 412000, 0.4, 0, 12.0],
    ["custom", "gif.rendered", 5120, 0.02, 0.001, 3400.0],
  ]),
  blinks: beam("blinks_backend", "1.8.9", "1.2.7", 96, 610, 90, [], [
    ["http.route", "GET /", 44100, 0.4, 0, 14.0], ["db.query", "BlinksBackend.Repo", 120400, 0.1, 0, 1.1],
  ]),
  dave: { ok: false, error: "connect ECONNREFUSED dave:9568", at: null, runtime: null, units: null, streams: null, truncated: null },
};

const fmtBytes = (b) => {
  if (b == null) return "-";
  const u = ["B", "KB", "MB", "GB", "TB"]; let i = 0; let v = b;
  while (v >= 1000 && i < u.length - 1) { v /= 1024; i++; }
  return `${v < 10 && i > 0 ? v.toFixed(1) : Math.round(v)} ${u[i]}`;
};
const r2 = (x) => (x == null ? null : Math.round(x * 1000) / 1000);

function build(bad) {
  const caddyOk = !bad;
  const sources = {
    docker: { ok: true, at: AT, error: null },
    caddy: caddyOk ? { ok: true, at: AT, error: null }
      : { ok: false, at: null, error: "GET http://caddy:9180/metrics: connection refused (econnrefused)" },
    postgres: { ok: true, at: AT, error: null },
    host: { ok: true, at: AT, error: null },
    probes: { ok: true, at: AT, error: null },
    sites: { ok: true, at: AT, error: null },
    reports: { ok: true, at: AT, error: null },
    access: bad ? { ok: false, at: null, error: "cannot open /caddy-logs/access.log: no such file or directory" } : { ok: true, at: AT, error: null },
  };
  const accessOk = !bad;
  const host = { ...HOST };
  if (bad) { host.cpu_used_cores = 1.31; host.load1 = 2.4; host.mem_used_bytes = 9.4 * GB; }

  const hostRows = (hosts) => hosts.map((h) => {
    const [rps, err, ms] = RPS[h] ?? [0, 0, null];
    if (!caddyOk) return { host: h, rps: null, err_rps: null, avg_ms: null, codes: null, in_bps: null, out_bps: null, in_flight: null };
    const [m3, m4, mo, size] = MIX[h] ?? [0.03, 0.03, 0, 5000];
    const rest = rps - err;
    const codes = { "2xx": r2(rest * (1 - m3 - m4 - mo)), "3xx": r2(rest * m3), "4xx": r2(rest * m4), "5xx": r2(err), other: r2(rest * mo) };
    return { host: h, rps, err_rps: err, avg_ms: ms, codes, in_bps: r2(rps * 420), out_bps: r2(rps * size), in_flight: IN_FLIGHT[h] ?? 0 };
  });
  const sumRps = (rows) => rows.length === 0 ? null
    : rows.some((r) => r.rps == null) ? null : r2(rows.reduce((a, r) => a + r.rps, 0));

  const nodes = [];
  const edges = [];
  const attention = [];
  let totalRps = 0;

  for (const [id, label, kind, service, pos, hosts, via, databases, probe, mem, cpu, upDays, limit] of apps) {
    const rows = hostRows(hosts);
    const rps = sumRps(rows);
    let c = {
      name: `blog-${service}-1`, state: "running", status_text: `Up ${upDays} days`,
      uptime_s: upDays * 86400, restarts: 0, oom_killed: false,
      cpu_cores: cpu, mem_bytes: mem, mem_limit_bytes: limit,
      net_rx_bps: Math.round(cpu * 4e6) + 600, net_tx_bps: Math.round(cpu * 9e6) + 900,
    };
    if (id === "blimp-blog") { c.net_rx_bps = 43473.6; c.net_tx_bps = 1963.6; } // capture
    if (id === "db") { c.net_rx_bps = 6825.8; c.net_tx_bps = 3713.6; c.status_text = "Up 4 months (healthy)"; } // capture
    let pr = probe ? { ok: true, code: 200, ms: 4 + Math.round(cpu * 900) } : null;
    let status = cpu > 0.003 || (rps ?? 0) > 0.05 ? "working" : "idle";
    let reason = null;
    let headline = rps != null ? { value: rps, unit: "req/s" } : { value: r2(cpu), unit: "cores" };
    const facts = [{ label: "memory", value: `${fmtBytes(mem)}${limit ? ` of ${fmtBytes(limit)}` : ", no limit"}` }];
    if (via.length) facts.push({ label: "routes", value: via.join(", ") });

    if (kind === "proxy") {
      const all = Object.keys(RPS);
      totalRps = r2(all.reduce((a, h) => a + RPS[h][0], 0));
      headline = { value: caddyOk ? totalRps : null, unit: "req/s" };
      facts.push({ label: "sites", value: "21 site blocks, 2.10.2" });
      if (!caddyOk) { status = "unknown"; reason = "metrics endpoint not answering"; }
    }
    if (kind === "app" && !caddyOk && rps == null && hosts.length) {
      headline = { value: null, unit: "req/s" };
    }
    if (kind === "db") {
      const used = bad ? 96 : 91;
      headline = { value: used, unit: "of 100 conns" };
      facts.push({ label: "connections", value: `${used} of 100` }, { label: "databases", value: `${Object.keys(DBS).length}` },
        { label: "version", value: "PostgreSQL 17" });
      if (bad) { status = "blocked"; reason = "96 of 100 connections in use"; }
      attention.push({ node: "db", severity: bad ? "alert" : "warn", text: `Postgres at ${used} of 100 connections` });
    }
    if (bad && id === "blimp-blog") {
      c.mem_bytes = 1562 * MB; c.cpu_cores = 0.41;
      status = "blocked"; reason = "memory at 97% of its 1.5 GB limit";
      facts[0].value = `${fmtBytes(c.mem_bytes)} of ${fmtBytes(limit)}`;
      pr = { ok: true, code: 200, ms: 1840 };
      attention.unshift({ node: "blimp-blog", severity: "alert", text: "Blimp blog at 97% of its memory limit" });
    }
    if (bad && id === "skyfeed") {
      c = { ...c, state: "restarting", status_text: "Restarting (137) 8 seconds ago", uptime_s: null, restarts: 14,
        oom_killed: true, cpu_cores: null, mem_bytes: null, net_rx_bps: null, net_tx_bps: null };
      pr = { ok: false, code: null, ms: null, error: "connect ECONNREFUSED skyfeed:4000" };
      status = "down"; reason = "restart loop: 14 restarts, last exit 137 (OOM)";
      facts[0].value = "not running";
      headline = { value: null, unit: "req/s" };
      attention.unshift({ node: "skyfeed", severity: "alert", text: "Sky feeds down: restart loop, OOM killed" });
    }
    const viaOnly = via.length > 0 && hosts.length === 0;
    const vr = via.length ? viaOf(id, accessOk) : {};
    if (viaOnly && accessOk) headline = { value: vr.via_rps, unit: "req/s" };
    nodes.push({
      routes: routeRows(id, accessOk), latency: accessOk ? LAT(ROUTES[id]) : null, ...vr,
      id, label, kind, style: STYLE[id] ?? null, platform: "main", pos, status, reason, headline, container: c, probe: pr,
      hosts: rows, via, holds: kind === "db" ? Object.entries(DBS).map(([l, [b]]) => ({ label: l, bytes: b })) : [],
      facts,
    });
    if (kind !== "proxy") {
      if (hosts.length) edges.push({ id: `caddy>${id}`, from: "caddy", to: id, item: "requests", rate: rps, unit: "req/s", metered: true, label: hosts[0], codes: sumCodes(rows) });
      else if (via.length) edges.push({ id: `caddy>${id}`, from: "caddy", to: id, item: "requests", rate: accessOk ? vr.via_rps : null, unit: "req/s", metered: accessOk, label: via[0], codes: accessOk ? vr.via_codes : null });
    }
    if (databases.length) {
      edges.push({ id: `${id}>db`, from: id, to: "db", item: "commits",
        rate: r2(databases.reduce((a, d) => a + DBS[d][1], 0) / (databases[0] === "blog_prod" ? 2 : 1)),
        unit: "commit/s", metered: true, label: databases.join(", "), codes: null });
    }
  }
  edges.unshift({ id: "internet>caddy", from: "internet", to: "caddy", item: "requests", rate: caddyOk ? totalRps : null, unit: "req/s", metered: true, label: "all hosts",
    codes: caddyOk ? sumCodes(hostRows(Object.keys(RPS))) : null });
  edges.push({ id: "blimp-blog>deepseek", from: "blimp-blog", to: "deepseek", item: "prompts", rate: null, unit: null, metered: false, label: "prompts", codes: null });

  for (const [id, label, site, pos, hosts, bytes] of statics) {
    const rows = hostRows(hosts);
    const rps = sumRps(rows);
    const status = rps == null ? "unknown" : rps > 0 ? "working" : "idle";
    nodes.push({
      routes: routeRows(id, accessOk), latency: accessOk ? LAT(ROUTES[id]) : null,
      id, label, kind: "static", style: STYLE[id] ?? null, platform: "static", pos, status,
      reason: status === "unknown" ? "request counts unknown: caddy metrics failing" : null,
      headline: { value: rps, unit: "req/s" }, container: null, probe: null, hosts: rows, via: [],
      holds: [{ label: site, bytes }], facts: [{ label: "directory", value: `/sites/${site}` }, { label: "size", value: fmtBytes(bytes) }],
    });
    edges.push({ id: `caddy>${id}`, from: "caddy", to: id, item: "requests", rate: rps, unit: "req/s", metered: true, label: hosts[0], codes: sumCodes(rows) });
  }

  // resources and source
  const diskPct = Math.round((host.disk_used_bytes / host.disk_total_bytes) * 100);
  nodes.push(
    { id: "host-cpu", label: "CPU", kind: "resource", style: null, platform: "host", pos: [0, 0], status: "working", reason: null,
      headline: { value: host.cpu_used_cores, unit: `of ${host.cores} cores` }, container: null, probe: null, hosts: [], via: [], holds: [],
      facts: [{ label: "cores", value: `${host.cores}` }, { label: "load 1m", value: `${host.load1}` }] },
    { id: "host-mem", label: "Memory", kind: "resource", style: null, platform: "host", pos: [1, 0], status: "working", reason: null,
      headline: { value: r2(host.mem_used_bytes / GB), unit: `of ${fmtBytes(host.mem_total_bytes)}` }, container: null, probe: null, hosts: [], via: [], holds: [],
      facts: [{ label: "used", value: fmtBytes(host.mem_used_bytes) }, { label: "total", value: fmtBytes(host.mem_total_bytes) }] },
    { id: "host-disk", label: "Disk", kind: "resource", style: null, platform: "host", pos: [2, 0],
      status: bad ? "blocked" : "working", reason: bad ? "87% full, 21 GB free" : null,
      headline: { value: diskPct, unit: "% full" }, container: null, probe: null, hosts: [], via: [],
      holds: [{ label: "used", bytes: host.disk_used_bytes }, { label: "free", bytes: host.disk_total_bytes - host.disk_used_bytes }],
      facts: [{ label: "filesystem", value: "/ (ext4)" }, { label: "size", value: fmtBytes(host.disk_total_bytes) }] },
    { id: "internet", label: "Internet", kind: "source", style: null, platform: "outside", pos: [0, 0], status: caddyOk ? "working" : "unknown",
      reason: caddyOk ? null : "request counts unknown: caddy metrics failing",
      headline: { value: caddyOk ? totalRps : null, unit: "req/s" }, container: null, probe: null, hosts: [], via: [], holds: [], facts: [] },
    { id: "deepseek", label: "DeepSeek", kind: "external", style: null, platform: "outside", pos: [0, 2], status: "unknown", reason: "not observed: nothing meters outbound calls",
      headline: { value: null, unit: null }, container: null, probe: null, hosts: [], via: [], holds: [], facts: [{ label: "api", value: "api.deepseek.com" }] },
  );
  attention.push({ node: "host-disk", severity: bad ? "alert" : "warn", text: `Disk ${diskPct}% full` });
  if (bad) attention.splice(3, 0, { node: "caddy", severity: "warn", text: "Caddy metrics unreachable: request rates unknown" });

  // unplaced: on the box, not in the topology
  const unplaced = [
    ["classifier", "blog-classifier-1", "running", "Up 4 months", 120, 418 * MB, 0.004],
    ["icecast", "blog-icecast-1", "running", "Up 4 months", 120, 12 * MB, 0.0009],
    ["temper-link", "temper-link", "exited", "Exited (0) 8 weeks ago", null, null, null],
  ];
  for (const [id, name, state, st, up, mem, cpu] of unplaced) {
    nodes.push({
      id, label: id, kind: "unplaced", style: null, platform: null, pos: null,
      status: state === "running" ? (cpu > 0.003 ? "working" : "idle") : "idle", reason: null,
      headline: { value: mem == null ? null : r2(mem / MB), unit: "MB" },
      container: { name, state, status_text: st, uptime_s: up == null ? null : up * 86400, restarts: 0, oom_killed: false,
        cpu_cores: cpu, mem_bytes: mem, mem_limit_bytes: null, net_rx_bps: state === "running" ? 210 : null, net_tx_bps: state === "running" ? 90 : null },
      probe: null, hosts: [], via: [], holds: [], facts: [{ label: "topology", value: "not in the topology file" }],
    });
  }

  attention.sort((a, b) => (a.severity === b.severity ? 0 : a.severity === "alert" ? -1 : 1));
  attention.push({ node: "dave", severity: "warn", text: "Dave report failing: connect ECONNREFUSED dave:9568" });
  for (const n of nodes) {
    n.inside = INSIDE[n.id] ?? null;
    if (!("routes" in n)) { n.routes = accessOk ? [] : null; n.latency = null; }
    if (n.id === "internet") n.clients = accessOk
      ? { classes: { browser: 1480, bot: 610, tool: 240, other: 75 }, countries: [["US", 1210], ["DE", 310], ["GB", 190], ["??", 180], ["JP", 140], ["BR", 95]].map(([code, count]) => ({ code, count })), window_s: 300 }
      : null;
  }
  if (bad) attention.push({ node: null, severity: "warn", text: "access source failing: cannot open /caddy-logs/access.log: no such file or directory" });
  return { at: AT, tick_ms: 5000, sources, host, platforms, nodes, edges, attention };
}

for (const [name, bad] of [["box", false], ["bad-day", true]]) {
  writeFileSync(join(here, `${name}.json`), JSON.stringify(build(bad), null, 1) + "\n");
  console.log(`wrote ${name}.json`);
}
