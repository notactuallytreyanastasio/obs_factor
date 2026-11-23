// Fires: what went wrong, and how it was handled, over the stretch of tape
// the timeline shows (or the stretch selected on it). Read from the `tape`
// channel's `insights` (ObsFactor.Insights): the objectives say what people
// did, the tape says what the floor did.
//
// Also the floor's alarm: the top-bar button counts the buildings burning
// now (alerts; warnings are smoke), the screen's edges glow while what is
// on screen has an alert, and a banner calls each new fire and the moment
// the last one goes out.

import * as bus from "./bus.js";
import { esc } from "./fmt.js";
import { span } from "./timeline.js";

const pad = (n) => String(n).padStart(2, "0");
const hms = (ms) => { const d = new Date(ms); return `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}`; };
const MARK_WORD = { fire: "started", "came back": "came back", look: "looking", out: "put out", puff: "burned out", pin: "flagged" };

export class Fires {
  constructor(api) {
    this.api = api; // { timeline, go(id), closeOthers(), outer() }
    this.el = document.getElementById("fires");
    this.btn = document.getElementById("firesbtn");
    this.banner = document.getElementById("firebanner");
    this.data = null; this.error = null; this.loading = false;
    this.burning = new Map(); // node -> text, on the live floor
    this.first = true;
    this.btn.addEventListener("click", () => this.toggle());
    this.el.addEventListener("click", (e) => this.onClick(e));
    this.banner.addEventListener("click", () => { this.banner.hidden = true; this.toggle(true); });
    setInterval(() => { if (this.open && this.api.timeline.window().live) this.fetch(); }, 30_000);
    // the panel needs the tape channel; joined by the timeline already, this only adds a subscriber
    bus.subscribe("tape", () => {}, { onJoin: (r) => { this.error = r.error ?? null; this.btn.hidden = false; if (this.open) this.fetch(); } });
    // someone crossing an objective off is a fire put out: the whole floor hears it
    this.states = new Map();
    const learn = (list) => { for (const o of list ?? []) this.states.set(o.id, o.state); };
    bus.subscribe("objectives", (ev, p) => {
      if (ev === "list") return learn(p.objectives);
      if (ev !== "objective") return;
      const was = this.states.get(p.id);
      this.states.set(p.id, p.state);
      if (p.state === "done" && was && was !== "done") this.say("out", `FIRE OUT · ${this.label(p.node)}`, `${p.done_by ?? "someone"}${p.note ? `: ${p.note}` : ` crossed off “${p.title}”`}`);
    }, { onJoin: (r) => learn(r.objectives) });
  }

  get open() { return !this.el.hidden; }

  toggle(open) {
    const on = open ?? this.el.hidden;
    if (on) this.api.closeOthers();
    this.el.hidden = !on;
    this.btn.setAttribute("aria-expanded", String(on));
    if (on) { this.render(); this.fetch(); }
    else this.window = null;
    this.api.onToggle?.();
  }

  setWindow() {
    if (!this.open) return;
    clearTimeout(this.wt);
    this.wt = setTimeout(() => this.fetch(), 250);
  }

  fetch() {
    const w = this.api.timeline.window();
    if (!this.api.timeline.ok) { this.error = this.api.timeline.error ?? "no tape yet"; return this.render(); }
    this.loading = true; this.render();
    const ask = { from: w.from, to: w.to };
    this.asked = ask;
    bus.push("tape", "insights", ask)
      .then((r) => { if (this.asked !== ask) return; this.data = r; this.window = w; this.error = null; })
      .catch((e) => { this.error = e.message; })
      .finally(() => { this.loading = false; this.render(); });
  }

  label(id) {
    if (!id) return "the observer";
    return this.api.outer()?.nodes.find((n) => n.id === id)?.label ?? id;
  }

  // ---- the live floor: the button, the banners --------------------------

