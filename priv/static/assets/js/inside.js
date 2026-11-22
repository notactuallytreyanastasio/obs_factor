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
//   members (a cluster)   -> a machine room per BEAM node, a "distribution"
//                            building in each, belts between them carrying
//                            each connection's bytes/s, and every :global
//                            name as a landmark on the node that holds it
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
  const all = r.streams ?? [];
  // Rows with `by` break a total down by who caused it; the totals are the rows without.
  const streams = all.filter((s) => !s.by);
  const breakdown = all.filter((s) => s.by);
  const events = r.events ?? [];
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
    const mine = [
      ...streams.filter((s) => s.name === u.name || s.name.startsWith(`${u.name}#`) || (u.route && s.kind === "http.route" && s.name.split(" ").slice(1).join(" ") === u.route)),
      ...breakdown.filter((s) => s.by.kind === u.kind && s.by.name === u.name),
    ];
    nodes.push(blank({
      id, label: short(u.name), kind: "app", platform: "alive", pos: [i % cols, Math.floor(i / cols)],
      status: (u.count ?? 0) > 0 ? "working" : "idle",
      headline: { value: u.count ?? null, unit: u.kind === "liveview" ? "sessions" : "alive" },
      facts: [
        { label: "kind", value: u.kind }, { label: "name", value: u.name },
        ...(u.route ? [{ label: "route", value: u.route }] : []),
      ],
      // the inspector shows this unit's members and its own streams
      inside: { ok: true, error: null, at: r.at, runtime: null, units: [u], streams: mine, truncated: null,
        events: events.filter((e) => e.by && e.by.kind === u.kind && e.by.name === u.name) },
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
      inside: { ok: true, error: null, at: r.at, runtime: null, units: [], streams: [...plain, ...breakdown.filter((s) => s.by.kind === "http.route" && !routeOwner.has(s.by.name.split(" ").slice(1).join(" ")))], truncated: null,
        events: events.filter((e) => e.by && e.by.kind === "http.route") },
    }));
    edge("hub", "routes", "requests", rate, "req/s", `${plain.length} routes`);
  }

  // Who caused a query or a call, when the report says: a belt from that page
  // (or from the plain routes) to the store, and only the rest from the hub.
  const causeOf = (by) => {
    if (by.kind === "http.route") return routeOwner.get(by.name.split(" ").slice(1).join(" ")) ?? (plain.length ? "routes" : null);
    const id = `unit:${by.kind}:${by.name}`;
    return nodes.some((n) => n.id === id) ? id : null;
  };
  const feed = (target, total, item, unit) => {
    const parts = breakdown.filter((s) => s.kind === total.kind && s.name === total.name);
    const byCause = new Map();
    for (const p of parts) {
      const from = causeOf(p.by);
      if (!from) continue;
      byCause.set(from, [...(byCause.get(from) ?? []), p]);
    }
    let attributed = 0, unknown = false;
    for (const [from, list] of byCause) {
      const rate = sum(list.map((s) => s.rate));
      if (rate == null) unknown = true; else attributed += rate;
      edge(from, target, item, rate, unit, list.map((s) => s.by.name).join(", "));
    }
    const rest = total.rate == null || unknown ? null : Math.max(0, total.rate - attributed);
    // the hub's belt stays unless everything is known to come from named causes
    if (!(byCause.size && rest === 0 && total.count === parts.reduce((a, s) => a + s.count, 0))) {
      edge("hub", target, item, byCause.size ? rest : total.rate, unit, byCause.size ? "not attributed to a page" : "from anywhere inside");
    }
  };

  // ---- stores and outside -------------------------------------------------
  streams.filter((s) => s.kind === "db.query").forEach((s, i) => {
    const id = `store:${s.name}`;
    nodes.push(blank({
      id, label: short(s.name), kind: "db", platform: "stores", pos: [0, i],
      status: active(s.rate), reason: why(s.rate), headline: { value: round(s.rate, 2), unit: "queries/s" },
      facts: [{ label: "repo", value: s.name }, { label: "average", value: isNum(s.avg_ms) ? `${s.avg_ms} ms` : null },
        { label: "since start", value: `${s.count} queries, ${s.errors ?? 0} errors` }],
      inside: { ok: true, error: null, at: r.at, runtime: null, units: [], streams: [s, ...breakdown.filter((b) => b.kind === s.kind && b.name === s.name)], truncated: null },
    }));
    feed(id, s, "queries", "queries/s");
  });
  streams.filter((s) => s.kind === "outbound.http").forEach((s, i) => {
    const id = `out:${s.name}`;
    nodes.push(blank({
      id, label: s.name, kind: "external", platform: "stores", pos: [1 + Math.floor(i / 4), i % 4],
      status: active(s.rate), reason: why(s.rate), headline: { value: round(s.rate, 3), unit: "calls/s" },
      facts: [{ label: "host", value: s.name }, { label: "average", value: isNum(s.avg_ms) ? `${s.avg_ms} ms` : null },
        { label: "since start", value: `${s.count} calls, ${s.errors ?? 0} errors` }],
      inside: { ok: true, error: null, at: r.at, runtime: null, units: [], streams: [s, ...breakdown.filter((b) => b.kind === s.kind && b.name === s.name)], truncated: null },
    }));
    feed(id, s, "calls", "calls/s");
  });

  // ---- everything else: one station each ----------------------------------
  const known = new Set(["http.route", "db.query", "outbound.http"]);
  const other = streams.filter((s) => !known.has(s.kind) && !s.kind.startsWith("liveview.") && s.kind !== "log");
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
  const members = (r.members ?? []).filter(Boolean);
  const attention = [];
  if (members.length > 1) {
    clusterRooms(members, node, outer, blank, nodes, edges, attention);
  } else nodes.push(
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
    ...members.map((m, i) => ({ id: `node${i}`, label: m.cluster?.node ?? m.address })),
  ].filter((p) => nodes.some((n) => n.platform === p.id));
  if (cut > 0) attention.push({ node: null, severity: "warn", text: `the report was cut: ${t.units ?? 0} units, ${t.members ?? 0} members, ${t.streams ?? 0} streams left out` });

  return {
    interior: { of: node.id, label: node.label, kind, versions: rt.versions ?? {}, uptime_s: rt.uptime_s ?? null, events },
    at: outer.at, tick_ms: outer.tick_ms,
    sources: { report: { ok: true, at: r.at, error: null } },
    host, platforms, nodes, edges,
    attention,
  };
}

