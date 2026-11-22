// The Applications floor: :observer's Applications tab played out on the
// control plane, for one building's BEAM (or the observer's own).
//
// Fed only by the bus (docs/contract.md, Observer, "On the bus"):
//   observer:<node>:<member or ->:apps        the started applications
//   observer:<node>:<member or ->:tree:<app>  each one's supervision tree
// one subscription per topic while it is on screen, dropped when it is not
// (leaving, another member, another app in focus), so the feeds stop.
//
// What each read becomes (appsSnapshot):
//   application with a top supervisor -> a platform, its tree in rows by depth
//   application without one (a library) or with a lone empty supervisor
//                                     -> named in the legend line, not drawn
//   supervisor                        -> a tower ("otp-sup"), taller with memory
//   worker                            -> a workshop ("otp-worker")
//   the engine's group (children past 25 under one supervisor)
//                                     -> one building with the count ("otp-group")
//   what we leave out ourselves (more than MAX_DRAWN per app)
//                                     -> one building per parent with the count ("otp-fold")
//   parent -> child                   -> a belt; its speed is the child's
//                                        reductions per second between two reads
//   mailbox                           -> crates at the dock (message_queue_len)
//   status                            -> the lamp
// Every failed read is shown with its reason, never an empty floor.

import { isNum, bytes } from "./fmt.js";
import * as bus from "./bus.js";

export const topicOf = (node, member, view) => `observer:${node}:${member || "-"}:${view}`;

// Buildings per application in the "all applications" view; one application
// in focus may draw this many.
const MAX_DRAWN = 40;
const MAX_FOCUS = 260;

const LAMP = {
  running: "working", runnable: "working", garbage_collecting: "working",
  waiting: "idle", suspended: "blocked", exiting: "down", "not running": "down",
};

const short = (s) => {
  const t = String(s ?? "").replace(/^Elixir\./, "");
  if (/^[A-Z][\w.]*$/.test(t)) { const p = t.split("."); return p.length > 2 ? p.slice(-2).join(".") : t; }
  return t.length > 28 ? `${t.slice(0, 27)}…` : t;
};

// a process's name on the floor: its registered name, else its child id,
// else what it was started as
export function procLabel(t) {
  if (t.registered_name) return short(t.registered_name);
  // a bare number or index says little on its own: what it runs, and the number
  if (t.id && /^-?\d+$/.test(t.id) && t.initial_call) return `${short(t.initial_call.replace(/\/\d+$/, ""))} ${t.id}`;
  if (t.id && t.id !== ":undefined") return short(t.id);
  if (t.initial_call) return short(t.initial_call.replace(/\/\d+$/, ""));
  return t.pid ?? "?";
}

// Height in tiles of z, from memory: a log scale, so a 2 MB process is
// visibly taller than a 3 KB one without towering over the floor.
function heightFor(kind, mem) {
  const u = isNum(mem) && mem > 0 ? Math.max(0, Math.min(1, (Math.log10(mem) - 3.4) / 3.6)) : 0;
  return kind === "sup" ? 2.3 + 2.0 * u : kind === "worker" ? 0.9 + 1.5 * u : 1.4 + 1.2 * u;
}

const round = (v, d = 1) => (isNum(v) ? Math.round(v * 10 ** d) / 10 ** d : null);

