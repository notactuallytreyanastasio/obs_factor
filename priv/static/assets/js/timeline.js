// The timeline: the tape (ObsFactor.Tape, channel `tape`) along the bottom
// of the screen. Every tick of the floor is on it.
//
// From the top, on one canvas:
//   windows   the stretches someone saved, as labelled brackets. Click one
//             to open it: it is selected, the view fits it, the floor goes
//             to its start.
//   marks     what happened to the objectives: a flame where a fire started
//             or came back, an eye where someone looked, a drop where it was
//             put out, a grey puff where it burned out with nobody coming,
//             a diamond where a building was flagged
//   overview  the worst of each column: teal where there is tape (none: a
//             gap, the observer was down), amber warnings, red alerts
//             (taller for more), a bright cap for buildings down, a pink
//             line for 5xx
//   lanes     (expanded, key t) one row per building that burned in view,
//             worst first: red where it had an alert, amber a warning. A
//             fire that never goes out is one long bar on its own row, and
//             cannot hide a short one somewhere else.
//   axis      the time, UTC
//
// Mouse and touch: click to go to a moment; drag to select a stretch; drag
// a selection's edge to trim it; drag the playhead to scrub; scroll to zoom
// around the pointer; shift-scroll (or a sideways swipe) to pan. Keys: see
// HELP below, or press ? on the page.
//
// The page is told through callbacks: onFrame(snapshot, at) to draw a
// moment, onLive() to go back to the live floor, onMode(replaying, at),
// onWindow() when the stretch in view or selected changes, onNode(id) to
// go to a building, openFires() to read a stretch, label(id), who().

import * as bus from "./bus.js";
import { esc } from "./fmt.js";

const SPANS = [["15m", 15 * 60e3], ["1h", 3600e3], ["6h", 6 * 3600e3], ["24h", 86400e3], ["7d", 7 * 86400e3]];
const MIN_SPAN = 60e3, MAX_SPAN = 31 * 86400e3;
const SPEEDS = [1, 4, 16, 64, 256];
const KIND = { seen: "fire", "came back": "fire", reopened: "fire", pinned: "pin", looking: "look", "crossed off": "out", "cleared itself": "puff" };
const WORD = { fire: "fire", pin: "flagged", look: "looking", out: "put out", puff: "burned out" };
const MIN_REQ_MS = 90; // at most ~11 frames a second while playing fast
const LANES_SHOWN = 8, LANE_H = 13, GUTTER = 110;
// the BEAM rows (expanded): one per node, each cell its number against the
// node's own median over the view; click the header to change the number
const HEAT_ROWS = 10, HEAT_H = 9;
const HEAT_METRICS = [["reds", "reductions/s"], ["rq", "run queue on schedulers"], ["mem", "memory"], ["mbox", "biggest mailbox"], ["procs", "processes"]];
// what of the BEAM wire goes on the marks row, and how it is drawn
const WIRE_MARK = { deploy: "deploy", crash: "crash", restart: "restart", joined: "restart", left: "crash", leader: "leader", partition: "crash", outlier: "odd", anomaly: "odd" };
const HELP = [
  ["click", "go to that moment"], ["drag", "select a stretch"], ["drag an edge", "trim the selection"], ["drag the playhead", "scrub"],
  ["scroll", "zoom around the pointer"], ["shift-scroll", "pan"], ["Space", "play / pause; live: instant replay"],
  [", .", "a frame back / on (Shift: a minute)"], ["[ ]", "previous / next fire"], ["End", "back to live"],
  ["w", "save the selection as a window"], ["t", "lanes: one row per building"], ["?", "this card"],
];

const pad = (n) => String(n).padStart(2, "0");
function hms(ms) { const d = new Date(ms); return `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}`; }
function dayHm(ms) { const d = new Date(ms); return `${d.toLocaleDateString("en-GB", { timeZone: "UTC", day: "numeric", month: "short" })} ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`; }
function when(ms) { return Date.now() - ms > 20 * 3600e3 ? dayHm(ms) : hms(ms); }
export function span(ms) {
  if (ms == null) return "-";
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 48) return `${h}h ${pad(m % 60)}m`;
  return `${Math.floor(h / 24)}d ${h % 24}h`;
}
const typing = (el) => el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName));
const store = { get: (k) => { try { return localStorage.getItem(k); } catch { return null; } }, set: (k, v) => { try { localStorage.setItem(k, v); } catch {} } };

export class Timeline {
  constructor(api) {
    this.api = api;
    this.el = document.getElementById("timeline");
    this.ok = false; // the tape answered
    this.range = null; // {from, to, frames}
    this.tick = 5000;
    this.spanMs = 3600e3;
    this.live = true;
    this.cursor = null; // the moment shown, while replaying
    this.shownAt = null; this.nextAt = null; // the frame on screen and the one after it
    this.playing = false;
    this.speedI = 0;
    this.viewEnd = null; // null: the view follows now; else where it ends
    this.sel = null; // {a, b, id?} the selected stretch; id when it is a saved window
    this.index = null; // {from, to, step, buckets}
    this.marks = [];
    this.lanes = []; // [{node, alert_ms, warn_ms, spans: [{sev, a, b, text}]}], worst first
    this.windows = [];
    this.heatSeries = []; // [[at, {"beam:node": {...}}]] over the view
    this.heatMetric = store.get("obs.tl.heat") ?? "reds";
    this.wmarks = []; // BEAM wire items drawn as marks
    this.trimming = null; // the window whose edges are being dragged
    this.expanded = store.get("obs.tl.expanded") != null ? store.get("obs.tl.expanded") === "1" : window.innerHeight >= 820;
    this.inflight = false; this.pending = null; this.lastReq = 0;
    this.hover = null; // {x, y}
    this.build();
    this.connect();
    requestAnimationFrame((t) => this.loop(t));
  }

  get replaying() { return !this.live; }

  build() {
    this.el.innerHTML = `
      <div class="tl-ctl">
        <button type="button" class="tl-live" data-a="live" title="Back to the live floor (End)"><span class="dot"></span>LIVE</button>
        <button type="button" class="tl-b" data-a="prev" title="Previous fire ([)" aria-label="Previous fire"><svg viewBox="0 0 24 24"><path d="M6 5v14M19 5l-10 7 10 7z"/></svg></button>
        <button type="button" class="tl-b tl-play" data-a="play" title="Play / pause (Space). On the live floor: instant replay of the last 2 minutes" aria-label="Play"><svg viewBox="0 0 24 24"><path class="pl" d="M7 5l12 7-12 7z"/><path class="pa" d="M7 5h4v14H7zM14 5h4v14h-4z"/></svg></button>
        <button type="button" class="tl-b" data-a="next" title="Next fire (])" aria-label="Next fire"><svg viewBox="0 0 24 24"><path d="M18 5v14M5 5l10 7-10 7z"/></svg></button>
        <button type="button" class="tl-speed" data-a="speed" title="Playback speed">1×</button>
      </div>
      <div class="tl-strip">
        <canvas aria-label="The tape. Click to replay a moment, drag to select a stretch, scroll to zoom."></canvas>
        <div class="tl-tip" hidden></div>
        <button type="button" class="tl-follow" data-a="follow" hidden title="Slide the view back to now (the floor stays where it is)">now ⇥</button>
      </div>
      <div class="tl-side">
        <div class="tl-spans" role="group" aria-label="How much of the tape to show">
          ${SPANS.map(([l, ms]) => `<button type="button" data-span="${ms}">${l}</button>`).join("")}
        </div>
        <button type="button" class="tl-tool" data-a="windows" aria-expanded="false" title="Saved windows: open, loop, trim, prune">Windows <b class="n">0</b></button>
        <button type="button" class="tl-tool sq" data-a="expand" title="Lanes: one row per building that burned (t)" aria-pressed="false"><svg viewBox="0 0 24 24"><path d="M4 7h16M4 12h10M4 17h13"/></svg></button>
        <button type="button" class="tl-tool sq" data-a="help" title="How to drive the timeline (?)">?</button>
      </div>
      <div class="tl-sel" hidden></div>
      <button type="button" class="tl-back" data-a="live" hidden></button>
      <div class="tl-help" hidden><h4>The timeline</h4><dl>${HELP.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join("")}</dl>
        <p>Windows are kept at full detail until pruned; the rest of the tape keeps every tick for 6 h, then one a minute for 7 days.</p></div>
      <aside class="tl-wins" hidden aria-label="Saved windows"></aside>
      <div class="tl-undo" hidden role="status"></div>
      <div class="tl-badge" hidden></div>`;
    this.canvas = this.el.querySelector("canvas");
    this.tip = this.el.querySelector(".tl-tip");
    this.selEl = this.el.querySelector(".tl-sel");
    this.badge = this.el.querySelector(".tl-badge");
    this.back = this.el.querySelector(".tl-back");
    this.help = this.el.querySelector(".tl-help");
    this.winsEl = this.el.querySelector(".tl-wins");
    this.followBtn = this.el.querySelector(".tl-follow");
    this.undoEl = this.el.querySelector(".tl-undo");
    this.el.addEventListener("click", (e) => this.onClick(e));
    this.el.addEventListener("submit", (e) => { e.preventDefault(); this.onSubmit(e.target); });
    this.el.addEventListener("change", (e) => { if (e.target.matches("[data-pick]")) this.renderPruneButton(); });
    const c = this.canvas;
    c.addEventListener("pointerdown", (e) => this.down(e));
    c.addEventListener("pointermove", (e) => this.move(e));
    c.addEventListener("pointerup", (e) => this.up(e));
    c.addEventListener("pointercancel", () => { this.drag = null; });
    c.addEventListener("pointerleave", () => { this.hover = null; this.tip.hidden = true; c.style.cursor = ""; this.draw(); });
    c.addEventListener("wheel", (e) => this.wheel(e), { passive: false });
    c.addEventListener("dblclick", (e) => { if (!this.windowAt(e.offsetX, e.offsetY) && this.sel) this.zoomToSel(); });
    window.addEventListener("resize", () => { this.size(); this.refetch(); });
    document.addEventListener("keydown", (e) => this.key(e));
    document.addEventListener("pointerdown", (e) => {
      if (!this.help.hidden && !e.target.closest(".tl-help, [data-a=help]")) this.help.hidden = true;
    });
    this.size();
  }

