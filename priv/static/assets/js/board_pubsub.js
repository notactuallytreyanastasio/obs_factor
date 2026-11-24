// The board's PubSub tab: every Phoenix.PubSub server of every BEAM on the
// floor, and of the observer itself.
//
//   per app, then per member and server: topics and subscriptions now, with
//   their 15-minute sparklines (the tape's `pubsub:<member>:<server>`
//   metrics, so a replayed moment shows them as they were), and the top
//   topic patterns (the snapshot's inside.pubsub; ids blanked to #: the
//   report never names a topic)
//
//   a click on a pattern opens, beside the table, the topics in it, read
//   live from observer:<node>:<member>:pubsub, and a graph of the chosen
//   topic: the topic in the middle, its subscriber processes around it,
//   sized by mailbox and named, from
//   observer:<node>:<member>:pubsub:<server>:<topic>
//
//   a click on a subscriber shows it inline, with a button that opens it in
//   the Processes panel (api.openProc) when the page has one
//
// The observer's own patterns come from its listing feed (it has no report
// on the floor). The graph is always live, also during a replay: there is
// no tape of who was subscribed.

import * as bus from "./bus.js";
import { esc, num, bytes } from "./fmt.js";

const isNum = (v) => typeof v === "number" && Number.isFinite(v);
const short = (n) => String(n ?? "").replace(/^Elixir\./, "").replace(/^:/, "");
const shortNode = (n) => { const m = /^([^@]+)@(?:\d+\.\d+\.)?(\d+\.\d+)$/.exec(n ?? ""); return m ? `${m[1]}@.${m[2]}` : n ?? "?"; };
const OBSERVER = "observer";
const MAX_TOPICS = 12; // topics of a pattern shown as chips
const MAX_NODES = 24; // subscribers drawn

export class PubSubTab {
  constructor(board) {
    this.b = board;
    this.sel = null; // {app, member, server, pattern, feedMember, label}
    this.topic = null; // the topic graphed
    this.pid = null; // the subscriber shown inline
    this.list = { topic: null, unsub: null, data: null, error: null };
    this.graph = { topic: null, unsub: null, data: null, error: null };
    this.own = { unsub: null, data: null, error: null }; // the observer's listing
  }

  // ---- what there is ---------------------------------------------------------

  // [{app, label, rows: [{key, member, server, m}]}] from the tape's latest point
  groups() {
    const by = new Map();
    for (const k of this.b.keys("pubsub:")) {
      const m = this.b.latest(k);
      if (!m) continue;
      if (!by.has(m.app)) by.set(m.app, { app: m.app, label: m.app === OBSERVER ? "observer (this VM)" : this.b.label(m.app), rows: [] });
      by.get(m.app).rows.push({ key: k, member: m.member, server: m.server, m });
    }
    // the observer last: the floor's apps first
    return [...by.values()].sort((a, b) => (a.app === OBSERVER) - (b.app === OBSERVER) || a.label.localeCompare(b.label));
  }

  count() { return this.b.keys("pubsub:").length; }

  node(app) { return this.b.shown?.nodes.find((n) => n.id === app) ?? null; }

  // the member's address for an observer feed, or null ("-"): a cluster
  // member is keyed by its node name on the tape
  feedMember(app, member) {
    if (app === OBSERVER) return null;
    const ms = (this.node(app)?.inside?.members ?? []).filter((m) => m && m.address);
    if (ms.length < 2) return null;
    return (ms.find((m) => m.cluster?.distributed && m.cluster?.node === member) ?? ms[0]).address;
  }

  // the server as the snapshot shows it for this member: patterns and all
  serverOf(app, member, server) {
    if (app === OBSERVER) return this.ownServer(server);
    const inside = this.node(app)?.inside;
    if (!inside) return null;
    const ms = (inside.members ?? []).filter((m) => m && m.address);
    const list = ms.length > 1 ? (ms.find((m) => m.cluster?.distributed && m.cluster?.node === member) ?? ms[0])?.pubsub : inside.pubsub;
    return (list ?? []).find((s) => s.name === server) ?? null;
  }

  // the observer's own, from its listing feed, grouped by pattern as a report would
  ownServer(server) {
    const s = (this.own.data?.servers ?? []).find((x) => x.name === server);
    if (!s) return null;
    const by = new Map();
    for (const t of s.topics_list ?? []) {
      const p = by.get(t.pattern) ?? { pattern: t.pattern, topics: 0, subscriptions: 0 };
      p.topics++; p.subscriptions += t.subscriptions;
      by.set(t.pattern, p);
    }
    const top = [...by.values()].sort((a, b) => b.subscriptions - a.subscriptions || b.topics - a.topics || a.pattern.localeCompare(b.pattern));
    return { ...s, top: top.slice(0, 25), patterns_cut: Math.max(0, top.length - 25) };
  }