  onLive(snap) {
    const now = new Map();
    let smoke = 0;
    for (const a of snap.attention ?? []) {
      if (a.severity === "alert") now.set(a.node ?? "-", a.text);
      else if (a.severity === "warn") smoke++;
    }
    if (!this.first) {
      const fresh = [...now].filter(([n]) => !this.burning.has(n));
      if (fresh.length) this.say("fire", fresh.length === 1 ? `FIRE · ${this.label(fresh[0][0])}` : `${fresh.length} NEW FIRES`, fresh.map(([n, t]) => t).join(" · "));
      else if (this.burning.size && !now.size) this.say("out", "ALL FIRES OUT", "the floor is calm");
    }
    this.first = false;
    this.burning = now;
    const n = now.size;
    this.btn.dataset.level = n ? "alert" : smoke ? "warn" : "none";
    this.btn.querySelector(".n").textContent = String(n);
    this.btn.title = n ? `${n} building${n > 1 ? "s" : ""} on fire now (alerts)${smoke ? `, ${smoke} smoking (warnings)` : ""}` : smoke ? `no fire; ${smoke} smoking (warnings)` : "no fires: the floor is calm";
  }

  // what is on screen, live or replayed: the alarm glow follows it
  onShown(snap) {
    document.body.classList.toggle("alarm", (snap.attention ?? []).some((a) => a.severity === "alert"));
  }

  say(kind, title, text) {
    const b = this.banner;
    b.dataset.kind = kind;
    b.innerHTML = `<b>${esc(title)}</b>${text ? `<span>${esc(text)}</span>` : ""}`;
    b.hidden = false;
    b.classList.remove("in"); void b.offsetWidth; b.classList.add("in");
    clearTimeout(this.bt);
    this.bt = setTimeout(() => { b.hidden = true; }, kind === "fire" ? 7000 : 4000);
  }

  // ---- the panel ------------------------------------------------------------

  onClick(e) {
    const t = e.target.closest("[data-seek], [data-node], [data-a]");
    if (!t) return;
    if (t.dataset.a === "close") return this.toggle(false);
    if (t.dataset.a === "refresh") return this.fetch();
    if (t.dataset.node) this.api.go(t.dataset.node);
    if (t.dataset.seek) { this.api.timeline.play(false); this.api.timeline.seek(+t.dataset.seek); }
  }