  onClick(e) {
    const b = e.target.closest("button");
    if (!b) return;
    if (b.dataset.span) {
      // on a phone only the window in use is shown: tapping it takes the next one
      if (+b.dataset.span === this.spanMs && window.innerWidth <= 640) { const i = SPANS.findIndex(([, ms]) => ms === this.spanMs); return this.setSpan(SPANS[(i + 1) % SPANS.length][1]); }
      return this.setSpan(+b.dataset.span);
    }
    const a = b.dataset.a, id = b.closest("[data-win]")?.dataset.win;
    const w = id && this.windows.find((x) => String(x.id) === id);
    switch (a) {
      case "live": return this.goLive();
      case "play": return this.togglePlay();
      case "prev": return this.jumpFire(-1);
      case "next": return this.jumpFire(1);
      case "speed": this.speedI = (this.speedI + 1) % SPEEDS.length; return this.render();
      case "follow": this.viewEnd = null; this.refetch(); return this.render();
      case "expand": return this.setExpanded(!this.expanded);
      case "help": this.help.hidden = !this.help.hidden; return;
      case "windows": return this.toggleWins();
      case "loop": this.seek(this.sel.a); return this.play(true);
      case "zoom": return this.zoomToSel();
      case "clear": this.trimming = null; return this.setSel(null);
      case "fires": return this.api.openFires?.();
      case "writeup": {
        if (!this.sel) return;
        const win = this.sel.id && this.windows.find((x) => x.id === this.sel.id);
        return this.api.openWriteup?.({ from: this.sel.a, to: this.sel.b, window: win?.id, title: win?.title });
      }
      case "wwriteup": return w && this.api.openWriteup?.({ from: w.from, to: w.to, window: w.id, title: w.title });
      case "save": this.saving = true; return this.renderSel(true);
      case "unsave": this.saving = false; return this.renderSel();
      case "trim-save": return this.saveTrim();
      case "trim-cancel": { const t = this.trimming; this.trimming = null; return this.setSel(t ? { a: t.from, b: t.to, id: t.id } : null); }
      case "open": return w && this.openWindow(w);
      case "wloop": if (w) { this.openWindow(w, false); this.play(true); } return;
      case "trim": return w && this.startTrim(w);
      case "rename": this.renaming = w?.id; return this.renderWins();
      case "prune": return w && this.prune([w.id]);
      case "prune-picked": { const ids = this.picked(); return ids.length && this.prune(ids); }
      case "restore": return w && this.restore([w.id]);
      case "undo": return this.restore(this.undoIds ?? []);
      case "note": this.noting = w?.id; return this.renderWins();
      case "link": return w && this.copyLink(w);
      case "pick-all": { const boxes = [...this.winsEl.querySelectorAll("[data-pick]")]; const on = boxes.some((x) => !x.checked); boxes.forEach((x) => { x.checked = on; }); return this.renderPruneButton(); }
      case "wins-close": return this.toggleWins(false);
    }
  }

  onSubmit(form) {
    const title = form.querySelector("input[name=title]")?.value ?? "";
    if (form.dataset.form === "save" && this.sel) {
      this.write("save_window", { from: Math.round(this.sel.a), to: Math.round(this.sel.b), title, by: this.api.who?.() || null })
        .then((r) => { this.saving = false; this.sel = { a: r.window.from, b: r.window.to, id: r.window.id }; this.flash(`saved “${r.window.title}”: kept at full detail until pruned`); this.render(); this.api.onWindow?.(this.window()); });
    } else if (form.dataset.form === "note") {
      const w = this.windows.find((x) => x.id === +form.dataset.id);
      const note = form.querySelector("textarea").value;
      if (w) this.write("save_window", { id: w.id, from: w.from, to: w.to, title: w.title, note }).then(() => { this.noting = null; this.renderWins(); this.api.onWindow?.(this.window()); });
    } else if (form.dataset.form === "rename") {
      const w = this.windows.find((x) => x.id === +form.dataset.id);
      if (w) this.write("save_window", { id: w.id, from: w.from, to: w.to, title }).then(() => { this.renaming = null; this.renderWins(); });
    }
  }

  // ---- the channel -----------------------------------------------------

  connect() {
    bus.subscribe("tape", (ev, p) => {
      if (ev === "tick") this.onTick(p);
      else if (ev === "windows") this.setWindows(p.windows);
    }, {
      onJoin: (r) => {
        if (r.error) return this.fail(r.error);
        this.ok = true; this.range = r.range; this.tick = r.tick_ms || 5000;
        document.body.classList.add("has-tape");
        this.el.hidden = false;
        this.setWindows(r.windows ?? []);
        this.size(); this.refetch();
        const q = new URLSearchParams(location.search);
        const t = q.get("t"), wid = q.get("w");
        if (wid && !this.started) {
          const w = this.active().find((x) => String(x.id) === wid);
          if (w) setTimeout(() => this.openWindow(w), 300); else this.flash(`window ${wid} is not on the tape: pruned, or never saved here`);
        } else if (t && !this.started) { const ms = /^\d+$/.test(t) ? +t : Date.parse(t); if (ms) this.seek(ms); }
        this.started = true;
        this.render();
        if (!store.get("obs.tl.helped")) { store.set("obs.tl.helped", "1"); this.help.hidden = false; setTimeout(() => { this.help.hidden = true; }, 9000); }
      },
      onError: (why) => this.fail(why),
    });
  }

  fail(why) {
    this.ok = false;
    this.error = why;
    console.error(`obs_factor timeline: ${why}`);
    document.body.classList.remove("has-tape");
    this.el.hidden = true;
    this.api.onWindow?.(this.window());
  }

  write(event, payload) {
    return bus.push("tape", event, payload).catch((e) => { this.flash(`${event.replace("_", " ")}: ${e.message}`); throw e; });
  }

  // saved and not pruned; the pruned are listed for an hour, to restore
  active() { return this.windows.filter((w) => !w.pruned_at); }

  setWindows(list) {
    this.windows = list;
    if (this.sel?.id && !this.active().some((w) => w.id === this.sel.id)) this.sel = { ...this.sel, id: null };
    this.el.querySelector("[data-a=windows] .n").textContent = String(this.active().length);
    this.renderWins(); this.renderSel(); this.draw();
  }

  onTick(t) {
    if (!this.range) return;
    this.range.to = t.at; this.range.frames++;
    if (this.range.from == null) this.range.from = t.at;
    // the strip grows by the tick at once; the whole strip is read again now and then
    if (this.index && t.at >= this.index.from) {
      const b = this.index.buckets, step = this.index.step;
      const start = this.index.from + Math.floor((t.at - this.index.from) / step) * step;
      const last = b[b.length - 1];
      if (last && last[0] === start) {
        last[1]++; last[2] = Math.max(last[2], t.alerts); last[3] = Math.max(last[3], t.warns); last[4] = Math.max(last[4], t.down);
        if (t.err_rps != null) last[5] = Math.max(last[5] ?? 0, t.err_rps);
      } else b.push([start, 1, t.alerts, t.warns, t.down, t.err_rps, t.rps]);
    }
    // the lanes grow too: a building still burning stretches its last bar
    for (const a of t.top ?? []) {
      const lane = this.lanes.find((l) => l.node === (a.node ?? null));
      const sp = lane?.spans.filter((s) => s.sev === a.severity).pop();
      if (sp && t.at - sp.b <= 90_000) sp.b = Math.max(sp.b, t.at);
    }
    // the whole strip again every 20 s, and at once when a fire starts or goes out
    if (performance.now() - (this.indexAt ?? 0) > 20_000 || t.fires !== this.lastFires) this.refetch();
    this.lastFires = t.fires;
    this.draw();
  }

