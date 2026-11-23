// The timeline: the tape (ObsFactor.Tape, channel `tape`) along the bottom
// of the screen. Every tick of the floor is on it. Click a moment and the
// floor is redrawn as it was; drag across a stretch to select it, and play
// loops inside it while the Fires panel reads only that stretch.
//
// What the strip shows, per column of the window: a thin teal line where
// there is tape (none: a gap, the observer was down), amber for warnings,
// red for alerts (taller for more of them), a bright cap for buildings
// down, and a pink line for 5xx. Above it, what people and rules did:
//   fire   an objective opened, or came back
//   eye    someone said they were looking
//   drop   crossed off: put out
//   puff   cleared itself: burned out with nobody putting it out
//   pin    flagged on the floor
//
// Keys (outside a text field): Space plays and pauses; on the live floor
// it is an instant replay of the last two minutes at 4x. , and . step a
// frame back and forward (with Shift, a minute). [ and ] jump to the
// previous and next fire. End goes back to live.
//
// The page is told through callbacks: onFrame(snapshot, at) to draw a
// moment, onLive() to go back to the live floor, onMode(replaying, at)
// as the mode or the moment changes, onWindow({from, to, selected}) as the
// stretch in view or selected changes, onNode(id) when a fire on the strip
// is clicked.

import * as bus from "./bus.js";
import { esc } from "./fmt.js";

const SPANS = [["15m", 15 * 60e3], ["1h", 3600e3], ["6h", 6 * 3600e3], ["24h", 86400e3], ["7d", 7 * 86400e3]];
const SPEEDS = [1, 4, 16, 64, 256];
const KIND = { seen: "fire", "came back": "fire", reopened: "fire", pinned: "pin", looking: "look", "crossed off": "out", "cleared itself": "puff" };
const WORD = { fire: "fire", pin: "flagged", look: "looking", out: "put out", puff: "burned out" };
const MIN_REQ_MS = 90; // at most ~11 frames a second while playing fast