  render() {
    if (!this.open) return;
    const w = this.window ?? this.api.timeline.window();
    const head = `<div class="fi-head"><h3>Fires</h3><span class="fi-win">${w.title ? `window “${esc(w.title)}”` : w.selected ? "selected" : w.live ? "last" : "in view"} ${span(w.to - w.from)}${w.selected || !w.live ? ` · ${hms(w.from)}–${hms(w.to)}` : ""}</span>
      <button type="button" class="fi-x" data-a="refresh" title="Read again">↻</button><button type="button" class="fi-x" data-a="close" aria-label="Close">×</button></div>`;
    if (this.error && !this.data) { this.el.innerHTML = `${head}<p class="fi-err">${esc(this.error)}</p>`; return; }
    if (!this.data) { this.el.innerHTML = `${head}<p class="fi-dim">reading the tape…</p>`; return; }
    const d = this.data, s = d.score;
    const live = this.burning.size;
    const calmPct = d.calm.share == null ? null : Math.round(d.calm.share * 100);
    const streak = live ? `<b class="fi-hot">burning now</b>` : d.calm.last_alert ? `calm for <b>${span(Date.now() - d.calm.last_alert)}</b>` : `<b>no alert on the whole tape</b>`;
    const tile = (cls, n, l, sub = "") => `<div class="fi-tile ${cls}"><b>${n}</b><span>${l}</span>${sub ? `<i>${sub}</i>` : ""}</div>`;
    const maxBurn = Math.max(1, ...d.hot.map((h) => h.alert_ms + h.warn_ms));
    const marks = this.api.timeline.marks.filter((m) => m.at >= d.from && m.at <= d.to).slice(-40).reverse();

    this.el.innerHTML = `${head}
      ${this.error ? `<p class="fi-err">${esc(this.error)} (showing the last answer)</p>` : ""}
      <div class="fi-hud${this.loading ? " loading" : ""}">
        ${tile(live ? "burn" : "", live, "burning now", s.burning ? `${s.burning} objective${s.burning > 1 ? "s" : ""} open` : "")}
        ${tile("start", s.started, "fires started")}
        ${tile("out", s.put_out, "put out", s.put_out_ms != null ? `median ${span(s.put_out_ms)}` : "")}
        ${tile("puff", s.burned_out, "burned out", s.unattended ? `${s.unattended} nobody came` : "")}
        ${tile("", s.respond_ms != null ? span(s.respond_ms) : "–", "to respond", "median, to “looking”")}
        ${tile("", calmPct == null ? "–" : `${calmPct}%`, "calm", "of the tape, no alert")}
      </div>
      <div class="fi-calm"><div class="bar"><span style="width:${calmPct ?? 0}%"></span></div><div class="fi-streak">${streak}</div></div>

      <h4>Where it burns</h4>
      ${d.hot.length ? `<ul class="fi-hot-list">${d.hot.map((h) => `
        <li data-node="${esc(h.node ?? "")}" data-seek="${h.last - 5000}" title="Go there, and replay its last burn">
          <div class="fi-row"><b>${esc(this.label(h.node))}</b><span class="fi-dim">${h.alert_ms ? `<span class="fi-hot">${span(h.alert_ms)} on fire</span>` : ""}${h.alert_ms && h.warn_ms ? " · " : ""}${h.warn_ms ? `${span(h.warn_ms)} smoking` : ""}${h.fires ? ` · ${h.fires} objective${h.fires > 1 ? "s" : ""}` : ""}</span></div>
          <div class="fi-bar"><span class="a" style="width:${(h.alert_ms / maxBurn) * 100}%"></span><span class="w" style="width:${(h.warn_ms / maxBurn) * 100}%"></span></div>
          <div class="fi-text">${esc(h.text)} <span class="fi-dim">· last ${hms(h.last)}</span></div>
        </li>`).join("")}</ul>` : `<p class="fi-calm-note">Nothing burned or smoked in this stretch.</p>`}

      ${d.peaks.length || d.worst ? `<h4>Worst moments</h4><ul class="fi-moments">
        ${d.worst ? `<li data-seek="${d.worst.at}"><span class="fi-hot">${d.worst.alerts} alert${d.worst.alerts === 1 ? "" : "s"}${d.worst.down ? `, ${d.worst.down} down` : ""}</span> at <b>${hms(d.worst.at)}</b> <span class="fi-dim">replay →</span></li>` : ""}
        ${d.peaks.map((p) => `<li data-seek="${p.at - 5000}"><span class="fi-pink">5xx ${p.err_rps}/s</span> at <b>${hms(p.at)}</b> <span class="fi-dim">replay →</span></li>`).join("")}
      </ul>` : ""}

      ${d.repeat.length ? `<h4>Keeps coming back</h4><ul class="fi-repeat">${d.repeat.map((r) => `
        <li data-node="${esc(r.node ?? "")}"><b>${esc(this.label(r.node))}</b> <span class="fi-dim">back ${r.returns}× here · seen ${r.seen_count}× in all · ${esc(r.state)}</span><div class="fi-text">${esc(r.title)}</div></li>`).join("")}</ul>` : ""}

      ${s.longest ? `<h4>Longest burn</h4><p class="fi-longest" data-node="${esc(s.longest.node ?? "")}"><b>${span(s.longest.ms)}</b> ${esc(this.label(s.longest.node))}: ${esc(s.longest.title)} <span class="fi-dim">(${esc(s.longest.state)})</span></p>` : ""}

      <h4>Log</h4>
      ${marks.length ? `<ul class="fi-log">${marks.map((m) => `<li data-seek="${m.at - (m.kind === "fire" ? 5000 : 0)}" class="k-${m.kind}"><span class="t">${hms(m.at)}</span> <span class="k">${MARK_WORD[m.raw] ?? MARK_WORD[m.kind]}</span>${m.by ? ` <span class="fi-dim">by ${esc(m.by)}</span>` : ""} <b>${esc(this.label(m.node))}</b> <span class="fi-text">${esc(m.title)}</span></li>`).join("")}</ul>` : `<p class="fi-dim">No objective opened, looked at or closed in this stretch.</p>`}
      <p class="fi-foot">Drag across the timeline to read one stretch. Click anything here to replay it.</p>`;
  }
}