// ---- the snapshot ----------------------------------------------------------
// st: {target: {node, label, member}, apps: {at, data} | {at, error} | null,
//      trees: Map(app -> payload), rates: Map(pid -> reductions/s), focus}
export function appsSnapshot(outer, st) {
  const { target } = st;
  const nodes = [], edges = [], platforms = [], attention = [];
  const sources = {};
  const blank = (o) => ({
    style: null, reason: null, container: null, probe: null, hosts: [], via: [], holds: [], facts: [],
    routes: null, latency: null, inside: null, headline: { value: null, unit: null }, ...o,
  });
  const appsTopic = topicOf(target.node, target.member, "apps");
  const a = st.apps;
  sources.apps = a?.error ? { ok: false, at: null, error: a.error } : { ok: !!a?.data, at: a?.at ?? null, error: a?.data ? null : "no read yet" };
  const info = { node: a?.data?.node ?? null, took_ms: a?.data?.took_ms ?? null, count: a?.data?.count ?? null, drawn: [], trivial: [], cut: [], trees_ms: [] };

  if (!a?.data) {
    // nothing to draw yet, or the read failed: one marked lot that says so
    platforms.push({ id: "apps", label: "applications" });
    nodes.push(blank({
      id: "apps:none", label: a?.error ? "applications: read failed" : "applications: waiting", kind: "app", style: "otp-sup",
      platform: "apps", pos: [0, 0], status: "unknown", height: 2.3,
      reason: a?.error ? `${appsTopic}: ${a.error}` : `waiting for the first read of ${appsTopic}`,
    }));
    if (a?.error) attention.push({ node: "apps:none", severity: "alert", text: `${appsTopic}: ${a.error}` });
  } else {
    const list = [...a.data.apps].sort((x, y) => x.name.localeCompare(y.name));
    for (const app of list) {
      if (app.error) attention.push({ node: null, severity: "warn", text: `${app.name}: ${app.error}` });
      if (!app.top_supervisor) { info.trivial.push({ name: app.name, why: "a library: no processes" }); continue; }
      if (st.focus && st.focus !== app.name) continue;
      const tp = st.trees.get(app.name);
      const plat = `app:${app.name}`;
      const tTopic = topicOf(target.node, target.member, `tree:${app.name}`);
      sources[`tree:${app.name}`] = tp?.error ? { ok: false, at: null, error: tp.error } : { ok: !!tp?.data, at: tp?.at ?? null, error: tp?.data ? null : "no read yet" };
      if (!tp || tp.error || !tp.data) {
        const why = tp?.error ? `${tTopic}: ${tp.error}` : `waiting for the first read of ${tTopic}`;
        platforms.push({ id: plat, label: `${app.name} ${app.vsn}` });
        nodes.push(blank({
          id: `${plat}:/`, label: app.name, kind: "app", style: "otp-sup", platform: plat, pos: [0, 0],
          status: "unknown", reason: why, height: 2.3,
          facts: [{ label: "application", value: `${app.name} ${app.vsn}` }, { label: "top supervisor", value: app.top_supervisor }],
          otp: { app: app.name, pid: app.top_supervisor, type: "supervisor", parent: null, child_id: null },
        }));
        if (tp?.error) attention.push({ node: `${plat}:/`, severity: "alert", text: why });
        info.drawn.push(app.name);
        continue;
      }
      const d = tp.data;
      if (!st.focus && (d.nodes ?? 0) <= 1 && !(d.tree?.children ?? []).length) {
        info.trivial.push({ name: app.name, why: "one supervisor, no children" });
        continue;
      }
      info.drawn.push(app.name);
      if (isNum(d.took_ms)) info.trees_ms.push(d.took_ms);
      const c = d.cut ?? {};
      const engineCut = Object.entries(c).filter(([, v]) => v > 0).map(([k, v]) => `${v} ${k}`);
      const drawn = drawTree(app, d, st, plat, blank, nodes, edges, attention, st.focus ? MAX_FOCUS : MAX_DRAWN);
      const ours = drawn.folded > 0 ? `${drawn.folded} not drawn (more than ${st.focus ? MAX_FOCUS : MAX_DRAWN} buildings${st.focus ? "" : "; put it in focus to draw more"})` : null;
      if (engineCut.length) info.cut.push(`${app.name}: the engine cut ${engineCut.join(", ")}`);
      if (ours) info.cut.push(`${app.name}: ${ours}`);
      platforms.push({ id: plat, label: `${app.name} ${app.vsn} · ${d.nodes} proc · ${round(d.took_ms, 1)} ms` });
    }
  }

  return {
    interior: {
      of: target.node, label: target.label, kind: "applications",
      versions: { ...(info.node ? { node: info.node } : {}), ...(target.member ? { member: target.member } : {}) },
      uptime_s: null, events: [],
    },
    apps: info,
    at: outer?.at ?? new Date().toISOString(), tick_ms: outer?.tick_ms ?? 5000,
    sources,
    host: { cores: null, cpu_used_cores: null, load1: null, mem_used_bytes: null, mem_total_bytes: null, disk_used_bytes: null, disk_total_bytes: null, disk_avail_bytes: null },
    platforms, nodes, edges, attention,
  };
}