  // the stretch in view
  view() {
    const to = this.viewEnd == null ? Date.now() : this.viewEnd;
    return { from: to - this.spanMs, to };
  }

  // what Fires reads: the selection, else the view
  window() {
    const v = this.view();
    if (this.sel) {
      const w = this.sel.id && this.windows.find((x) => x.id === this.sel.id);
      return { from: Math.round(this.sel.a), to: Math.round(this.sel.b), selected: true, title: w?.title ?? null, note: w?.note ?? null, id: w?.id ?? null };
    }
    return { from: Math.round(v.from), to: Math.round(v.to), selected: false, live: this.viewEnd == null };
  }

  refetch() {
    this.indexAt = performance.now();
    clearTimeout(this.rt);
    this.rt = setTimeout(() => { this.fetchIndex(); this.fetchMarks(); this.fetchLanes(); this.fetchBeam(); }, 120);
  }

  fetchIndex() {
    if (!this.ok) return;
    const v = this.view();
    const from = Math.round(v.from), to = Math.round(v.to + (this.viewEnd == null ? this.tick * 2 : 0));
    bus.push("tape", "index", { from, to, buckets: Math.max(40, Math.min(1200, Math.floor(this.plotW() / 3))) })
      .then((r) => { this.index = r; this.draw(); })
      .catch((e) => console.error(`obs_factor timeline: index: ${e.message}`));
  }

  fetchMarks() {
    if (!this.ok) return;
    const v = this.view();
    bus.push("tape", "marks", this.readWindow())
      .then((r) => {
        this.marks = r.marks.map(([at, kind, id, node, severity, title, by]) => ({ at, kind: KIND[kind] ?? "fire", raw: kind, id, node, severity, title, by }));
        this.draw();
      })
      .catch((e) => console.error(`obs_factor timeline: marks: ${e.message}`));
  }

  // [from, to] for a read: the view and a minute past it, never over the
  // server's 31 days (at full zoom-out the extra minute went over, every
  // read was refused, and the rows quietly stayed as they were)
  readWindow() {
    const v = this.view();
    const to = Math.round(v.to + 60_000);
    return { from: Math.max(Math.round(v.from), to - MAX_SPAN), to };
  }

  // the BEAM rows' numbers and the wire's marks for the view
  fetchBeam() {
    if (!this.ok) return;
    const { from, to } = this.readWindow();
    if (this.expanded)
      bus.push("tape", "series", { from, to, points: Math.max(60, Math.min(600, Math.floor(this.plotW() / 4))), prefix: "beam:" })
        .then((r) => { this.heatSeries = r.series; this.size(); this.draw(); })
        .catch((e) => console.error(`obs_factor timeline: beam rows: ${e.message}`));
    // only the kinds drawn, and up to 5,000 of them: the newest 500 of the
    // whole wire covered a few hours of a week's view
    bus.push("tape", "wire", { from, to, kinds: Object.keys(WIRE_MARK), limit: 5000 })
      .then((r) => { this.wmarks = r.wire; this.wmarksCut = r.wire.length >= 5000; this.draw(); })
      .catch((e) => console.error(`obs_factor timeline: wire marks: ${e.message}`));
  }

  heatKeys() {
    const ks = new Set();
    for (const [, m] of this.heatSeries) for (const k of Object.keys(m)) ks.add(k);
    return [...ks].sort().slice(0, HEAT_ROWS);
  }

  heatValue(m, metric) {
    if (!m) return null;
    if (metric === "rq") return typeof m.rq === "number" && m.sched ? m.rq / m.sched : null;
    const v = m[metric];
    return typeof v === "number" ? v : null;
  }

  fetchLanes() {
    if (!this.ok) return;
    const v = this.view();
    bus.push("tape", "lanes", this.readWindow())
      .then((r) => {
        const by = new Map();
        for (const [node, sev, a, b, , text] of r.lanes) {
          const k = node ?? null;
          if (!by.has(k)) by.set(k, { node: k, alert_ms: 0, warn_ms: 0, spans: [] });
          const l = by.get(k);
          // one frame is a tick long, not zero: a short fire still shows
          const b2 = Math.max(b, a + this.tick);
          l.spans.push({ sev, a, b: b2, text });
          l[sev === "alert" ? "alert_ms" : "warn_ms"] += b2 - a;
        }
        this.lanes = [...by.values()].sort((x, y) => y.alert_ms - x.alert_ms || y.warn_ms - x.warn_ms);
        this.size();
        this.draw();
      })
      .catch((e) => console.error(`obs_factor timeline: lanes: ${e.message}`));
  }

  // ---- moving through the tape ------------------------------------------

  seek(t) {
    if (!this.ok || !this.range?.to) return;
    const latest = this.range.to;
    if (t >= latest - this.tick / 2 && !this.sel) return this.goLive();
    t = Math.max(this.range.from ?? t, Math.min(t, latest));
    const wasLive = this.live;
    this.live = false;
    this.cursor = t;
    const v = this.view();
    // keep the moment in view: past either edge, the view follows it
    if (t < v.from || t > v.to) this.panTo(t, 0.25);
    this.request(t, true);
    if (wasLive) this.api.onWindow?.(this.window());
    this.render();
  }

  // the view ending so that t sits `at` of a span from its right edge
  panTo(t, at) {
    const end = t + this.spanMs * at;
    this.viewEnd = end >= Date.now() - this.tick ? null : end;
    this.refetch();
  }

  request(t, now = false) {
    if (this.inflight) { this.pending = t; return; }
    if (!now && performance.now() - this.lastReq < MIN_REQ_MS) { this.pending = t; return; }
    this.inflight = true; this.lastReq = performance.now();
    bus.push("tape", "frame", { at: Math.round(t) })
      .then((r) => {
        if (this.live) return; // went live while it was on its way
        this.shownAt = r.at; this.nextAt = r.next; this.badgeError = null;
        this.api.onFrame(r.snapshot, r.at);
        this.api.onMode?.(true, this.cursor);
        this.renderBadge();
      })
      .catch((e) => { console.error(`obs_factor timeline: frame: ${e.message}`); this.badgeError = e.message; this.renderBadge(); })
      .finally(() => {
        this.inflight = false;
        if (this.pending != null) { const p = this.pending; this.pending = null; if (!this.live) this.request(p); }
      });
  }

  goLive() {
    const was = this.live;
    this.live = true; this.playing = false; this.cursor = null; this.pending = null;
    this.shownAt = null; this.nextAt = null; this.badgeError = null;
    // back to now means the view too: the selection stays, wherever it is
    this.viewEnd = null;
    if (!was) { this.api.onLive(); this.api.onMode?.(false, null); this.refetch(); this.api.onWindow?.(this.window()); }
    if (location.search.includes("t=")) { const u = new URL(location.href); u.searchParams.delete("t"); history.replaceState(null, "", u); }
    this.render();
  }

  togglePlay() {
    if (this.live) return this.instantReplay();
    this.play(!this.playing);
  }

  play(on) {
    if (this.live) return;
    this.playing = on;
    this.lastT = null;
    if (!on) this.remember();
    this.render();
  }

  instantReplay() {
    if (!this.ok || !this.range?.to) return;
    // the last two minutes, not a loop of some stretch selected earlier
    if (this.sel) this.setSel(null);
    this.speedI = 1;
    this.seek(this.range.to - 120_000);
    this.play(true);
  }

  // a paused moment is in the address: send it to someone and they see it too
  remember() {
    if (this.live || this.cursor == null) return;
    const u = new URL(location.href);
    u.searchParams.set("t", new Date(Math.round(this.cursor)).toISOString());
    history.replaceState(null, "", u);
  }

  step(dir, big) {
    if (!this.ok) return;
    const base = this.live ? this.range.to : this.shownAt ?? this.cursor;
    if (!big && dir > 0 && this.nextAt) return this.seek(this.nextAt);
    this.play(false);
    this.seek(base + dir * (big ? 60_000 : this.tick));
  }

  // fires to jump between: the starts of the lanes' alert runs (a run is
  // one fire, however many objectives it opened), then the fire marks
  fireStarts() {
    const s = new Set();
    for (const l of this.lanes) for (const sp of l.spans) if (sp.sev === "alert") s.add(sp.a);
    for (const m of this.marks) if (m.kind === "fire") s.add(m.at);
    return [...s].sort((a, b) => a - b);
  }

  jumpFire(dir) {
    const at = this.live ? Date.now() : this.cursor;
    const starts = this.fireStarts();
    // we land 5 s before a fire, so the one we are on is skipped
    const t = dir < 0 ? starts.filter((f) => f - 5000 < at - 1000).pop() : starts.find((f) => f - 5000 > at + 1000);
    if (t == null) return this.flash(dir < 0 ? "no earlier fire in view: zoom out" : "no later fire in view");
    this.play(false);
    this.seek(t - 5000);
    const lane = this.lanes.find((l) => l.spans.some((sp) => sp.a === t && sp.sev === "alert"));
    const node = lane ? lane.node : this.marks.find((m) => m.at === t)?.node;
    if (node) this.api.onNode?.(node);
  }