  // ---- feeds -------------------------------------------------------------------

  // Called whenever the tab is drawn: the observer's listing while the tab
  // shows, the selected pattern's listing and topic while one is open.
  sync(active) {
    this.follow(this.own, active ? "observer:observer:-:pubsub" : null, () => this.b.renderMonitor(false));
    const s = active ? this.sel : null;
    this.follow(this.list, s ? `observer:${s.app}:${s.feedMember ?? "-"}:pubsub` : null, () => { this.pickTopic(); this.paintSide(); });
    this.follow(this.graph, s && this.topic ? `observer:${s.app}:${s.feedMember ?? "-"}:pubsub:${s.server}:${this.topic}` : null, () => this.paintSide());
  }

  idle() { this.sync(false); }

  follow(slot, topic, onData) {
    if (slot.topic === topic) return;
    slot.unsub?.(); slot.unsub = null; slot.data = null; slot.error = null; slot.topic = topic;
    if (!topic) return;
    const take = (p) => {
      if (slot.topic !== topic || !p) return;
      if (p.error) slot.error = p.error; else if (p.data) { slot.data = p.data; slot.error = null; }
      onData();
    };
    slot.unsub = bus.subscribe(topic, (ev, p) => { if (ev === "feed") take(p); }, {
      onJoin: (p) => take(p),
      onError: (reason) => { if (slot.topic === topic) { slot.error = reason; onData(); } },
    });
  }

  // the topics of the selected pattern, busiest first
  topics() {
    const s = this.sel;
    const srv = (this.list.data?.servers ?? []).find((x) => x.name === s?.server);
    return (srv?.topics_list ?? []).filter((t) => t.pattern === s.pattern).sort((a, b) => b.subscriptions - a.subscriptions);
  }

  pickTopic() {
    const ts = this.topics();
    if (!ts.length || ts.some((t) => t.topic === this.topic)) return;
    this.topic = ts[0].topic; this.pid = null;
    this.sync(true);
  }

  // ---- clicks -------------------------------------------------------------------

  onClick(e) {
    const pat = e.target.closest("[data-ps-pat]");
    if (pat) {
      const [app, member, server, pattern] = JSON.parse(pat.dataset.psPat);
      const same = this.sel && this.sel.app === app && this.sel.member === member && this.sel.server === server && this.sel.pattern === pattern;
      this.sel = same ? null : { app, member, server, pattern, feedMember: this.feedMember(app, member) };
      this.topic = null; this.pid = null;
      this.b.renderMonitor();
      return true;
    }
    const t = e.target.closest("[data-ps-topic]");
    if (t) { this.topic = t.dataset.psTopic; this.pid = null; this.sync(true); this.paintSide(); return true; }
    const p = e.target.closest("[data-ps-pid]");
    if (p) { this.pid = this.pid === p.dataset.psPid ? null : p.dataset.psPid; this.paintSide(); return true; }
    if (e.target.closest("[data-ps-open]")) { this.openProc(); return true; }
    if (e.target.closest("[data-ps-close]")) { this.sel = null; this.topic = null; this.pid = null; this.b.renderMonitor(); return true; }
    return false;
  }

  openProc() {
    const s = this.sel;
    if (!s || !this.pid || !this.b.api.openProc) return;
    const n = this.node(s.app);
    const src = s.app === OBSERVER
      ? { node: OBSERVER, member: null, label: "observer", sub: "this VM", onFloor: false }
      : { node: s.app, member: s.feedMember, label: n?.label ?? s.app, sub: s.feedMember ? s.member : null, onFloor: true };
    this.b.api.openProc({ src, pid: this.pid, key: `${src.node}:${src.member ?? "-"}:${this.pid}` });
  }

  // ---- drawing --------------------------------------------------------------------