// One application's tree, breadth first so the top of the tree is always
// drawn and what does not fit is the bottom of it, counted where it hangs.
function drawTree(app, d, st, plat, blank, nodes, edges, attention, cap) {
  const out = [];
  const folds = new Map(); // parent id -> {count, memory, mql}
  const queue = [{ t: d.tree, id: `${plat}:/`, parent: null, depth: 0 }];
  const subtree = (t) => {
    let n = 0, mem = 0, q = 0;
    const walk = (x) => {
      if (x.group) { n += x.count ?? 0; mem += x.memory ?? 0; q = Math.max(q, x.message_queue_len_max ?? 0); return; }
      n += 1; mem += isNum(x.memory) ? x.memory : 0; q = Math.max(q, x.message_queue_len ?? 0);
      for (const ch of x.children ?? []) walk(ch);
    };
    walk(t);
    return { n, mem, q };
  };
  while (queue.length) {
    const e = queue.shift();
    if (out.length >= cap && e.parent) {
      const f = folds.get(e.parent.id) ?? { count: 0, memory: 0, mql: 0, depth: e.depth };
      const s = subtree(e.t);
      f.count += s.n; f.memory += s.mem; f.mql = Math.max(f.mql, s.q);
      folds.set(e.parent.id, f);
      continue;
    }
    out.push(e);
    const kids = e.t.children ?? [];
    // siblings with the same child id (a DynamicSupervisor's :undefined) are told apart by pid
    const seen = new Map();
    for (const k of kids) { const key = k.group ? "…group" : k.id ?? k.pid; seen.set(key, (seen.get(key) ?? 0) + 1); }
    for (const k of kids) {
      const key = k.group ? "…group" : k.id ?? k.pid;
      const part = seen.get(key) > 1 ? `${key}#${k.pid}` : key;
      queue.push({ t: k, id: `${e.id}/${part}`, parent: e, depth: e.depth + 1 });
    }
  }
  const all = [...out, ...[...folds].map(([pid, f]) => ({ fold: f, id: `${pid}/…not drawn`, parent: out.find((x) => x.id === pid), depth: f.depth }))];

  // rows by depth, wrapped at `cols`
  const cols = Math.max(3, Math.min(12, Math.ceil(Math.sqrt(all.length * 1.6))));
  const byDepth = new Map();
  for (const e of all) { if (!byDepth.has(e.depth)) byDepth.set(e.depth, []); byDepth.get(e.depth).push(e); }
  let row = 0;
  for (const depth of [...byDepth.keys()].sort((x, y) => x - y)) {
    const list = byDepth.get(depth);
    // a lone node in its row stands over the middle
    const pad = list.length < cols ? Math.floor((Math.min(cols, Math.max(...[...byDepth.values()].map((l) => l.length))) - list.length) / 2) : 0;
    list.forEach((e, i) => { e.pos = [pad + (i % cols), row + Math.floor(i / cols)]; });
    row += Math.ceil(list.length / cols);
  }

  for (const e of all) {
    const t = e.t;
    const parentPid = e.parent?.t?.pid ?? null;
    let n;
    if (e.fold) {
      const f = e.fold;
      n = blank({
        id: e.id, label: `${f.count} more`, kind: "app", style: "otp-fold", platform: plat, pos: e.pos,
        status: "unknown", reason: `not drawn here: ${f.count} processes below ${procLabel(e.parent.t)}${st.focus ? "" : "; put the application in focus to draw more of it"}`,
        headline: { value: f.count, unit: "processes" }, height: heightFor("group", f.memory / Math.max(1, f.count)),
        queue: f.mql, count: f.count, fittings: true,
        facts: [{ label: "memory, all of them", value: bytes(f.memory) }, { label: "longest mailbox", value: String(f.mql) }],
        otp: { app: app.name, group: true },
      });
    } else if (t.group) {
      n = blank({
        id: e.id, label: `${t.count} more`, kind: "app", style: "otp-group", platform: plat, pos: e.pos,
        status: (t.message_queue_len_max ?? 0) > 0 ? "working" : "idle",
        headline: { value: t.count, unit: "processes" }, height: heightFor("group", (t.memory ?? 0) / Math.max(1, t.count ?? 1)),
        queue: t.message_queue_len_max ?? 0, count: t.count, fittings: true,
        reason: `the engine groups children past ${d.children_limit ?? 25} per supervisor`,
        facts: [{ label: "memory, all of them", value: bytes(t.memory) }, { label: "longest mailbox", value: String(t.message_queue_len_max ?? "?") }],
        otp: { app: app.name, group: true },
      });
    } else {
      const sup = t.type === "supervisor";
      const lamp = t.pid == null ? "down" : LAMP[t.status] ?? "unknown";
      const reason = t.pid == null ? `not running: its supervisor lists child ${t.id} with no process (its init returned :ignore, or it stopped and was not restarted)`
        : lamp === "unknown" ? `status ${JSON.stringify(t.status)} is not one this page knows`
          : t.not_walked ? `children not read: ${t.not_walked}` : null;
      n = blank({
        id: e.id, label: e.depth === 0 ? app.name : procLabel(t), kind: "app", style: sup ? "otp-sup" : "otp-worker",
        platform: plat, pos: e.pos, status: lamp, reason,
        headline: { value: isNum(t.memory) ? t.memory : null, unit: "B" }, height: heightFor(sup ? "sup" : "worker", t.memory),
        queue: isNum(t.message_queue_len) ? t.message_queue_len : 0, fittings: true,
        facts: [
          { label: "pid", value: t.pid ?? "not running" }, { label: "child id", value: t.id ?? null },
          { label: "registered", value: t.registered_name ?? null }, { label: "in", value: t.current_function ?? null },
        ],
        otp: {
          app: app.name, pid: t.pid ?? null, type: t.type ?? (e.depth === 0 ? "supervisor" : "worker"),
          parent: parentPid, parentLabel: e.parent ? procLabel(e.parent.t) : null, child_id: e.depth === 0 ? null : t.id ?? null,
          registered_name: t.registered_name ?? null, status: t.status ?? null, memory: t.memory ?? null,
          message_queue_len: t.message_queue_len ?? null, reductions: t.reductions ?? null, children: t.children ? t.children.length : null,
        },
      });
      if (t.pid == null) attention.push({ node: e.id, severity: "warn", text: `${app.name}: ${procLabel(t)} is not running (no process under its supervisor)` });
      else if ((t.message_queue_len ?? 0) >= 100) attention.push({ node: e.id, severity: "warn", text: `${app.name}: ${procLabel(t)} has ${t.message_queue_len} messages waiting` });
    }
    nodes.push(n);
    if (e.parent) {
      const pid = t?.pid;
      const rate = pid && st.rates.has(pid) ? round(st.rates.get(pid), 0) : null;
      const metered = !(e.fold || t?.group);
      edges.push({
        id: `${e.parent.id}>${e.id}`, from: e.parent.id, to: e.id, item: "reductions",
        rate: metered ? rate : null, unit: "reductions/s", metered, codes: null,
        label: metered ? `${procLabel(t)}: reductions/s between two reads` : "not metered: a group",
      });
    }
  }
  return { folded: [...folds.values()].reduce((s, f) => s + f.count, 0) };
}