  setSpan(ms) {
    ms = Math.max(MIN_SPAN, Math.min(MAX_SPAN, ms));
    const keep = this.live ? null : this.cursor;
    this.spanMs = ms;
    if (keep != null) this.panTo(keep, 0.5);
    this.refetch();
    this.api.onWindow?.(this.window());
    this.render();
  }

  setSel(sel) {
    this.sel = sel && sel.b - sel.a > 1000 ? sel : null;
    this.saving = false;
    this.api.onWindow?.(this.window());
    this.render();
  }

  zoomToSel() {
    if (!this.sel) return;
    const len = this.sel.b - this.sel.a;
    this.spanMs = Math.max(MIN_SPAN, Math.min(MAX_SPAN, len * 1.25));
    const end = this.sel.b + (this.spanMs - len) / 2;
    this.viewEnd = end >= Date.now() - this.tick ? null : end;
    this.refetch();
    this.render();
  }

  setExpanded(on) {
    this.expanded = on;
    store.set("obs.tl.expanded", on ? "1" : "0");
    this.size(); this.render();
    if (on) this.refetch(); // the BEAM rows are read only while expanded
  }

  // ---- windows ---------------------------------------------------------------

  openWindow(w, fires = true) {
    this.trimming = null;
    this.sel = { a: w.from, b: w.to, id: w.id };
    this.zoomToSel();
    this.play(false);
    this.seek(w.from);
    this.api.onWindow?.(this.window());
    if (fires) this.api.openFires?.();
    this.render();
  }

  startTrim(w) {
    this.toggleWins(false);
    this.trimming = w;
    this.sel = { a: w.from, b: w.to, id: w.id };
    this.zoomToSel();
    this.flash("drag the edges of the selection, then Save edges");
    this.render();
  }

  saveTrim() {
    const w = this.trimming;
    if (!w || !this.sel) return;
    this.write("save_window", { id: w.id, from: Math.round(this.sel.a), to: Math.round(this.sel.b), title: w.title })
      .then((r) => { this.trimming = null; this.sel = { a: r.window.from, b: r.window.to, id: r.window.id }; this.flash(`trimmed “${r.window.title}” to ${span(r.window.to - r.window.from)}`); this.render(); this.api.onWindow?.(this.window()); });
  }

  // no "are you sure": a prune can be undone for an hour, here for 12 s
  // with one click, and from the tray's Recently pruned after that
  prune(ids) {
    this.write("prune_windows", { ids }).then((r) => {
      const n = r.pruned.length;
      this.undoIds = r.pruned;
      this.undoEl.innerHTML = `Pruned ${n} window${n === 1 ? "" : "s"}. <button type="button" data-a="undo">Undo</button> <span class="dim">or restore from the tray within the hour</span>`;
      this.undoEl.hidden = false;
      clearTimeout(this.ut);
      this.ut = setTimeout(() => { this.undoEl.hidden = true; }, 12_000);
    });
  }

  restore(ids) {
    if (!ids.length) return;
    this.write("restore_windows", { ids }).then((r) => {
      this.undoEl.hidden = true;
      this.flash(r.restored.length ? `restored ${r.restored.length} window${r.restored.length === 1 ? "" : "s"}` : "too late: pruned over an hour ago");
    });
  }

  copyLink(w) {
    const u = new URL(location.href);
    u.searchParams.delete("t"); u.searchParams.set("w", String(w.id));
    const done = () => this.flash(`link to “${w.title}” copied`);
    navigator.clipboard?.writeText(u.toString()).then(done, () => window.prompt("Copy the link to this window:", u.toString()));
    if (!navigator.clipboard) window.prompt("Copy the link to this window:", u.toString());
  }

  toggleWins(open) {
    const on = open ?? this.winsEl.hidden;
    this.winsEl.hidden = !on;
    this.el.querySelector("[data-a=windows]").setAttribute("aria-expanded", String(on));
    if (on) this.renderWins();
  }

  picked() { return [...this.winsEl.querySelectorAll("[data-pick]:checked")].map((x) => +x.dataset.pick); }

  // a title for a stretch: what burned in it longest
  autoTitle(a, b) {
    const hits = [];
    for (const l of this.lanes) {
      let ms = 0, text = null;
      for (const sp of l.spans) { const o = Math.min(b, sp.b) - Math.max(a, sp.a); if (o > 0 && sp.sev === "alert") { ms += o; text = sp.text; } }
      if (ms) hits.push({ l, ms, text });
    }
    hits.sort((x, y) => y.ms - x.ms);
    if (!hits.length) return `calm · ${when(a)}`;
    const head = hits[0].text ?? `${this.label(hits[0].l.node)} on fire`;
    return hits.length > 1 ? `${head} (+${hits.length - 1} more)` : head;
  }

  label(id) { return id == null ? "the observer" : this.api.label?.(id) ?? id; }

  // ---- input -------------------------------------------------------------------

  plotX() { return this.expanded ? this.gutter ?? GUTTER : 0; }
  plotW() { return Math.max(1, (this.canvas.clientWidth || 600) - this.plotX()); }
  X(t) { const v = this.view(); return this.plotX() + ((t - v.from) / (v.to - v.from)) * this.plotW(); }
  T(x) { const v = this.view(); return v.from + ((x - this.plotX()) / this.plotW()) * (v.to - v.from); }
  pxMs(px) { return (px / this.plotW()) * this.spanMs; }

  // what is under the pointer
  hit(x, y) {
    const L = this.L;
    if (!L) return {};
    if (this.sel) {
      if (Math.abs(x - this.X(this.sel.a)) < 6) return { edge: "a" };
      if (Math.abs(x - this.X(this.sel.b)) < 6) return { edge: "b" };
    }
    if (!this.live && this.cursor != null && Math.abs(x - this.X(this.cursor)) < 6) return { head: true };
    if (y < L.winY + L.winH + 4) { const w = this.windowAt(x, y); if (w) return { win: w }; }
    if (y >= L.markY - 7 && y <= L.markY + 7) {
      // the nearer of the two kinds of mark: an objective's flame drawn on
      // top of a deploy must still be reachable
      const wm = this.wmarkAt(x), m = this.markAt(x);
      if (wm && m) return Math.abs(this.X(m.at) - x) <= Math.abs(this.X(wm.at) - x) ? { mark: m } : { wmark: wm };
      if (wm) return { wmark: wm };
      if (m) return { mark: m };
    }
    if (this.expanded && L.heatN && y >= L.heatY - 10 && y < L.heatY + L.heatN * HEAT_H) {
      // the header is drawn in the gutter; above the rows in the plot, a
      // click is a click on the time
      if (y < L.heatY) { if (x < this.plotX()) return { heatHead: true }; }
      else {
      const key = this.heatKeys()[Math.floor((y - L.heatY) / HEAT_H)];
      if (key) return x < this.plotX() ? { heatRow: key } : { heat: key, t: this.T(x) };
      }
    }
    if (this.expanded && y >= L.laneY && y < L.laneY + L.lanes * LANE_H) {
      const lane = this.lanes[Math.floor((y - L.laneY) / LANE_H)];
      if (lane) {
        if (x < this.plotX()) return { laneLabel: lane };
        const t = this.T(x);
        const sp = lane.spans.filter((s) => t >= s.a - this.pxMs(3) && t <= s.b + this.pxMs(3)).sort((p, q) => (p.sev === "alert" ? -1 : 1) - (q.sev === "alert" ? -1 : 1))[0];
        if (sp) return { span: sp, lane };
      }
    }
    return {};
  }

  windowAt(x, y) {
    if (!this.L || y > this.L.winY + this.L.winH + 4 || x < this.plotX()) return null;
    const t = this.T(x);
    return this.active().filter((w) => t >= w.from - this.pxMs(3) && t <= w.to + this.pxMs(3)).sort((p, q) => (p.to - p.from) - (q.to - q.from))[0] ?? null;
  }

  wmarkAt(x) {
    let best = null, bd = 7;
    for (const w of this.wmarks) { const d = Math.abs(this.X(w.at) - x); if (d < bd) { bd = d; best = w; } }
    return best;
  }

  markAt(x) {
    let best = null, bd = 8;
    for (const m of this.marks) { const d = Math.abs(this.X(m.at) - x); if (d < bd) { bd = d; best = m; } }
    return best;
  }

  down(e) {
    if (!this.ok) return;
    this.canvas.setPointerCapture(e.pointerId);
    const h = this.hit(e.offsetX, e.offsetY);
    this.drag = { x0: e.offsetX, y0: e.offsetY, moved: false, h };
    if (h.head) this.play(false);
  }

