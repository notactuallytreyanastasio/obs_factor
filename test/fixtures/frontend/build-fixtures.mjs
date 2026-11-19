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
  };
  const host = { ...HOST };
  if (bad) { host.cpu_used_cores = 1.31; host.load1 = 2.4; host.mem_used_bytes = 9.4 * GB; }

  const hostRows = (hosts) => hosts.map((h) => {
    const [rps, err, ms] = RPS[h] ?? [0, 0, null];
    return caddyOk ? { host: h, rps, err_rps: err, avg_ms: ms } : { host: h, rps: null, err_rps: null, avg_ms: null };
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
    nodes.push({
      id, label, kind, platform: "main", pos, status, reason, headline, container: c, probe: pr,
      hosts: rows, via, holds: kind === "db" ? Object.entries(DBS).map(([l, [b]]) => ({ label: l, bytes: b })) : [],
      facts,
    });
    if (kind !== "proxy") {
      if (hosts.length) edges.push({ id: `caddy>${id}`, from: "caddy", to: id, item: "requests", rate: rps, unit: "req/s", metered: true, label: hosts[0] });
      else if (via.length) edges.push({ id: `caddy>${id}`, from: "caddy", to: id, item: "requests", rate: null, unit: "req/s", metered: false, label: via[0] });
    }
    if (databases.length) {
      edges.push({ id: `${id}>db`, from: id, to: "db", item: "commits",
        rate: r2(databases.reduce((a, d) => a + DBS[d][1], 0) / (databases[0] === "blog_prod" ? 2 : 1)),
        unit: "commit/s", metered: true, label: databases.join(", ") });
    }
  }
  edges.unshift({ id: "internet>caddy", from: "internet", to: "caddy", item: "requests", rate: caddyOk ? totalRps : null, unit: "req/s", metered: true, label: "all hosts" });
  edges.push({ id: "blimp-blog>deepseek", from: "blimp-blog", to: "deepseek", item: "prompts", rate: null, unit: null, metered: false, label: "prompts" });

  for (const [id, label, site, pos, hosts, bytes] of statics) {
    const rows = hostRows(hosts);
    const rps = sumRps(rows);
    const status = rps == null ? "unknown" : rps > 0 ? "working" : "idle";
    nodes.push({
      id, label, kind: "static", platform: "static", pos, status,
      reason: status === "unknown" ? "request counts unknown: caddy metrics failing" : null,
      headline: { value: rps, unit: "req/s" }, container: null, probe: null, hosts: rows, via: [],
      holds: [{ label: site, bytes }], facts: [{ label: "directory", value: `/sites/${site}` }, { label: "size", value: fmtBytes(bytes) }],
    });
    edges.push({ id: `caddy>${id}`, from: "caddy", to: id, item: "requests", rate: rps, unit: "req/s", metered: true, label: hosts[0] });
  }

  // resources and source
  const diskPct = Math.round((host.disk_used_bytes / host.disk_total_bytes) * 100);
  nodes.push(
    { id: "host-cpu", label: "CPU", kind: "resource", platform: "host", pos: [0, 0], status: "working", reason: null,
      headline: { value: host.cpu_used_cores, unit: `of ${host.cores} cores` }, container: null, probe: null, hosts: [], via: [], holds: [],
      facts: [{ label: "cores", value: `${host.cores}` }, { label: "load 1m", value: `${host.load1}` }] },
    { id: "host-mem", label: "Memory", kind: "resource", platform: "host", pos: [1, 0], status: "working", reason: null,
      headline: { value: r2(host.mem_used_bytes / GB), unit: `of ${fmtBytes(host.mem_total_bytes)}` }, container: null, probe: null, hosts: [], via: [], holds: [],
      facts: [{ label: "used", value: fmtBytes(host.mem_used_bytes) }, { label: "total", value: fmtBytes(host.mem_total_bytes) }] },
    { id: "host-disk", label: "Disk", kind: "resource", platform: "host", pos: [2, 0],
      status: bad ? "blocked" : "working", reason: bad ? "87% full, 21 GB free" : null,
      headline: { value: diskPct, unit: "% full" }, container: null, probe: null, hosts: [], via: [],
      holds: [{ label: "used", bytes: host.disk_used_bytes }, { label: "free", bytes: host.disk_total_bytes - host.disk_used_bytes }],
      facts: [{ label: "filesystem", value: "/ (ext4)" }, { label: "size", value: fmtBytes(host.disk_total_bytes) }] },
    { id: "internet", label: "Internet", kind: "source", platform: "outside", pos: [0, 0], status: caddyOk ? "working" : "unknown",
      reason: caddyOk ? null : "request counts unknown: caddy metrics failing",
      headline: { value: caddyOk ? totalRps : null, unit: "req/s" }, container: null, probe: null, hosts: [], via: [], holds: [], facts: [] },
    { id: "deepseek", label: "DeepSeek", kind: "external", platform: "outside", pos: [0, 2], status: "unknown", reason: "not observed: nothing meters outbound calls",
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
      id, label: id, kind: "unplaced", platform: null, pos: null,
      status: state === "running" ? (cpu > 0.003 ? "working" : "idle") : "idle", reason: null,
      headline: { value: mem == null ? null : r2(mem / MB), unit: "MB" },
      container: { name, state, status_text: st, uptime_s: up == null ? null : up * 86400, restarts: 0, oom_killed: false,
        cpu_cores: cpu, mem_bytes: mem, mem_limit_bytes: null, net_rx_bps: state === "running" ? 210 : null, net_tx_bps: state === "running" ? 90 : null },
      probe: null, hosts: [], via: [], holds: [], facts: [{ label: "topology", value: "not in the topology file" }],
    });
  }

  attention.sort((a, b) => (a.severity === b.severity ? 0 : a.severity === "alert" ? -1 : 1));
  return { at: AT, tick_ms: 5000, sources, host, platforms, nodes, edges, attention };
}

for (const [name, bad] of [["box", false], ["bad-day", true]]) {
  writeFileSync(join(here, `${name}.json`), JSON.stringify(build(bad), null, 1) + "\n");
  console.log(`wrote ${name}.json`);
}
