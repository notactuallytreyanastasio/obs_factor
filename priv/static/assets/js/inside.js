// The floor inside one building. A node that reports its own inside
// (docs/contract.md, Reports) can be entered: its report becomes a factory of
// its own, drawn by the same renderer. This file turns one node's `inside`
// into a snapshot of the usual shape.
//
// Generic on purpose: it reads runtime gauges, units and streams, never
// "Phoenix". What each report kind becomes:
//
//   runtime gauges        -> the machine room (schedulers, memory, processes)
//   units                 -> one building per unit, on "alive inside"
//   stream http.route     -> belts from the door: to the unit with that route,
//                            or to "Plain routes" when no unit has it
//   stream liveview.*     -> one belt per view from "Live sockets"
//   stream db.query       -> a store per repo, fed from the hub
//   stream outbound.http  -> an outside service per host, fed from the hub
//   anything else         -> a small station of its own, fed from the hub
//
// The hub ("Endpoint") stands for "somewhere inside": a report says how
// often the database is queried, not which page asked.

import { isNum } from "./fmt.js";

const MAX_OTHER = 8;
const short = (name) => {
  const parts = String(name).split(".");
  return parts.length > 2 ? parts.slice(-2).join(".") : String(name);
};
const sum = (list) => (list.some((v) => !isNum(v)) ? null : list.reduce((a, v) => a + v, 0));
const round = (v, d = 3) => (isNum(v) ? Math.round(v * 10 ** d) / 10 ** d : null);

export const canEnter = (node) => !!(node && node.inside && node.inside.ok);