  move(e) {
    this.hover = { x: e.offsetX, y: e.offsetY };
    const d = this.drag;
    if (d) {
      if (Math.abs(e.offsetX - d.x0) > 4) d.moved = true;
      if (d.moved) {
        const t = Math.max(this.range?.from ?? 0, Math.min(this.T(e.offsetX), Date.now()));
        if (d.h.edge) {
          // trim: an edge follows the pointer, and may not cross the other
          const s = { ...this.sel };
          if (d.h.edge === "a") s.a = Math.min(t, s.b - 1000); else s.b = Math.max(t, s.a + 1000);
          this.sel = s;
          this.renderSel();
        } else if (d.h.head) {
          this.cursor = t; this.request(t); this.renderBadge();
        } else if (d.x0 >= this.plotX()) {
          this.sel = { a: Math.min(this.T(d.x0), t), b: Math.max(this.T(d.x0), t) };
          this.trimming = null; this.saving = false;
          this.renderSel();
        }
      }
    }
    const h = d ? d.h : this.hit(e.offsetX, e.offsetY);
    this.canvas.style.cursor = h.edge ? "ew-resize" : h.head ? "grab" : h.win || h.mark || h.wmark || h.span || h.laneLabel || h.heatHead || h.heatRow ? "pointer" : "crosshair";
    this.draw(); this.renderTip(h);
  }

  up(e) {
    const d = this.drag;
    if (!d) return;
    this.drag = null;
    if (d.moved) {
      if (d.h.head) { this.seek(this.cursor); return; }
      this.api.onWindow?.(this.window()); this.render();
      return;
    }
    const h = d.h;
    if (h.win) return this.openWindow(h.win, false);
    if (h.mark) { this.seek(h.mark.at - (h.mark.kind === "fire" ? 5000 : 0)); if (h.mark.node) this.api.onNode?.(h.mark.node); return; }
    if (h.span) { this.seek(h.span.a - 5000); if (h.lane.node) this.api.onNode?.(h.lane.node); return; }
    if (h.wmark) { this.seek(h.wmark.at - 5000); if (h.wmark.app) this.api.onNode?.(h.wmark.app); return; }
    if (h.heatHead) { const i = HEAT_METRICS.findIndex(([k]) => k === this.heatMetric); this.heatMetric = HEAT_METRICS[(i + 1) % HEAT_METRICS.length][0]; store.set("obs.tl.heat", this.heatMetric); this.draw(); return; }
    if (h.heatRow) { const m = this.heatSeries.at(-1)?.[1]?.[h.heatRow]; if (m?.app) this.api.onNode?.(m.app); return; }
    if (h.heat) { this.seek(h.t); const m = this.heatSeries.at(-1)?.[1]?.[h.heat]; if (m?.app) this.api.onNode?.(m.app); return; }
    if (h.laneLabel) { if (h.laneLabel.node) this.api.onNode?.(h.laneLabel.node); return; }
    if (e.offsetX < this.plotX()) return;
    this.seek(this.T(e.offsetX));
  }

  wheel(e) {
    if (!this.ok) return;
    e.preventDefault();
    const v = this.view();
    const pan = e.shiftKey || Math.abs(e.deltaX) > Math.abs(e.deltaY);
    if (pan) {
      const d = (Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.deltaY) * (this.spanMs / this.plotW());
      const end = Math.min(Date.now(), v.to + d);
      this.viewEnd = end >= Date.now() - this.tick ? null : Math.max((this.range?.from ?? end) + this.spanMs * 0.2, end);
    } else {
      // zoom about the time under the pointer
      const x = e.offsetX, t = this.T(x);
      const next = Math.max(MIN_SPAN, Math.min(MAX_SPAN, this.spanMs * Math.exp(e.deltaY * 0.0022)));
      const f = (x - this.plotX()) / this.plotW();
      const end = t + (1 - f) * next;
      this.spanMs = next;
      this.viewEnd = end >= Date.now() - this.tick ? null : end;
    }
    this.refetch();
    this.render();
    clearTimeout(this.wt);
    this.wt = setTimeout(() => this.api.onWindow?.(this.window()), 300);
  }

  key(e) {
    if (!this.ok || e.metaKey || e.ctrlKey || e.altKey || typing(e.target) || e.defaultPrevented) return;
    if (document.querySelector("dialog[open], .ms-modal:not([hidden]), #jump:not([hidden])")) return;
    const k = e.key;
    if (k === " ") { e.preventDefault(); this.togglePlay(); }
    else if (k === "," || k === "<") { e.preventDefault(); this.step(-1, e.shiftKey); }
    else if (k === "." || k === ">") { e.preventDefault(); this.step(1, e.shiftKey); }
    else if (k === "[") { e.preventDefault(); this.jumpFire(-1); }
    else if (k === "]") { e.preventDefault(); this.jumpFire(1); }
    else if (k === "End") { e.preventDefault(); this.goLive(); }
    else if (k === "t") { e.preventDefault(); this.setExpanded(!this.expanded); }
    else if (k === "?") { e.preventDefault(); this.help.hidden = !this.help.hidden; }
    else if (k === "w" && this.sel && !this.sel.id) { e.preventDefault(); this.saving = true; this.renderSel(true); }
  }

  flash(text) {
    this.flashText = text; this.flashUntil = performance.now() + 3000;
    this.renderBadge();
    setTimeout(() => this.renderBadge(), 3100);
  }

  loop(now) {
    requestAnimationFrame((t) => this.loop(t));
    if (now - (this.secAt ?? 0) > 1000) { this.secAt = now; this.renderBack(); }
    if (!this.playing || this.live) { this.lastT = null; if (this.ok && !document.hidden && now - (this.drawnAt ?? 0) > 1000) { this.drawnAt = now; this.draw(); } return; }
    const dt = this.lastT == null ? 0 : Math.min(250, now - this.lastT);
    this.lastT = now;
    this.cursor += dt * SPEEDS[this.speedI];
    if (this.sel && this.cursor > this.sel.b) { this.cursor = this.sel.a; this.request(this.cursor, true); }
    else if (!this.sel && this.cursor >= this.range.to) return this.goLive();
    else if (this.nextAt == null ? this.cursor - (this.shownAt ?? 0) >= this.tick : this.cursor >= this.nextAt) this.request(this.cursor);
    const v = this.view();
    if (this.cursor > v.to - this.spanMs * 0.02) this.panTo(this.cursor, 0.5);
    this.api.onMode?.(true, this.cursor);
    this.renderBadge();
    if (now - (this.drawnAt ?? 0) > 50) { this.drawnAt = now; this.draw(); }
  }

  // ---- rendering ---------------------------------------------------------------

  // the strip's height: the overview, plus a row per lane when expanded
  size() {
    const n = this.expanded ? Math.min(LANES_SHOWN, Math.max(1, this.lanes.length)) : 0;
    const nh = this.expanded ? this.heatKeys().length : 0;
    const strip = 48 + (this.expanded ? 6 + n * LANE_H + (this.lanes.length > LANES_SHOWN ? 10 : 0) + (nh ? 14 + nh * HEAT_H : 0) : 0);
    this.el.style.setProperty("--strip-h", `${strip}px`);
    // a phone stacks the controls in two rows over the strip (tape.css)
    const phone = window.innerWidth <= 640;
    this.gutter = phone ? 74 : GUTTER;
    document.body.style.setProperty("--tl", `${strip + (phone ? 88 : 14)}px`);
    this.el.classList.toggle("expanded", this.expanded);
    this.el.querySelector("[data-a=expand]").setAttribute("aria-pressed", String(this.expanded));
    this.draw();
  }

  render() {
    this.el.classList.toggle("replaying", !this.live);
    this.el.classList.toggle("playing", this.playing);
    this.el.classList.toggle("trimming", !!this.trimming);
    this.el.querySelector(".tl-play").setAttribute("aria-label", this.playing ? "Pause" : this.live ? "Instant replay" : "Play");
    this.el.querySelector(".tl-speed").textContent = `${SPEEDS[this.speedI]}×`;
    for (const b of this.el.querySelectorAll("[data-span]")) b.setAttribute("aria-pressed", String(+b.dataset.span === this.spanMs));
    this.followBtn.hidden = this.viewEnd == null;
    this.renderSel();
    this.renderBadge();
    this.renderBack();
    this.draw();
  }

  renderSel(focus = false) {
    this.selEl.hidden = !this.sel;
    if (!this.sel) return;
    const s = this.sel, len = span(s.b - s.a);
    const w = s.id && this.windows.find((x) => x.id === s.id);
    const range = `<b>${when(s.a)}–${hms(s.b)}</b> <span class="dim">${len}</span>`;
    if (this.trimming) {
      this.selEl.innerHTML = `<span class="tag trim">trimming</span> <b>${esc(this.trimming.title)}</b> ${range}
        <button type="button" data-a="trim-save" class="go">Save edges</button><button type="button" data-a="trim-cancel">Cancel</button>`;
    } else if (this.saving) {
      if (this.selEl.querySelector("form[data-form=save]") && !focus) { this.selEl.querySelector(".rng").innerHTML = range; return; }
      this.selEl.innerHTML = `<form data-form="save" class="tl-form"><span class="rng">${range}</span><input name="title" maxlength="120" value="${esc(this.autoTitle(s.a, s.b))}" aria-label="Window title" spellcheck="false">
        <button type="submit" class="go">Save window</button><button type="button" data-a="unsave">Cancel</button></form>`;
      if (focus) { const i = this.selEl.querySelector("input"); i.focus(); i.select(); }
    } else {
      this.selEl.innerHTML = `${w ? `<span class="tag">window</span> <b>${esc(w.title)}</b> ` : ""}${range}
        <button type="button" data-a="loop" title="Play this stretch on a loop">▶ loop</button>
        <button type="button" data-a="fires" title="What went wrong in this stretch">Fires</button>
        <button type="button" data-a="writeup" title="This stretch as a Markdown document: download, copy or share">Write up</button>
        <button type="button" data-a="zoom" title="Fit the view to this stretch (double-click)">zoom</button>
        ${w ? "" : `<button type="button" data-a="save" class="go" title="Keep this stretch at full detail, named, for everyone (w)">Save window</button>`}
        <button type="button" data-a="clear" aria-label="Clear the selection">×</button>`;
    }
  }