  tab() {
    this.sync(true);
    const gs = this.groups();
    if (!gs.length) return `<p class="bd-empty">No PubSub server on the tape at this moment. Apps report theirs with factory_report (its <code>pubsub</code> section); the observer counts its own.</p>`;
    const rows = gs.map((g) => `<tr class="grp"${g.app === OBSERVER ? "" : ` data-node="${esc(g.app)}"`}><td colspan="5">${esc(g.label)} <span class="dim">${g.rows.length} server${g.rows.length === 1 ? "" : "s"}</span></td></tr>` +
      g.rows.map(({ key, member, server, m }) => {
        const [t, t0] = this.b.move(key, "topics"), [s, s0] = this.b.move(key, "subs");
        const who = member !== g.app && member !== OBSERVER ? ` <span class="dim">${esc(shortNode(member))}</span>` : "";
        return `<tr><td class="nm" title="${esc(server)} on ${esc(member)}">${esc(short(server))}${who}</td><td class="r">${isNum(t) ? num(t) : "–"} ${this.b.delta("topics", t, t0)}</td><td>${this.b.spark(key, "topics")}</td><td class="r">${isNum(s) ? num(s) : "–"} ${this.b.delta("subs", s, s0)}</td><td>${this.b.spark(key, "subs")}</td></tr>`;
      }).join("")).join("");

    const tops = gs.flatMap((g) => g.rows.map(({ member, server }) => this.topTable(g, member, server))).join("");
    const side = this.sel ? `<div class="ps-side" id="ps-side">${this.sideHtml()}</div>` : "";
    return `<table><thead><tr><th>server</th><th class="r">topics</th><th>15m</th><th class="r">subscriptions</th><th>15m</th></tr></thead><tbody>${rows}</tbody></table>
      <div class="ps-wrap"><div class="ps-tops">${tops}</div>${side}</div>
      <p class="bd-foot">Patterns are topics with their ids blanked to # (the report names no topic). Click one for its topics and a live graph of who is subscribed. Broadcast rates are not observable: Phoenix.PubSub emits no telemetry (factory_report's opt-in FactoryReport.PubSub.broadcast/3 counts them as a <code>pubsub.broadcast</code> stream).</p>`;
  }

  topTable(g, member, server) {
    const s = this.serverOf(g.app, member, server);
    const title = `${esc(g.app === OBSERVER ? "observer" : g.label)}${member !== g.app && member !== OBSERVER ? ` ${esc(shortNode(member))}` : ""}: ${esc(short(server))}`;
    if (!s) return g.app === OBSERVER && !this.own.data ? `<h4>${title}</h4><p class="bd-empty">${this.own.error ? esc(this.own.error) : "reading…"}</p>` : "";
    if (s.counts_only) return `<h4>${title}</h4><p class="bd-empty">${esc(s.counts_only)}</p>`;
    if (!(s.top ?? []).length) return `<h4>${title}</h4><p class="bd-empty">No topics.</p>`;
    const sel = this.sel;
    const rows = s.top.map((p) => {
      const on = sel && sel.app === g.app && sel.member === member && sel.server === server && sel.pattern === p.pattern;
      return `<tr class="ps-pat${on ? " on" : ""}" data-ps-pat="${esc(JSON.stringify([g.app, member, server, p.pattern]))}"><td class="nm" title="${esc(p.pattern)}">${esc(p.pattern)}</td><td class="r">${num(p.topics)}</td><td class="r">${num(p.subscriptions)}</td></tr>`;
    }).join("");
    const cut = s.patterns_cut ? `<tr><td class="nm dim" colspan="3">${num(s.patterns_cut)} more not shown</td></tr>` : "";
    return `<h4>${title}${isNum(s.subscribers) ? ` <span class="dim">${num(s.subscribers)} processes</span>` : ""}</h4><table><thead><tr><th>pattern</th><th class="r">topics</th><th class="r">subs</th></tr></thead><tbody>${rows}${cut}</tbody></table>`;
  }

  // redraw the side panel alone: a feed tick must not redraw the board
  paintSide() {
    const el = this.b.el.querySelector("#ps-side");
    if (el) el.innerHTML = this.sideHtml();
  }

  sideHtml() {
    const s = this.sel;
    const head = `<div class="ps-h"><b title="${esc(s.pattern)}">${esc(s.pattern)}</b><button type="button" class="fi-x" data-ps-close aria-label="Close">×</button></div>`;
    if (this.list.error) return `${head}<p class="bd-empty">${esc(this.list.error)}</p>`;
    if (!this.list.data) return `${head}<p class="bd-empty">reading ${esc(short(s.server))}…</p>`;
    const ts = this.topics();
    if (!ts.length) return `${head}<p class="bd-empty">No topic of this pattern now.</p>`;
    const chips = ts.slice(0, MAX_TOPICS).map((t) => `<button type="button" class="bd-chip${t.topic === this.topic ? " on" : ""}" data-ps-topic="${esc(t.topic)}" title="${esc(t.topic)}">${esc(t.topic.length > 28 ? `${t.topic.slice(0, 27)}…` : t.topic)} <i>${num(t.subscriptions)}</i></button>`).join("");
    const more = ts.length > MAX_TOPICS ? `<span class="bd-hint">+${ts.length - MAX_TOPICS} more</span>` : "";
    return `${head}<div class="ps-chips">${chips}${more}</div>${this.graphHtml()}${this.procHtml()}<p class="bd-hint">live${this.b.api.timeline?.replaying ? " (the board is replaying; who is subscribed is not on the tape)" : ""} · circle size: mailbox</p>`;
  }