// A machine room per node of a cluster. Each member's report is that node's
// own view: its gauges, and the connections it has. A connection one side
// lists and the other does not is a partial partition, said in attention
// and drawn as a down belt; a member whose report failed is a dark room.
function clusterRooms(members, node, outer, blank, nodes, edges, attention) {
  const byName = new Map(members.map((m, i) => [m.cluster?.node, i]).filter(([k]) => k));
  const shortName = (name) => String(name ?? "?").replace(/^[^@]*@/, "@");
  const limit = node.container?.mem_limit_bytes ?? outer.host?.mem_total_bytes ?? null;

  members.forEach((m, i) => {
    const plat = `node${i}`;
    const g = m.runtime?.gauges ?? {};
    const num = (k) => (isNum(g[k]) ? g[k] : null);
    const cores = num("schedulers.online"), util = num("scheduler.utilization");
    const mem = num("memory.total"), procs = num("process.count"), plimit = num("process.limit");
    const dark = !m.ok;
    const why = dark ? `report failing: ${m.error ?? "no answer"}` : null;
    nodes.push(
      blank({
        id: `${plat}:cpu`, label: "Schedulers", kind: "resource", resource: "cpu", platform: plat, pos: [0, 0],
        status: dark || util == null ? "unknown" : "working", reason: why ?? (util == null ? "scheduler use not reported yet" : null),
        load: util, headline: { value: util == null ? null : round(util * 100, 1), unit: `% of ${cores ?? "?"}` },
        facts: Object.entries(m.runtime?.rates ?? {}).map(([k, v]) => ({ label: `${k} /s`, value: v == null ? null : String(v) })),
      }),
      blank({
        id: `${plat}:mem`, label: "Memory", kind: "resource", resource: "mem", platform: plat, pos: [1, 0],
        status: dark || mem == null ? "unknown" : "working", reason: why,
        load: mem != null && limit ? mem / limit : null, headline: { value: mem, unit: "B" },
        holds: Object.entries(g).filter(([k, v]) => k.startsWith("memory.") && k !== "memory.total" && isNum(v)).map(([k, v]) => ({ label: k.slice(7), bytes: v })),
      }),
      blank({
        id: `${plat}:procs`, label: "Processes", kind: "resource", resource: "procs", platform: plat, pos: [2, 0],
        status: dark || procs == null ? "unknown" : "working", reason: why,
        load: procs != null && plimit ? procs / plimit : null, headline: { value: procs, unit: "processes" },
      }),
    );

    const conns = m.cluster?.connections ?? [];
    const outBps = conns.reduce((a, c) => (isNum(c.out_bps) ? a + c.out_bps : a), 0);
    nodes.push(blank({
      id: `${plat}:dist`, label: "Distribution", kind: "relay", platform: plat, pos: [0, 1],
      status: dark ? "unknown" : conns.length ? "working" : "idle",
      reason: why ?? (m.cluster && !m.cluster.distributed ? "not distributed: started without a node name" : null),
      headline: { value: dark ? null : conns.length, unit: conns.length === 1 ? "connection" : "connections" },
      facts: [
        { label: "node", value: m.cluster?.node ?? null },
        { label: "address", value: m.address },
        { label: "sending", value: dark ? null : `${round(outBps, 0)} B/s` },
        ...conns.map((c) => ({ label: shortName(c.node), value: `${c.kind}${isNum(c.send_queue_bytes) && c.send_queue_bytes > 0 ? `, ${c.send_queue_bytes} B queued` : ""}` })),
      ],
    }));

    // what this node can see the other ends of
    for (const c of conns) {
      const j = byName.get(c.node);
      if (j == null) continue; // a hidden node or one outside this service (an observer, a remote shell)
      const back = (members[j].cluster?.connections ?? []).some((x) => x.node === m.cluster?.node);
      if (members[j].ok && !back) {
        attention.push({ node: `${plat}:dist`, severity: "alert", text: `${m.cluster.node} lists ${c.node}, which does not list it back: a partial partition` });
      }
      edges.push({
        id: `${plat}:dist>node${j}:dist`, from: `${plat}:dist`, to: `node${j}:dist`, item: "dist",
        rate: isNum(c.out_bps) ? round(c.out_bps, 1) : null, unit: "B/s", metered: true, label: null, codes: null,
        status: members[j].ok && !back ? "down" : undefined,
      });
    }
    // a member that should see the others and does not
    if (!dark && m.cluster) {
      for (const [name, j] of byName) {
        if (j !== i && members[j].ok && !conns.some((c) => c.node === name)) {
          attention.push({ node: `${plat}:dist`, severity: "alert", text: `${m.cluster.node} is not connected to ${name}` });
        }
      }
    }
  });

  // :global names, each on the node it lives on. Taken from every member's
  // view: two nodes disagreeing about where a name lives is said, too.
  const where = new Map();
  for (const m of members) for (const gl of m.cluster?.globals ?? []) {
    if (!where.has(gl.name)) where.set(gl.name, new Set());
    where.get(gl.name).add(gl.node);
  }
  let k = 0;
  for (const [name, at] of [...where].sort((a, b) => a[0].localeCompare(b[0]))) {
    const homes = [...at];
    if (homes.length > 1) attention.push({ node: null, severity: "alert", text: `the nodes disagree where ${name} lives: ${homes.join(", ")}` });
    const j = byName.get(homes[0]);
    if (j == null) continue;
    const slot = 1 + (k++ % 2);
    nodes.push(blank({
      id: `node${j}:g:${name}`, label: `★ ${name.replace(/^Elixir\./, "").split(".").slice(-2).join(".")}`, kind: "app", platform: `node${j}`,
      pos: [slot, 1 + Math.floor((k - 1) / 2)], status: "working",
      headline: { value: null, unit: "global" }, facts: [{ label: "registered as", value: name }, { label: "lives on", value: homes[0] }],
    }));
  }
}