  renderWins() {
    if (this.winsEl.hidden) return;
    const picked = new Set(this.picked());
    const live = this.active(), gone = this.windows.filter((w) => w.pruned_at);
    const total = live.reduce((a, w) => a + (w.frames ?? 0), 0);
    const row = (w) => `<li data-win="${w.id}" class="${this.sel?.id === w.id ? "on" : ""}">
          <input type="checkbox" data-pick="${w.id}" aria-label="Pick ${esc(w.title)}"${picked.has(w.id) ? " checked" : ""}>
          <div class="tw-body">
            ${this.renaming === w.id ? `<form data-form="rename" data-id="${w.id}" class="tl-form"><input name="title" maxlength="120" value="${esc(w.title)}" aria-label="New title"><button type="submit" class="go">Rename</button></form>` : `<b>${esc(w.title)}</b>`}
            <span class="dim">${when(w.from)}–${hms(w.to)} · ${span(w.to - w.from)} · ${w.frames} frames${w.by ? ` · ${esc(w.by)}` : ""}</span>
            ${this.noting === w.id ? `<form data-form="note" data-id="${w.id}" class="tl-note"><textarea maxlength="2000" rows="3" placeholder="what happened, what was done, what to remember" aria-label="Note">${esc(w.note ?? "")}</textarea><button type="submit" class="go">Save note</button></form>` : w.note ? `<span class="tw-note">${esc(w.note)}</span>` : ""}
          </div>
          <div class="tw-acts"><button type="button" data-a="open">open</button><button type="button" data-a="wloop">loop</button><button type="button" data-a="trim">trim</button><button type="button" data-a="rename">rename</button><button type="button" data-a="note">note</button><button type="button" data-a="link" title="Copy a link that opens this window">link</button><button type="button" data-a="wwriteup" title="This window as a Markdown document">write up</button><button type="button" data-a="prune" class="bad">prune</button></div>
        </li>`;
    this.winsEl.innerHTML = `<div class="tw-head"><h4>Windows</h4><span class="dim">${live.length} saved · ${total} frames kept at full detail</span><button type="button" class="fi-x" data-a="wins-close" aria-label="Close">×</button></div>
      ${live.length ? `<ul>${live.map(row).join("")}</ul>
        <div class="tw-foot"><button type="button" data-a="pick-all">pick all</button><button type="button" data-a="prune-picked" class="bad">prune picked</button></div>`
      : `<p class="dim">Nothing saved. Drag across the timeline, then Save window (or w): the stretch is kept at full detail, named, for everyone, until you prune it.</p>`}
      ${gone.length ? `<h5>Recently pruned <span class="dim">· restorable for an hour, frames still kept</span></h5><ul class="tw-gone">${gone.map((w) => `<li data-win="${w.id}"><span></span><div class="tw-body"><b>${esc(w.title)}</b><span class="dim">${when(w.from)}–${hms(w.to)} · pruned ${span(Date.now() - w.pruned_at)} ago · final in ${span(Math.max(0, w.pruned_at + 3600e3 - Date.now()))}</span></div><div class="tw-acts"><button type="button" data-a="restore" class="go">restore</button></div></li>`).join("")}</ul>` : ""}`;
    this.renderPruneButton();
    if (this.renaming) this.winsEl.querySelector("form[data-form=rename] input")?.focus();
    if (this.noting) this.winsEl.querySelector("form[data-form=note] textarea")?.focus();
  }

  renderPruneButton() {
    const b = this.winsEl.querySelector("[data-a=prune-picked]");
    if (!b) return;
    const n = this.picked().length;
    b.disabled = !n;
    b.textContent = `prune picked (${n})`;
  }

  renderBadge() {
    const flash = this.flashUntil && performance.now() < this.flashUntil ? this.flashText : null;
    this.badge.hidden = this.live && !flash;
    if (this.badge.hidden) return;
    if (this.live) { this.badge.innerHTML = `<span class="note">${esc(flash)}</span>`; return; }
    this.badge.innerHTML = `<span class="rec">REPLAY</span> <b>${this.cursor != null ? hms(this.cursor) : "--:--:--"}</b> UTC
      <span class="dim">${new Date(this.cursor ?? Date.now()).toLocaleDateString("en-GB", { timeZone: "UTC", day: "numeric", month: "short" })} · ${SPEEDS[this.speedI]}×${this.playing ? "" : " · paused"}</span>
      ${this.badgeError ? `<span class="err">${esc(this.badgeError)}</span>` : ""}${flash ? `<span class="note">${esc(flash)}</span>` : ""}`;
  }

  // the way back: how far behind, one click (or End) from now
  renderBack() {
    this.back.hidden = this.live || !this.ok;
    if (this.back.hidden) return;
    const behind = this.cursor != null ? Date.now() - this.cursor : null;
    this.back.innerHTML = `<span class="dim">${span(behind)} behind</span> <b>Back to live ⇥</b> <kbd>End</kbd>`;
  }

  renderTip(h) {
    if (!this.hover || !this.ok) { this.tip.hidden = true; return; }
    const x = this.hover.x;
    if (x < this.plotX() && !h.laneLabel && !h.heatRow && !h.heatHead) { this.tip.hidden = true; return; }
    const t = this.T(x);
    const lines = [`<b>${this.spanMs > 86400e3 ? dayHm(t) : hms(t)}</b>`];
    if (h.edge) lines.push(`drag to trim the ${h.edge === "a" ? "start" : "end"}`);
    else if (h.head) lines.push("drag to scrub");
    else if (h.win) lines.push(`<span class="k-win">window</span> ${esc(h.win.title)} · ${span(h.win.to - h.win.from)}<br><span class="dim">click to open</span>`);
    else if (h.mark) lines.push(`<span class="k-${h.mark.kind}">${WORD[h.mark.kind]}</span>${h.mark.by ? ` by ${esc(h.mark.by)}` : ""}: ${esc(h.mark.title)}`);
    else if (h.span) lines.push(`<span class="k-${h.span.sev === "alert" ? "fire" : "warn"}">${esc(this.label(h.lane.node))} ${h.span.sev === "alert" ? "on fire" : "smoking"} ${span(h.span.b - h.span.a)}</span><br>${esc(h.span.text)}<br><span class="dim">${hms(h.span.a)}–${hms(h.span.b)} · click to replay</span>`);
    else if (h.wmark) lines.push(`<span class="k-${h.wmark.sev === "alert" ? "fire" : h.wmark.sev === "warn" ? "warn" : "win"}">${esc(h.wmark.label ?? h.wmark.app ?? "")}</span> ${esc(h.wmark.head)}<br><span class="dim">${esc(h.wmark.text ?? "")}</span>`);
    else if (h.heatHead) lines.push(`BEAM rows: ${esc(HEAT_METRICS.find(([k]) => k === this.heatMetric)[1])} against each node's own median in view.<br><span class="dim">click to show another number</span>`);
    else if (h.heat || h.heatRow) {
      const key = h.heat ?? h.heatRow;
      const vals = this.heatSeries.map(([, m]) => this.heatValue(m[key], this.heatMetric)).filter((v) => v != null).sort((a, b) => a - b);
      const med = vals[Math.floor(vals.length / 2)];
      let v = null;
      if (h.heat) { for (const [at, m] of this.heatSeries) { if (at > h.t) break; v = this.heatValue(m[key], this.heatMetric) ?? v; } }
      lines.push(`${esc(key.slice(5))} · ${esc(HEAT_METRICS.find(([k]) => k === this.heatMetric)[1])}` + (v != null ? `<br>${fmtHeat(this.heatMetric, v)}${med ? ` · ${(v / med).toFixed(1)}x its median` : " · its median in view is 0"}` : ""));
    }
    else if (h.laneLabel) lines.push(`${esc(this.label(h.laneLabel.node))}: ${span(h.laneLabel.alert_ms)} on fire, ${span(h.laneLabel.warn_ms)} smoking in view`);
    else {
      const b = this.bucketAt(t);
      if (b) lines.push(b[2] ? `<span class="k-fire">${b[2]} alert${b[2] > 1 ? "s" : ""}</span>${b[3] ? `, ${b[3]} warning${b[3] > 1 ? "s" : ""}` : ""}${b[5] ? ` · 5xx ${b[5]}/s` : ""}` : b[3] ? `${b[3]} warning${b[3] > 1 ? "s" : ""}${b[5] ? ` · 5xx ${b[5]}/s` : ""}` : `calm${b[5] ? ` · 5xx ${b[5]}/s` : ""}`);
      else lines.push(`<span class="dim">no tape here</span>`);
    }
    this.tip.innerHTML = lines.join("<br>");
    this.tip.hidden = false;
    const w = this.canvas.clientWidth;
    this.tip.style.left = `${Math.max(0, Math.min(w - 260, x - 130))}px`;
  }