const pad = (n) => String(n).padStart(2, "0");
function hms(ms) { const d = new Date(ms); return `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}`; }
function dayHm(ms) { const d = new Date(ms); return `${d.toLocaleDateString("en-GB", { timeZone: "UTC", day: "numeric", month: "short" })} ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`; }
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
    this.viewEnd = null; // the window's end while replaying (live: now)
    this.sel = null; // {a, b} selected stretch
    this.index = null; // {from, to, step, buckets}
    this.marks = [];
    this.inflight = false; this.pending = null; this.lastReq = 0;
    this.hoverX = null;
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
        <button type="button" class="tl-b tl-play" data-a="play" title="Play / pause (Space). On the live floor: instant replay" aria-label="Play"><svg viewBox="0 0 24 24"><path class="pl" d="M7 5l12 7-12 7z"/><path class="pa" d="M7 5h4v14H7zM14 5h4v14h-4z"/></svg></button>
        <button type="button" class="tl-b" data-a="next" title="Next fire (])" aria-label="Next fire"><svg viewBox="0 0 24 24"><path d="M18 5v14M5 5l10 7-10 7z"/></svg></button>
        <button type="button" class="tl-speed" data-a="speed" title="Playback speed">1×</button>
      </div>
      <div class="tl-strip">
        <canvas aria-label="The tape: alerts, warnings and 5xx over time, and what was done about them. Click to replay a moment, drag to select a stretch."></canvas>
        <div class="tl-tip" hidden></div>
      </div>
      <div class="tl-spans" role="group" aria-label="How much of the tape to show">
        ${SPANS.map(([l, ms]) => `<button type="button" data-span="${ms}"${ms === this.spanMs ? ' aria-pressed="true"' : ""}>${l}</button>`).join("")}
      </div>
      <div class="tl-sel" hidden></div>
      <div class="tl-badge" hidden></div>`;
    this.canvas = this.el.querySelector("canvas");
    this.tip = this.el.querySelector(".tl-tip");
    this.selEl = this.el.querySelector(".tl-sel");
    this.badge = this.el.querySelector(".tl-badge");
    this.el.addEventListener("click", (e) => {
      const b = e.target.closest("button");
      if (!b) return;
      if (b.dataset.span) {
        // on a phone only the window in use is shown: tapping it takes the next one
        if (+b.dataset.span === this.spanMs && window.innerWidth <= 640) { const i = SPANS.findIndex(([, ms]) => ms === this.spanMs); return this.setSpan(SPANS[(i + 1) % SPANS.length][1]); }
        return this.setSpan(+b.dataset.span);
      }
      const a = b.dataset.a;
      if (a === "live") this.goLive();
      else if (a === "play") this.togglePlay();
      else if (a === "prev") this.jumpFire(-1);
      else if (a === "next") this.jumpFire(1);
      else if (a === "speed") { this.speedI = (this.speedI + 1) % SPEEDS.length; this.render(); }
      else if (a === "loop") { this.seek(this.sel.a); this.play(true); }
      else if (a === "zoom") this.zoomToSel();
      else if (a === "clear") this.setSel(null);
    });
    const c = this.canvas;
    c.addEventListener("pointerdown", (e) => {
      if (!this.ok) return;
      c.setPointerCapture(e.pointerId);
      this.drag = { x0: e.offsetX, moved: false };
    });
    c.addEventListener("pointermove", (e) => {
      this.hoverX = e.offsetX;
      if (this.drag && Math.abs(e.offsetX - this.drag.x0) > 5) {
        this.drag.moved = true;
        const a = this.T(Math.min(this.drag.x0, e.offsetX)), b = this.T(Math.max(this.drag.x0, e.offsetX));
        this.sel = { a, b };
      }
      this.draw(); this.renderTip();
    });
    c.addEventListener("pointerleave", () => { this.hoverX = null; this.tip.hidden = true; this.draw(); });
    const up = (e) => {
      if (!this.drag) return;
      const d = this.drag; this.drag = null;
      if (d.moved) { this.setSel(this.sel); return; }
      const m = this.markAt(e.offsetX);
      if (m) { this.seek(m.at - (m.kind === "fire" ? 5000 : 0)); if (m.node) this.api.onNode?.(m.node); }
      else this.seek(this.T(e.offsetX));
    };
    c.addEventListener("pointerup", up);
    c.addEventListener("pointercancel", () => { this.drag = null; });
    window.addEventListener("resize", () => { this.fetchIndex(); this.draw(); });
    document.addEventListener("keydown", (e) => this.key(e));
  }

  // ---- the channel -----------------------------------------------------

  connect() {
    bus.subscribe("tape", (ev, p) => { if (ev === "tick") this.onTick(p); }, {
      onJoin: (r) => {
        if (r.error) return this.fail(r.error);
        this.ok = true; this.range = r.range; this.tick = r.tick_ms || 5000;
        document.body.classList.add("has-tape");
        this.el.hidden = false;
        this.fetchIndex(); this.fetchMarks();
        const t = new URLSearchParams(location.search).get("t");
        if (t && !this.started) { this.started = true; const ms = /^\d+$/.test(t) ? +t : Date.parse(t); if (ms) this.seek(ms); }
        this.started = true;
        this.render();
      },
      onError: (why) => this.fail(why),
    });
  }

  fail(why) {
    this.ok = false;
    this.error = why;
    console.error(`obs_factor timeline: ${why}`);
    // no tape: no timeline, and nothing else moves for it
    document.body.classList.remove("has-tape");
    this.el.hidden = true;
    this.api.onWindow?.(this.window());
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
    const now = performance.now();
    if (now - (this.indexAt ?? 0) > 20_000) this.fetchIndex();
    if (t.fires && now - (this.marksAt ?? 0) > 8_000) this.fetchMarks();
    else if (!t.fires && this.lastFires) this.fetchMarks(); // a fire went out: there is a mark to draw
    this.lastFires = t.fires;
    this.draw();
  }

  // the window in view: [now - span, now] live, or around the moment
  view() {
    const to = this.live || this.viewEnd == null ? Date.now() : this.viewEnd;
    return { from: to - this.spanMs, to };
  }

  window() {
    const v = this.view();
    return this.sel ? { from: Math.round(this.sel.a), to: Math.round(this.sel.b), selected: true } : { from: Math.round(v.from), to: Math.round(v.to), selected: false, live: this.live };
  }

  buckets() { return Math.max(40, Math.min(1200, Math.floor((this.canvas.clientWidth || 600) / 3))); }

  fetchIndex() {
    if (!this.ok) return;
    this.indexAt = performance.now();
    const v = this.view();
    const from = Math.round(v.from), to = Math.round(v.to + (this.live ? this.tick * 2 : 0));
    bus.push("tape", "index", { from, to, buckets: this.buckets() })
      .then((r) => { this.index = r; this.draw(); })
      .catch((e) => console.error(`obs_factor timeline: index: ${e.message}`));
  }

  fetchMarks() {
    if (!this.ok) return;
    this.marksAt = performance.now();
    const v = this.view();
    bus.push("tape", "marks", { from: Math.round(v.from), to: Math.round(v.to + 60_000) })
      .then((r) => {
        this.marks = r.marks.map(([at, kind, id, node, severity, title, by]) => ({ at, kind: KIND[kind] ?? "fire", raw: kind, id, node, severity, title, by }));
        this.draw();
      })
      .catch((e) => console.error(`obs_factor timeline: marks: ${e.message}`));
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
    if (wasLive || this.viewEnd == null) this.viewEnd = Date.now();
    // keep the moment in view: past either edge, the window follows it
    if (t < v.from || t > v.to) { this.viewEnd = Math.min(Date.now(), t + this.spanMs * 0.25); this.fetchIndex(); this.fetchMarks(); }
    this.request(t, true);
    if (wasLive) this.api.onWindow?.(this.window());
    this.render();
  }

  request(t, now = false) {
    if (this.inflight) { this.pending = t; return; }
    if (!now && performance.now() - this.lastReq < MIN_REQ_MS) { this.pending = t; return; }
    this.inflight = true; this.lastReq = performance.now();
    bus.push("tape", "frame", { at: Math.round(t) })
      .then((r) => {
        if (this.live) return; // went live while it was on its way
        this.shownAt = r.at; this.nextAt = r.next;
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
    this.live = true; this.playing = false; this.cursor = null; this.viewEnd = null; this.pending = null;
    this.shownAt = null; this.nextAt = null; this.badgeError = null;
    if (!was) { this.api.onLive(); this.api.onMode?.(false, null); this.fetchIndex(); this.fetchMarks(); this.api.onWindow?.(this.window()); }
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

  jumpFire(dir) {
    const at = this.live ? Date.now() : this.cursor;
    const fires = this.marks.filter((m) => m.kind === "fire");
    // a fire counts as "this one" for 6 s after we jump to it (we land 5 s before it)
    const m = dir < 0 ? fires.filter((f) => f.at - 5000 < at - 1000).pop() : fires.find((f) => f.at - 5000 > at + 1000);
    if (!m) return this.flash(dir < 0 ? "no earlier fire in view: widen the window" : "no later fire in view");
    this.play(false);
    this.seek(m.at - 5000);
    if (m.node) this.api.onNode?.(m.node);
  }

  setSpan(ms) {
    const keep = this.live ? null : this.cursor;
    this.spanMs = ms;
    if (keep != null) this.viewEnd = Math.min(Date.now(), keep + ms * 0.5);
    if (this.sel && (this.sel.b - this.sel.a) > ms) this.sel = null;
    this.fetchIndex(); this.fetchMarks();
    this.api.onWindow?.(this.window());
    this.render();
  }

  setSel(sel) {
    this.sel = sel && sel.b - sel.a > 1000 ? sel : null;
    this.api.onWindow?.(this.window());
    this.render();
  }

  zoomToSel() {
    if (!this.sel) return;
    const len = this.sel.b - this.sel.a;
    const fit = SPANS.find(([, ms]) => ms >= len * 1.15) ?? SPANS[SPANS.length - 1];
    this.spanMs = fit[1];
    this.viewEnd = Math.min(Date.now(), this.sel.b + (fit[1] - len) / 2);
    if (this.cursor == null) this.seek(this.sel.a); else { this.fetchIndex(); this.fetchMarks(); }
    this.render();
  }

  loop(now) {
    requestAnimationFrame((t) => this.loop(t));
    if (!this.playing || this.live) { this.lastT = null; if (this.live && this.ok && !document.hidden && now - (this.drawnAt ?? 0) > 1000) { this.drawnAt = now; this.draw(); } return; }
    const dt = this.lastT == null ? 0 : Math.min(250, now - this.lastT);
    this.lastT = now;
    this.cursor += dt * SPEEDS[this.speedI];
    if (this.sel && this.cursor > this.sel.b) { this.cursor = this.sel.a; this.request(this.cursor, true); }
    else if (!this.sel && this.cursor >= this.range.to) return this.goLive();
    else if (this.nextAt == null ? this.cursor - (this.shownAt ?? 0) >= this.tick : this.cursor >= this.nextAt) this.request(this.cursor);
    const v = this.view();
    if (this.cursor > v.to - this.spanMs * 0.02) { this.viewEnd = Math.min(Date.now(), this.cursor + this.spanMs * 0.5); this.fetchIndex(); this.fetchMarks(); }
    this.api.onMode?.(true, this.cursor);
    this.renderBadge();
    if (now - (this.drawnAt ?? 0) > 50) { this.drawnAt = now; this.draw(); }
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
  }

  flash(text) {
    this.flashText = text; this.flashUntil = performance.now() + 2500;
    this.renderBadge();
    setTimeout(() => this.renderBadge(), 2600);
  }

  // ---- drawing -------------------------------------------------------------

  X(t) { const v = this.view(); return ((t - v.from) / (v.to - v.from)) * this.canvas.clientWidth; }
  T(x) { const v = this.view(); return v.from + (x / this.canvas.clientWidth) * (v.to - v.from); }

  markAt(x) {
    let best = null, bd = 8;
    for (const m of this.marks) { const d = Math.abs(this.X(m.at) - x); if (d < bd) { bd = d; best = m; } }
    return best;
  }

  render() {
    this.el.classList.toggle("replaying", !this.live);
    this.el.classList.toggle("playing", this.playing);
    const play = this.el.querySelector(".tl-play");
    play.setAttribute("aria-label", this.playing ? "Pause" : this.live ? "Instant replay" : "Play");
    this.el.querySelector(".tl-speed").textContent = `${SPEEDS[this.speedI]}×`;
    for (const b of this.el.querySelectorAll("[data-span]")) b.setAttribute("aria-pressed", String(+b.dataset.span === this.spanMs));
    this.selEl.hidden = !this.sel;
    if (this.sel) {
      this.selEl.innerHTML = `<b>${hms(this.sel.a)}–${hms(this.sel.b)}</b> <span class="dim">${span(this.sel.b - this.sel.a)}</span>
        <button type="button" data-a="loop" title="Play this stretch on a loop">▶ loop</button>
        <button type="button" data-a="zoom" title="Fit the window to this stretch">zoom</button>
        <button type="button" data-a="clear" aria-label="Clear the selection">×</button>`;
    }
    this.renderBadge();
    this.draw();
  }

  renderBadge() {
    const flash = this.flashUntil && performance.now() < this.flashUntil ? this.flashText : null;
    this.badge.hidden = this.live && !flash;
    if (this.badge.hidden) return;
    if (this.live) { this.badge.innerHTML = `<span class="note">${esc(flash)}</span>`; return; }
    const behind = this.range?.to && this.cursor != null ? this.range.to - this.cursor : null;
    this.badge.innerHTML = `<span class="rec">REPLAY</span> <b>${this.cursor != null ? hms(this.cursor) : "--:--:--"}</b> UTC
      <span class="dim">${new Date(this.cursor ?? Date.now()).toLocaleDateString("en-GB", { timeZone: "UTC", day: "numeric", month: "short" })} · ${span(behind)} ago · ${SPEEDS[this.speedI]}×${this.playing ? "" : " · paused"}</span>
      ${this.badgeError ? `<span class="err">${esc(this.badgeError)}</span>` : ""}${flash ? `<span class="note">${esc(flash)}</span>` : ""}`;
  }

  renderTip() {
    if (this.hoverX == null || !this.ok) { this.tip.hidden = true; return; }
    const t = this.T(this.hoverX);
    const m = this.markAt(this.hoverX);
    const b = this.bucketAt(t);
    const lines = [`<b>${this.spanMs > 86400e3 ? dayHm(t) : hms(t)}</b>`];
    if (m) lines.push(`<span class="k-${m.kind}">${WORD[m.kind]}</span>${m.by ? ` by ${esc(m.by)}` : ""}: ${esc(m.title)}`);
    else if (b) lines.push(b[2] ? `<span class="k-fire">${b[2]} alert${b[2] > 1 ? "s" : ""}</span>${b[3] ? `, ${b[3]} warning${b[3] > 1 ? "s" : ""}` : ""}${b[5] ? ` · 5xx ${b[5]}/s` : ""}` : b[3] ? `${b[3]} warning${b[3] > 1 ? "s" : ""}${b[5] ? ` · 5xx ${b[5]}/s` : ""}` : `calm${b[5] ? ` · 5xx ${b[5]}/s` : ""}`);
    else lines.push(`<span class="dim">no tape here</span>`);
    this.tip.innerHTML = lines.join("<br>");
    this.tip.hidden = false;
    const w = this.canvas.clientWidth;
    this.tip.style.left = `${Math.max(0, Math.min(w - 220, this.hoverX - 110))}px`;
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
    const top = 11, base = h - 12; // marks above, time labels below
    const tall = base - top;

    // time grid
    ctx.font = "10px ui-monospace, Menlo, monospace";
    ctx.textBaseline = "alphabetic";
    const every = [60e3, 5 * 60e3, 15 * 60e3, 3600e3, 3 * 3600e3, 6 * 3600e3, 86400e3].find((g) => (g / (v.to - v.from)) * w > 70) ?? 86400e3;
    for (let g = Math.ceil(v.from / every) * every; g < v.to; g += every) {
      const x = this.X(g);
      ctx.fillStyle = "rgba(255,255,255,0.05)"; ctx.fillRect(x, top, 1, tall);
      ctx.fillStyle = "rgba(160,170,190,0.55)";
      const d = new Date(g);
      ctx.fillText(every >= 86400e3 ? dayHm(g) : `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`, x + 3, h - 2);
    }

    // the tape
    if (this.index) {
      const { buckets, step } = this.index;
      let maxErr = 0;
      for (const b of buckets) if (b[5] > maxErr) maxErr = b[5];
      const errPts = [];
      for (const [t, , alerts, warns, down, err] of buckets) {
        const x0 = this.X(t), x1 = this.X(t + step);
        const bw = Math.max(1, x1 - x0 - 0.4);
        ctx.fillStyle = "rgba(76,201,240,0.45)"; ctx.fillRect(x0, base - 2, bw, 2);
        if (warns) { ctx.fillStyle = "rgba(255,179,71,0.75)"; const hh = tall * 0.32; ctx.fillRect(x0, base - hh, bw, hh - 2); }
        if (alerts) {
          const hh = tall * Math.min(1, 0.45 + alerts * 0.14);
          const g = ctx.createLinearGradient(0, base - hh, 0, base);
          g.addColorStop(0, "rgba(255,90,40,0.95)"); g.addColorStop(1, "rgba(200,30,30,0.85)");
          ctx.fillStyle = g; ctx.fillRect(x0, base - hh, bw, hh - 2);
        }
        if (down) { ctx.fillStyle = "#ffe08a"; ctx.fillRect(x0, top, bw, 2); }
        if (err != null && maxErr > 0) errPts.push([x0 + bw / 2, base - 3 - (err / maxErr) * (tall - 6)]);
      }
      if (errPts.length > 1) {
        ctx.strokeStyle = "rgba(255,105,180,0.9)"; ctx.lineWidth = 1.2; ctx.beginPath();
        errPts.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
        ctx.stroke();
      }
    } else {
      ctx.fillStyle = "rgba(160,170,190,0.5)"; ctx.fillText(this.ok ? "reading the tape…" : "", 8, base - 8);
    }

    // the selection
    if (this.sel) {
      const a = this.X(this.sel.a), b = this.X(this.sel.b);
      ctx.fillStyle = "rgba(127,224,255,0.14)"; ctx.fillRect(a, 0, b - a, h);
      ctx.fillStyle = "rgba(127,224,255,0.85)"; ctx.fillRect(a, 0, 1.5, h); ctx.fillRect(b - 1.5, 0, 1.5, h);
    }

    // what was done
    for (const m of this.marks) {
      const x = this.X(m.at);
      if (x < -6 || x > w + 6) continue;
      glyph(ctx, m.kind, x, 6);
    }

    // hover
    if (this.hoverX != null) { ctx.fillStyle = "rgba(255,255,255,0.35)"; ctx.fillRect(this.hoverX, top, 1, tall); }

    // the playhead, or the live edge
    if (!this.live && this.cursor != null) {
      const x = this.X(this.cursor);
      ctx.save();
      ctx.shadowColor = "rgba(127,224,255,0.9)"; ctx.shadowBlur = 8;
      ctx.fillStyle = "#e8fbff"; ctx.fillRect(x - 1, 0, 2, h);
      ctx.beginPath(); ctx.moveTo(x - 5, 0); ctx.lineTo(x + 5, 0); ctx.lineTo(x, 6); ctx.fill();
      ctx.restore();
    } else if (this.range?.to) {
      const x = Math.min(w - 2, this.X(this.range.to));
      const pulse = 0.55 + 0.45 * Math.sin(performance.now() / 300);
      ctx.fillStyle = `rgba(61,220,132,${pulse})`; ctx.fillRect(x - 1, top, 2, tall);
    }
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