export function interiorSnapshot(outer, node) {
  const r = node.inside;
  const rt = r.runtime ?? {};
  const g = rt.gauges ?? {};
  const units = r.units ?? [];
  const streams = r.streams ?? [];
  const kind = rt.kind ?? "runtime";

  const blank = (o) => ({
    style: null, reason: null, container: null, probe: null, hosts: [], via: [], holds: [], facts: [],
    routes: null, latency: null, inside: null, headline: { value: null, unit: null }, ...o,
  });
  const nodes = [];
  const edges = [];
  const edge = (from, to, item, rate, unit, label) => edges.push({
    id: `${from}>${to}`, from, to, item, rate: round(rate), unit, metered: true, label, codes: null,
  });
  const active = (rate) => (rate == null ? "unknown" : rate > 0 ? "working" : "idle");
  const why = (rate) => (rate == null ? "rate not known yet: needs two reads" : null);

  // ---- who comes in -------------------------------------------------------
  const http = streams.filter((s) => s.kind === "http.route");
  const httpRate = http.length ? sum(http.map((s) => s.rate)) : null;
  const live = streams.filter((s) => s.kind.startsWith("liveview."));
  const liveRate = live.length ? sum(live.map((s) => s.rate)) : null;

  nodes.push(blank({
    id: "internet", label: "Requests in", kind: "source", platform: null, pos: null,
    status: http.length ? active(httpRate) : "idle", reason: http.length ? why(httpRate) : null,
    headline: { value: round(httpRate, 2), unit: "req/s" },
    facts: [{ label: "what", value: `HTTP requests reaching ${node.label}` }],
  }));
  if (live.length || units.some((u) => u.kind === "liveview")) {
    nodes.push(blank({
      id: "sockets", label: "Live sockets", kind: "source", platform: null, pos: null,
      status: active(liveRate), reason: why(liveRate),
      headline: { value: round(liveRate, 2), unit: "events/s" },
      facts: [{ label: "what", value: "mounts, params and events over LiveView sockets" }],
    }));
  }

  // ---- the hub ------------------------------------------------------------
  nodes.push(blank({
    id: "hub", label: "Endpoint", kind: "proxy", platform: "work", pos: [0, 0],
    status: active(httpRate), reason: why(httpRate),
    headline: { value: round(httpRate, 2), unit: "req/s" },
    facts: [{ label: "what", value: "stands for anywhere inside: the report says how often, not who asked" }],
  }));
  if (http.length) edge("internet", "hub", "requests", httpRate, "req/s", "all routes");

  // ---- units --------------------------------------------------------------
  const routeOwner = new Map();
  const cols = Math.max(1, Math.ceil(Math.sqrt(units.length)));
  const sorted = [...units].sort((a, b) => (b.count ?? 0) - (a.count ?? 0));
  sorted.forEach((u, i) => {
    const id = `unit:${u.kind}:${u.name}`;
    if (u.route) routeOwner.set(u.route, id);
    const mine = streams.filter((s) => s.name === u.name || s.name.startsWith(`${u.name}#`) || (u.route && s.kind === "http.route" && s.name.split(" ").slice(1).join(" ") === u.route));
    nodes.push(blank({
      id, label: short(u.name), kind: "app", platform: "alive", pos: [i % cols, Math.floor(i / cols)],
      status: (u.count ?? 0) > 0 ? "working" : "idle",
      headline: { value: u.count ?? null, unit: u.kind === "liveview" ? "sessions" : "alive" },
      facts: [
        { label: "kind", value: u.kind }, { label: "name", value: u.name },
        ...(u.route ? [{ label: "route", value: u.route }] : []),
      ],
      // the inspector shows this unit's members and its own streams
      inside: { ok: true, error: null, at: r.at, runtime: null, units: [u], streams: mine, truncated: null },
    }));
    const evs = live.filter((s) => s.name === u.name || s.name.startsWith(`${u.name}#`));
    if (evs.length) edge("sockets", id, "events", sum(evs.map((s) => s.rate)), "events/s", "mounts, params, events");
  });

  // ---- http routes --------------------------------------------------------
  const plain = [];
  const toUnit = new Map();
  for (const s of http) {
    const owner = routeOwner.get(s.name.split(" ").slice(1).join(" "));
    if (owner) toUnit.set(owner, [...(toUnit.get(owner) ?? []), s]);
    else plain.push(s);
  }
  for (const [owner, list] of toUnit) edge("hub", owner, "requests", sum(list.map((s) => s.rate)), "req/s", list.map((s) => s.name).join(", "));
  if (plain.length) {
    const rate = sum(plain.map((s) => s.rate));
    nodes.push(blank({
      id: "routes", label: "Plain routes", kind: "app", style: "switchyard", platform: "work", pos: [1, 0],
      status: active(rate), reason: why(rate), headline: { value: round(rate, 2), unit: "req/s" },
      facts: [{ label: "what", value: `${plain.length} routes that are not a live page` }],
      inside: { ok: true, error: null, at: r.at, runtime: null, units: [], streams: plain, truncated: null },
    }));
    edge("hub", "routes", "requests", rate, "req/s", `${plain.length} routes`);
  }

  // ---- stores and outside -------------------------------------------------
  streams.filter((s) => s.kind === "db.query").forEach((s, i) => {
    const id = `store:${s.name}`;
    nodes.push(blank({
      id, label: short(s.name), kind: "db", platform: "stores", pos: [0, i],
      status: active(s.rate), reason: why(s.rate), headline: { value: round(s.rate, 2), unit: "queries/s" },
      facts: [{ label: "repo", value: s.name }, { label: "average", value: isNum(s.avg_ms) ? `${s.avg_ms} ms` : null },
        { label: "since start", value: `${s.count} queries, ${s.errors ?? 0} errors` }],
      inside: { ok: true, error: null, at: r.at, runtime: null, units: [], streams: [s], truncated: null },
    }));
    edge("hub", id, "queries", s.rate, "queries/s", "from anywhere inside");
  });
  streams.filter((s) => s.kind === "outbound.http").forEach((s, i) => {
    const id = `out:${s.name}`;
    nodes.push(blank({
      id, label: s.name, kind: "external", platform: "stores", pos: [1 + Math.floor(i / 4), i % 4],
      status: active(s.rate), reason: why(s.rate), headline: { value: round(s.rate, 3), unit: "calls/s" },
      facts: [{ label: "host", value: s.name }, { label: "average", value: isNum(s.avg_ms) ? `${s.avg_ms} ms` : null },
        { label: "since start", value: `${s.count} calls, ${s.errors ?? 0} errors` }],
      inside: { ok: true, error: null, at: r.at, runtime: null, units: [], streams: [s], truncated: null },
    }));
    edge("hub", id, "calls", s.rate, "calls/s", "from anywhere inside");
  });

  // ---- everything else: one station each ----------------------------------
  const known = new Set(["http.route", "db.query", "outbound.http"]);
  const other = streams.filter((s) => !known.has(s.kind) && !s.kind.startsWith("liveview."));
  other.slice(0, MAX_OTHER).forEach((s, i) => {
    const id = `stream:${s.kind}:${s.name}`;
    nodes.push(blank({
      id, label: s.name, kind: "relay", platform: "work", pos: [i % 4, 1 + Math.floor(i / 4)],
      status: active(s.rate), reason: why(s.rate), headline: { value: round(s.rate, 3), unit: "/s" },
      facts: [{ label: "kind", value: s.kind }, { label: "since start", value: `${s.count}, ${s.errors ?? 0} errors` }],
      inside: { ok: true, error: null, at: r.at, runtime: null, units: [], streams: [s], truncated: null },
    }));
  });

  // ---- the machine room ---------------------------------------------------
  const cores = isNum(g["schedulers.online"]) ? g["schedulers.online"] : null;
  const util = isNum(g["scheduler.utilization"]) ? g["scheduler.utilization"] : null;
  const memTotal = node.container?.mem_limit_bytes ?? node.container?.mem_bytes ?? outer.host?.mem_total_bytes ?? null;
  const host = {
    cores, cpu_used_cores: cores != null && util != null ? round(util * cores, 3) : null, load1: isNum(g.run_queue) ? g.run_queue : null,
    mem_used_bytes: isNum(g["memory.total"]) ? g["memory.total"] : null, mem_total_bytes: memTotal,
    disk_used_bytes: isNum(g["process.count"]) ? g["process.count"] : null,
    disk_total_bytes: isNum(g["process.limit"]) ? g["process.limit"] : null, disk_avail_bytes: null,
  };
  const memParts = Object.entries(g).filter(([k, v]) => k.startsWith("memory.") && k !== "memory.total" && isNum(v)).sort((a, b) => b[1] - a[1]);
  const gaugeFacts = (pick) => Object.entries(g).filter(([k]) => pick(k)).map(([k, v]) => ({ label: k, value: String(v) }));
  nodes.push(
    blank({
      id: "host-cpu", label: "Schedulers", kind: "resource", platform: "host", pos: null,
      status: util == null ? "unknown" : "working", reason: util == null ? "scheduler use not reported yet" : null,
      headline: { value: util == null ? null : round(util * 100, 1), unit: `% of ${cores ?? "?"}` },
      facts: [...gaugeFacts((k) => k.startsWith("scheduler") || k === "run_queue"),
        ...Object.entries(rt.rates ?? {}).map(([k, v]) => ({ label: `${k} /s`, value: v == null ? null : String(v) }))],
    }),
    blank({
      id: "host-mem", label: `${kind} memory`, kind: "resource", platform: "host", pos: null,
      status: host.mem_used_bytes == null ? "unknown" : "working", reason: host.mem_used_bytes == null ? "memory not reported" : null,
      headline: { value: host.mem_used_bytes, unit: "B" },
      holds: memParts.map(([k, v]) => ({ label: k.slice(7), bytes: v })),
    }),
    blank({
      id: "host-disk", label: "Processes", kind: "resource", platform: "host", pos: null,
      status: host.disk_used_bytes == null ? "unknown" : "working", reason: host.disk_used_bytes == null ? "process count not reported" : null,
      headline: { value: host.disk_used_bytes, unit: "processes" },
      facts: gaugeFacts((k) => /^(process|port|atom|ets)\./.test(k)),
    }),
  );

  const t = r.truncated ?? {};
  const cut = (t.units ?? 0) + (t.members ?? 0) + (t.streams ?? 0);
  const platforms = [
    { id: "alive", label: `alive inside ${node.label}` },
    { id: "work", label: "routes and jobs" },
    { id: "stores", label: "stores and outside" },
    { id: "host", label: `${kind} machine room` },
  ].filter((p) => nodes.some((n) => n.platform === p.id));

  return {
    interior: { of: node.id, label: node.label, kind, versions: rt.versions ?? {}, uptime_s: rt.uptime_s ?? null },
    at: outer.at, tick_ms: outer.tick_ms,
    sources: { report: { ok: true, at: r.at, error: null } },
    host, platforms, nodes, edges,
    attention: cut > 0 ? [{ node: null, severity: "warn", text: `the report was cut: ${t.units ?? 0} units, ${t.members ?? 0} members, ${t.streams ?? 0} streams left out` }] : [],
  };
}