  bucketAt(t) {
    if (!this.index) return null;
    const { buckets, step } = this.index;
    for (const b of buckets) if (t >= b[0] && t < b[0] + step) return b;
    return null;
  }

  draw() {
    const c = this.canvas;
    const w = c.clientWidth, h = c.clientHeight;
    if (!w || !h || this.el.hidden) return;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    if (c.width !== Math.round(w * dpr) || c.height !== Math.round(h * dpr)) { c.width = Math.round(w * dpr); c.height = Math.round(h * dpr); }
    const ctx = c.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    const v = this.view();
    const x0 = this.plotX();
    const nLanes = this.expanded ? Math.min(LANES_SHOWN, this.lanes.length) : 0;
    // the rows, top to bottom
    const L = { winY: 0, winH: 9, markY: 15, ovY: 21, ovH: 15 };
    L.laneY = L.ovY + L.ovH + (this.expanded ? 4 : 0);
    L.lanes = nLanes;
    const heatKeys = this.expanded ? this.heatKeys() : [];
    L.heatN = heatKeys.length;
    L.heatY = L.laneY + Math.max(nLanes, this.expanded && !nLanes ? 1 : 0) * LANE_H + (this.lanes.length > LANES_SHOWN ? 10 : 0) + 12;
    L.axisY = h - 1;
    this.L = L;
    const ovBase = L.ovY + L.ovH;
    ctx.font = "10px ui-monospace, Menlo, monospace";
    ctx.textBaseline = "alphabetic";

    // time grid and axis
    const every = [60e3, 5 * 60e3, 15 * 60e3, 3600e3, 3 * 3600e3, 6 * 3600e3, 86400e3].find((g) => (g / (v.to - v.from)) * (w - x0) > 70) ?? 86400e3;
    for (let g = Math.ceil(v.from / every) * every; g < v.to; g += every) {
      const x = this.X(g);
      ctx.fillStyle = "rgba(255,255,255,0.05)"; ctx.fillRect(x, L.ovY, 1, h - L.ovY - 11);
      ctx.fillStyle = "rgba(160,170,190,0.55)";
      const d = new Date(g);
      ctx.fillText(every >= 86400e3 ? dayHm(g) : `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`, x + 3, L.axisY);
    }

    // the overview
    ctx.save(); ctx.beginPath(); ctx.rect(x0, 0, w - x0, h); ctx.clip();
    if (this.index) {
      const { buckets, step } = this.index;
      let maxErr = 0;
      for (const b of buckets) if (b[5] > maxErr) maxErr = b[5];
      const errPts = [];
      for (const [t, , alerts, warns, down, err] of buckets) {
        const bx = this.X(t), bw = Math.max(1, this.X(t + step) - bx - 0.4);
        ctx.fillStyle = "rgba(76,201,240,0.45)"; ctx.fillRect(bx, ovBase - 2, bw, 2);
        if (warns) { ctx.fillStyle = "rgba(255,179,71,0.75)"; const hh = L.ovH * 0.4; ctx.fillRect(bx, ovBase - hh, bw, hh - 2); }
        if (alerts) { const hh = L.ovH * Math.min(1, 0.5 + alerts * 0.12); ctx.fillStyle = "rgba(240,60,30,0.92)"; ctx.fillRect(bx, ovBase - hh, bw, hh - 2); }
        if (down) { ctx.fillStyle = "#ffe08a"; ctx.fillRect(bx, L.ovY - 1, bw, 2); }
        if (err != null && maxErr > 0) errPts.push([bx + bw / 2, ovBase - 3 - (err / maxErr) * (L.ovH - 4)]);
      }
      if (errPts.length > 1) {
        ctx.strokeStyle = "rgba(255,105,180,0.95)"; ctx.lineWidth = 1.2; ctx.beginPath();
        errPts.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
        ctx.stroke();
      }
    } else if (this.ok) { ctx.fillStyle = "rgba(160,170,190,0.5)"; ctx.fillText("reading the tape…", x0 + 8, ovBase - 4); }

    // the lanes
    for (let i = 0; i < nLanes; i++) {
      const lane = this.lanes[i], y = L.laneY + i * LANE_H;
      ctx.fillStyle = i % 2 ? "rgba(255,255,255,0.025)" : "rgba(255,255,255,0.045)"; ctx.fillRect(x0, y, w - x0, LANE_H - 1);
      for (const sev of ["warn", "alert"]) {
        for (const sp of lane.spans) {
          if (sp.sev !== sev) continue;
          const a = this.X(sp.a), b = Math.max(a + 2, this.X(sp.b));
          if (b < x0 || a > w) continue;
          ctx.fillStyle = sev === "alert" ? "rgba(240,60,30,0.95)" : "rgba(255,179,71,0.8)";
          const inset = sev === "alert" ? 2 : 4;
          ctx.fillRect(a, y + inset, b - a, LANE_H - 1 - inset * 2);
        }
      }
    }
    // the BEAM rows: each cell the node's number against its own median in
    // view; dim at its normal, orange at 3x, red at 6x (run queue: per
    // scheduler, red at 1)
    if (L.heatN) {
      const metric = this.heatMetric;
      heatKeys.forEach((key, r) => {
        const y = L.heatY + r * HEAT_H;
        const pts = this.heatSeries.map(([t, m]) => [t, this.heatValue(m[key], metric)]);
        const vals = pts.map(([, v]) => v).filter((v) => v != null).sort((a, b) => a - b);
        const med = vals[Math.floor(vals.length / 2)] || 0;
        for (let i = 0; i < pts.length; i++) {
          const [t, v] = pts[i];
          if (v == null) continue;
          const x = this.X(t), x2 = i + 1 < pts.length ? this.X(pts[i + 1][0]) : x + 3;
          // a zero median (an idle mailbox) has no multiple: the value
          // itself, on a log scale, so 1 message is not painted like 50,000
          const k = metric === "rq" ? v : med > 0 ? v / med : v > 0 ? 1.3 + Math.log10(v + 1) : 0;
          ctx.fillStyle = heatColour(metric === "rq" ? k * 6 : k);
          ctx.fillRect(x, y, Math.max(1, x2 - x), HEAT_H - 1);
        }
      });
    }
    ctx.restore();
    if (L.heatN) {
      ctx.font = "9px system-ui, sans-serif"; ctx.fillStyle = "#c9b8ff";
      ctx.fillText(`BEAM · ${HEAT_METRICS.find(([k]) => k === this.heatMetric)[1]} ▾`, 4, L.heatY - 3);
      ctx.font = "9px ui-monospace, Menlo, monospace"; ctx.fillStyle = "rgba(200,190,255,0.85)";
      heatKeys.forEach((key, r) => {
        const name = key.slice(5).replace(/^([^@]+)@(?:\d+\.\d+\.)?(\d+\.\d+)$/, "$1@.$2");
        let s2 = name;
        while (s2.length > 3 && ctx.measureText(`${s2}…`).width > this.plotX() - 8) s2 = s2.slice(0, -1);
        ctx.fillText(s2 === name ? s2 : `${s2}…`, 4, L.heatY + r * HEAT_H + HEAT_H - 1.5);
      });
      ctx.font = "10px ui-monospace, Menlo, monospace";
    }
    if (this.expanded) {
      // the gutter: what each row is
      ctx.fillStyle = "rgba(160,170,190,0.55)"; ctx.font = "9px system-ui, sans-serif";
      ctx.fillText("WINDOWS", 4, L.winY + 9); ctx.fillText("OVERVIEW", 4, ovBase - 4);
      ctx.font = "10px ui-monospace, Menlo, monospace";
      for (let i = 0; i < nLanes; i++) {
        const lane = this.lanes[i], y = L.laneY + i * LANE_H;
        ctx.fillStyle = lane.alert_ms ? "#ff8a50" : "#ffc46b";
        const full = this.label(lane.node);
        let s = full;
        while (s.length > 3 && ctx.measureText(`${s}…`).width > x0 - 10) s = s.slice(0, -1);
        ctx.fillText(s === full ? s : `${s}…`, 4, y + LANE_H - 3);
      }
      if (this.lanes.length > LANES_SHOWN) { ctx.fillStyle = "rgba(160,170,190,0.6)"; ctx.fillText(`+${this.lanes.length - LANES_SHOWN} more buildings`, 4, L.laneY + nLanes * LANE_H + 8); }
      if (!nLanes && this.index) { ctx.fillStyle = "rgba(61,220,132,0.75)"; ctx.fillText("nothing burned in view", x0 + 8, L.laneY + 10); }
    }

    ctx.save(); ctx.beginPath(); ctx.rect(x0, 0, w - x0, h); ctx.clip();
    // saved windows: brackets along the top, labelled, tinting their stretch
    for (const win of this.active()) {
      const a = this.X(win.from), b = this.X(win.to);
      if (b < x0 || a > w) continue;
      const on = this.sel?.id === win.id;
      ctx.fillStyle = "rgba(127,224,255,0.05)"; ctx.fillRect(a, L.winY, Math.max(2, b - a), h - 11);
      ctx.fillStyle = on ? "rgba(127,224,255,0.95)" : "rgba(127,224,255,0.6)";
      ctx.fillRect(a, L.winY + 1, Math.max(2, b - a), 2);
      ctx.fillRect(a, L.winY + 1, 1.5, L.winH); ctx.fillRect(Math.max(a, b - 1.5), L.winY + 1, 1.5, L.winH);
      if (b - a > 40) {
        ctx.fillStyle = on ? "#e8fbff" : "#9fdcf0"; ctx.font = "9px system-ui, sans-serif";
        let s = win.title;
        while (s.length > 2 && ctx.measureText(`${s}…`).width > b - a - 8) s = s.slice(0, -1);
        ctx.fillText(s === win.title ? s : `${s}…`, a + 4, L.winY + 12);
        ctx.font = "10px ui-monospace, Menlo, monospace";
      }
    }

    // the selection, with its edges as handles
    if (this.sel) {
      const a = this.X(this.sel.a), b = this.X(this.sel.b);
      ctx.fillStyle = this.trimming ? "rgba(255,209,102,0.12)" : "rgba(127,224,255,0.13)"; ctx.fillRect(a, 0, b - a, h);
      ctx.fillStyle = this.trimming ? "#ffd166" : "rgba(127,224,255,0.9)";
      for (const x of [a, b]) { ctx.fillRect(x - 1, 0, 2, h); ctx.fillRect(x - 3, h / 2 - 7, 6, 14); }
    }

    // what happened inside the BEAMs: deploys, crashes, restarts, leaders
    for (const wm of this.wmarks) {
      const x = this.X(wm.at);
      if (x < x0 - 6 || x > w + 6) continue;
      wireGlyph(ctx, WIRE_MARK[wm.kind], x, L.markY, L.ovY, h - 11);
    }
    // deploys.js: other modules' marks (deploy shas), drawn with the view's x
    for (const fn of this.overlays ?? []) fn(ctx, { X: (t) => this.X(t), x0, w, h, L });
    // never a silent cap: say so when the marks were cut
    if (this.wmarksCut) { ctx.fillStyle = "rgba(201,184,255,0.8)"; ctx.font = "9px system-ui, sans-serif"; ctx.fillText("only the newest 5,000 BEAM marks", x0 + 4, L.markY + 3); ctx.font = "10px ui-monospace, Menlo, monospace"; }

    // what was done
    for (const m of this.marks) {
      const x = this.X(m.at);
      if (x < x0 - 6 || x > w + 6) continue;
      glyph(ctx, m.kind, x, L.markY);
    }

    if (this.hover && this.hover.x >= x0) { ctx.fillStyle = "rgba(255,255,255,0.35)"; ctx.fillRect(this.hover.x, L.ovY, 1, h - L.ovY - 11); }

    // the playhead, and the live edge
    if (!this.live && this.cursor != null) {
      const x = this.X(this.cursor);
      ctx.save();
      ctx.shadowColor = "rgba(127,224,255,0.9)"; ctx.shadowBlur = 8;
      ctx.fillStyle = "#e8fbff"; ctx.fillRect(x - 1, 0, 2, h - 10);
      ctx.beginPath(); ctx.moveTo(x - 6, 0); ctx.lineTo(x + 6, 0); ctx.lineTo(x, 7); ctx.fill();
      ctx.restore();
    }
    if (this.range?.to && this.viewEnd == null) {
      const x = Math.min(w - 2, this.X(this.range.to));
      const pulse = 0.55 + 0.45 * Math.sin(performance.now() / 300);
      ctx.fillStyle = `rgba(61,220,132,${pulse})`; ctx.fillRect(x - 1, L.ovY, 2, h - L.ovY - 11);
    }
    ctx.restore();
  }
}