// ---- the subscriptions -----------------------------------------------------
// One AppsFloor per page. start() for a building (or the observer), stop()
// on leaving; it owns every observer:* subscription the floor needs and
// nothing else. onChange() after every payload: the page rebuilds its view.

export class AppsFloor {
  constructor({ onChange }) {
    this.onChange = onChange;
    this.target = null; // {node, label, member, members: [address]}
    this.focus = null;
    this.apps = null;
    this.trees = new Map();
    this.prev = new Map(); // pid -> [reductions, at ms]
    this.rates = new Map();
    this.unsubs = new Map(); // topic -> unsubscribe
  }

  get active() { return this.target != null; }

  start(target) {
    this.stop();
    this.target = { ...target };
    this.focus = null;
    this.subscribeApps();
  }

  stop() {
    for (const u of this.unsubs.values()) u();
    this.unsubs.clear();
    this.target = null;
    this.apps = null; this.trees.clear(); this.prev.clear(); this.rates.clear();
  }

  // the topics currently held, for checks and the info line
  topics() { return [...this.unsubs.keys()]; }

  setMember(member) {
    if (!this.target || member === this.target.member) return;
    const t = { ...this.target, member };
    const focus = this.focus;
    this.start(t);
    this.focus = focus;
    this.onChange(true);
  }