  graphHtml() {
    if (this.graph.error) return `<p class="bd-empty">${esc(this.graph.error)}</p>`;
    const d = this.graph.data;
    if (!d) return `<p class="bd-empty">reading subscribers…</p>`;
    const subs = d.subscribers ?? [];
    const shown = subs.slice(0, MAX_NODES);
    // the labels stand outside the ring: the view box is wider than it
    const W = 280, H = 230, cx = W / 2, cy = H / 2, R = 78, PAD = 70;
    const name = (p) => (p.module || p.registered_name ? short(p.module ?? p.registered_name).split(".").slice(-2).join(".") : p.pid);
    const radius = (p) => 5 + Math.min(14, 3 * Math.log10(1 + (p.message_queue_len ?? 0)) * 1.6);
    const nodes = shown.map((p, i) => {
      const a = (i / Math.max(shown.length, 1)) * 2 * Math.PI - Math.PI / 2;
      const x = cx + R * Math.cos(a), y = cy + R * Math.sin(a), r = radius(p);
      const anchor = Math.cos(a) > 0.2 ? "start" : Math.cos(a) < -0.2 ? "end" : "middle";
      const lx = x + Math.cos(a) * (r + 4), ly = y + Math.sin(a) * (r + 4) + (Math.abs(Math.cos(a)) <= 0.2 ? (Math.sin(a) > 0 ? 9 : -3) : 3);
      const on = p.pid === this.pid;
      return `<g class="ps-n k-${esc(p.kind)}${on ? " on" : ""}${(p.message_queue_len ?? 0) >= 100 ? " bad" : ""}" data-ps-pid="${esc(p.pid)}"><title>${esc(p.pid)} ${esc(p.module ?? p.registered_name ?? p.initial_call ?? "")} · mailbox ${p.message_queue_len} · ${bytes(p.memory)}</title>
        <line x1="${cx}" y1="${cy}" x2="${x.toFixed(1)}" y2="${y.toFixed(1)}"/><circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${r.toFixed(1)}"/>
        <text x="${lx.toFixed(1)}" y="${ly.toFixed(1)}" text-anchor="${anchor}">${esc(name(p).slice(0, 18))}</text></g>`;
    }).join("");
    const t = d.topic ?? this.topic ?? "";
    const center = `<g class="ps-c"><circle cx="${cx}" cy="${cy}" r="22"/><text x="${cx}" y="${cy + 3}" text-anchor="middle">${esc(t.length > 14 ? `${t.slice(0, 13)}…` : t)}</text></g>`;
    const cut = subs.length - shown.length + (d.subscribers_cut ?? 0);
    return `<svg class="ps-graph" viewBox="${-PAD} 0 ${W + 2 * PAD} ${H}" role="img" aria-label="${esc(t)}: ${subs.length} subscribers">${nodes}${center}</svg>
      <p class="bd-hint">${num(d.subscriptions)} subscription${d.subscriptions === 1 ? "" : "s"} by ${num(subs.length + (d.subscribers_cut ?? 0))} process${subs.length === 1 ? "" : "es"}${cut > 0 ? `, ${num(cut)} not drawn` : ""} · <span class="k-liveview">● LiveView</span> <span class="k-channel">● channel</span> <span class="k-process">● process</span></p>`;
  }

  procHtml() {
    const p = (this.graph.data?.subscribers ?? []).find((x) => x.pid === this.pid);
    if (!p) return "";
    const row = (k, v) => `<tr><td class="nm">${k}</td><td class="r">${v}</td></tr>`;
    return `<table class="ps-proc">${row("pid", esc(p.pid))}${row("kind", esc(p.kind) + (p.module ? ` ${esc(short(p.module))}` : ""))}${row("name", esc(p.registered_name ?? "–"))}${row("initial call", esc(p.initial_call ?? "–"))}${row("current", esc(p.current_function ?? "–"))}${row("mailbox", num(p.message_queue_len))}${row("memory", bytes(p.memory))}${row("subscribed", `${num(p.entries)}×${p.fastlane ? " (fastlane)" : ""}`)}</table>
      ${this.b.api.openProc ? `<button type="button" class="bd-chip" data-ps-open>Open in Processes</button>` : ""}`;
  }
}