// the marks above the strip, 12 px tall at most
function glyph(ctx, kind, x, y) {
  ctx.save();
  ctx.translate(x, y);
  if (kind === "fire") {
    const g = ctx.createLinearGradient(0, 5, 0, -6);
    g.addColorStop(0, "#ff3d00"); g.addColorStop(1, "#ffd166");
    ctx.fillStyle = g;
    ctx.beginPath(); ctx.moveTo(-4, 5); ctx.quadraticCurveTo(-5, -1, 0, -6); ctx.quadraticCurveTo(5, -1, 4, 5); ctx.closePath(); ctx.fill();
  } else if (kind === "out") {
    ctx.fillStyle = "#5ab8ff";
    ctx.beginPath(); ctx.moveTo(0, -6); ctx.quadraticCurveTo(5, 1, 0, 5); ctx.quadraticCurveTo(-5, 1, 0, -6); ctx.fill();
  } else if (kind === "puff") {
    ctx.fillStyle = "rgba(170,175,190,0.8)";
    ctx.beginPath(); ctx.arc(-2, 1, 3, 0, Math.PI * 2); ctx.arc(2, -1, 3.2, 0, Math.PI * 2); ctx.fill();
  } else if (kind === "look") {
    ctx.strokeStyle = "#7fe0ff"; ctx.lineWidth = 1.4;
    ctx.beginPath(); ctx.ellipse(0, 0, 5, 3, 0, 0, Math.PI * 2); ctx.stroke();
    ctx.fillStyle = "#7fe0ff"; ctx.beginPath(); ctx.arc(0, 0, 1.4, 0, Math.PI * 2); ctx.fill();
  } else {
    ctx.fillStyle = "#f2c94c";
    ctx.beginPath(); ctx.moveTo(0, -5); ctx.lineTo(4, 0); ctx.lineTo(0, 5); ctx.lineTo(-4, 0); ctx.fill();
  }
  ctx.restore();
}

function heatColour(k) {
  if (k < 1.3) return `rgba(76,201,240,${Math.min(0.35, 0.12 + k * 0.12)})`;
  if (k < 3) return `rgba(255,190,80,${0.35 + (k - 1.3) * 0.25})`;
  if (k < 6) return `rgba(255,120,40,${0.6 + (k - 3) * 0.1})`;
  return "rgba(255,50,30,0.95)";
}

function fmtHeat(metric, v) {
  if (metric === "rq") return `${v.toFixed(2)} per scheduler`;
  if (metric === "mem") return v >= 1e9 ? `${(v / 1073741824).toFixed(2)} GB` : `${Math.round(v / 1048576)} MB`;
  if (metric === "reds") return v >= 1e6 ? `${(v / 1e6).toFixed(2)}M/s` : v >= 1e3 ? `${Math.round(v / 1e3)}k/s` : `${Math.round(v)}/s`;
  return String(Math.round(v));
}

// a BEAM happening on the marks row; deploys and crashes also draw a thin
// line down through the strip, so "what changed right before this" is one look
function wireGlyph(ctx, kind, x, y, top, bottom) {
  ctx.save();
  if (kind === "deploy" || kind === "crash") {
    ctx.strokeStyle = kind === "deploy" ? "rgba(127,180,255,0.55)" : "rgba(255,70,50,0.6)";
    ctx.setLineDash([2, 3]); ctx.beginPath(); ctx.moveTo(x + 0.5, top); ctx.lineTo(x + 0.5, bottom); ctx.stroke(); ctx.setLineDash([]);
  }
  ctx.translate(x, y);
  if (kind === "deploy") { ctx.fillStyle = "#7fb4ff"; ctx.beginPath(); ctx.moveTo(0, -6); ctx.lineTo(5, 3); ctx.lineTo(-5, 3); ctx.closePath(); ctx.fill(); }
  else if (kind === "crash") { ctx.strokeStyle = "#ff4d3a"; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(-4, -4); ctx.lineTo(4, 4); ctx.moveTo(4, -4); ctx.lineTo(-4, 4); ctx.stroke(); }
  else if (kind === "restart") { ctx.strokeStyle = "#7fe0ff"; ctx.lineWidth = 1.6; ctx.beginPath(); ctx.arc(0, 0, 4, 0.4, Math.PI * 1.8); ctx.stroke(); }
  else if (kind === "leader") { ctx.fillStyle = "#f2c94c"; ctx.font = "11px system-ui"; ctx.textAlign = "center"; ctx.fillText("★", 0, 4); }
  else { ctx.fillStyle = "#c9b8ff"; ctx.beginPath(); ctx.moveTo(0, -5); ctx.lineTo(4, 0); ctx.lineTo(0, 5); ctx.lineTo(-4, 0); ctx.fill(); }
  ctx.restore();
}