  setFocus(app) {
    if (!this.target || app === this.focus) return;
    this.focus = app || null;
    this.syncTrees();
    this.onChange(true);
  }

  topic(view) { return topicOf(this.target.node, this.target.member, view); }

  hold(topic, onPayload) {
    if (this.unsubs.has(topic)) return;
    const take = (p) => { if (this.unsubs.has(topic) && p && p.at) onPayload(p); };
    const unsub = bus.subscribe(topic, (ev, p) => { if (ev === "feed") take(p); }, {
      onJoin: take,
      onError: (reason) => { if (this.unsubs.has(topic)) onPayload({ at: new Date().toISOString(), error: `refused: ${reason}` }); },
    });
    this.unsubs.set(topic, unsub);
  }

  drop(topic) {
    const u = this.unsubs.get(topic);
    if (u) { u(); this.unsubs.delete(topic); }
  }

  subscribeApps() {
    this.hold(this.topic("apps"), (p) => {
      this.apps = p;
      this.syncTrees();
      this.onChange(false);
    });
  }

  // a tree feed for every application on screen, none for the rest
  syncTrees() {
    const want = new Set();
    for (const a of this.apps?.data?.apps ?? []) {
      if (!a.top_supervisor) continue;
      if (this.focus && this.focus !== a.name) continue;
      want.add(a.name);
    }
    const prefix = this.topic("tree:");
    for (const t of this.topics()) {
      if (t.startsWith(prefix) && !want.has(t.slice(prefix.length))) { this.drop(t); this.trees.delete(t.slice(prefix.length)); }
    }
    for (const name of want) this.hold(this.topic(`tree:${name}`), (p) => this.takeTree(name, p));
  }

  takeTree(name, p) {
    this.trees.set(name, p);
    if (p.data?.tree) {
      const at = Date.parse(p.at);
      const walk = (t) => {
        if (!t || t.group) return;
        if (t.pid && isNum(t.reductions)) {
          const was = this.prev.get(t.pid);
          if (was && at > was[1]) this.rates.set(t.pid, Math.max(0, (t.reductions - was[0]) / ((at - was[1]) / 1000)));
          this.prev.set(t.pid, [t.reductions, at]);
        }
        for (const c of t.children ?? []) walk(c);
      };
      walk(p.data.tree);
    }
    this.onChange(false);
  }

  snapshot(outer) {
    return appsSnapshot(outer, { target: this.target, apps: this.apps, trees: this.trees, rates: this.rates, focus: this.focus });
  }

  // the applications that can be put in focus, for the picker
  choices() {
    return (this.apps?.data?.apps ?? []).filter((a) => a.top_supervisor).map((a) => a.name).sort();
  }
}
