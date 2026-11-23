// DOM overlays: label chips over buildings, the top bar, the attention
// strip, the legend. Text lives in the DOM, not on the canvas, so it stays
// sharp, selectable by screen readers and cheap to restyle.

import { num, withUnit, bytes, bps, utc, esc, isNum, UNKNOWN } from "./fmt.js";
import { itemColor } from "./render.js";

const $ = (id) => document.getElementById(id);

export const WARN_SVG = '<svg viewBox="0 0 24 24" width="15" height="15" aria-hidden="true"><path d="M12 3L2 21h20L12 3z" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linejoin="round"/><path d="M12 10v5M12 18v.5" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/></svg>';

export function headlineText(h) {
  if (!h) return UNKNOWN;
  const unit = h.unit ?? "";
  if (!isNum(h.value)) return unit ? `${UNKNOWN} ${unit}` : UNKNOWN;
  if (unit === "% built") return `${num(h.value)}% built`;
  if (unit.startsWith("%")) return `${num(h.value)}${unit}`;
  if (unit === "B") return bytes(h.value);
  if (unit === "B/s") return bps(h.value);
  return unit ? `${num(h.value)} ${unit}` : num(h.value);
}

// ---- chips ----------------------------------------------------------------

export class Chips {
  constructor(root) {
    this.root = root;
    this.els = new Map();
  }

  update(snap) {
    const seen = new Set();
    for (const n of snap.nodes) {
      seen.add(n.id);
      let c = this.els.get(n.id);
      if (!c) {
        const el = document.createElement("div");
        el.className = "chip";
        this.root.appendChild(el);
        c = { el, html: "", w: 0, h: 0 };
        this.els.set(n.id, c);
      }
      let tag = "";
      if (n.status === "down") tag = `<div class="tag down">${WARN_SVG}<span>down</span></div>`;
      else if (n.status === "blocked") tag = `<div class="tag blocked">${WARN_SVG}<span>${esc(n.reason ?? "blocked")}</span></div>`;
      const kindNote = KNOWN_KINDS.has(n.kind) ? "" : ` <i>kind ${esc(n.kind)}?</i>`;
      const html = `${tag}<div class="name"><span>${esc(n.label)}</span><i>${esc(headlineText(n.headline))}</i>${kindNote}</div>`;
      const cls = `chip k-${n.kind} st-${n.status}`;
      if (c.el.dataset.cls !== cls) { c.el.dataset.cls = cls; c.el.className = cls; }
      if (html !== c.html) { c.html = html; c.el.innerHTML = html; c.w = 0; }
      c.node = n;
      c.prio = priority(n, snap);
    }
    for (const [id, c] of this.els) if (!seen.has(id)) { c.el.remove(); this.els.delete(id); }
  }

  // anchorOf(id) -> [sx, sy] screen point above the building, or null
  place(anchorOf, view, selected, zoom) {
    const placed = [];
    const list = [...this.els.entries()].sort((a, b) => (b[0] === selected) - (a[0] === selected) || b[1].prio - a[1].prio);
    for (const [id, c] of list) {
      const a = anchorOf(id);
      if (!c.w) { c.w = c.el.offsetWidth; c.h = c.el.offsetHeight; }
      c.el.classList.toggle("sel", id === selected);
      const lowZoomHide = zoom < 0.22 && c.prio < 50 && id !== selected;
      if (!a || lowZoomHide) { c.el.classList.add("hide"); continue; }
      const r = [a[0] - c.w / 2, a[1] - c.h, a[0] + c.w / 2, a[1]];
      // keep a chip that is partly off the side fully readable
      if (a[0] > 0 && a[0] < view.w) {
        const shift = Math.max(0, 4 - r[0]) - Math.max(0, r[2] - (view.w - 4));
        r[0] += shift; r[2] += shift;
      }
      const off = r[2] < 0 || r[0] > view.w || r[1] < (view.top ?? 0) || r[3] > view.h - (view.bottom ?? 0);
      const hit = placed.some((q) => r[0] < q[2] + 4 && r[2] > q[0] - 4 && r[1] < q[3] + 2 && r[3] > q[1] - 2);
      if (off || hit) { c.el.classList.add("hide"); continue; }
      placed.push(r);
      c.el.classList.remove("hide");
      c.el.style.transform = `translate3d(${Math.round(r[0])}px, ${Math.round(r[1])}px, 0)`;
    }
  }
}

const KNOWN_KINDS = new Set(["proxy", "app", "relay", "db", "static", "external", "resource", "source", "unplaced", "construction"]);

function priority(n, snap) {
  const att = snap.attention.findIndex((a) => a.node === n.id);
  let p = 0;
  if (n.status === "down") p += 400;
  if (n.status === "blocked") p += 300;
  if (att >= 0) p += 200 - att;
  if (n.kind === "proxy" || n.kind === "resource" || n.kind === "source" || n.kind === "db") p += 60;
  if (n.kind === "unplaced") p += 55;
  if (n.kind === "construction" || n.build?.status === "running") p += 80;
  if (isNum(n.headline?.value) && n.headline.unit === "req/s") p += Math.min(40, n.headline.value * 10);
  return p;
}

// ---- top bar --------------------------------------------------------------

export class TopBar {
  // state is the socket's (bus.js): connecting | connected | reconnecting |
  // refused. Connected and fed shows "live", or "stale" when ticks stop.
  constructor() {
    this.state = "connecting";
    this.lastAt = null;
    this.lastRecv = 0;
    this.tick = 5000;
    this.detail = "";
    this.tickError = null;
    setInterval(() => this.renderClock(), 1000);
  }
  snapshot(snap) {
    this.lastAt = new Date(snap.at);
    this.lastRecv = performance.now();
    this.tick = snap.tick_ms || 5000;
    this.tickError = null;
    const ins = snap.edges.filter((e) => e.from === "internet");
    let rate = null;
    if (ins.length && ins.every((e) => isNum(e.rate))) rate = ins.reduce((a, e) => a + e.rate, 0);
    $("inrate").textContent = rate == null ? UNKNOWN : `${num(rate)}/s`;
    $("inrate").parentElement.title = rate == null ? "Requests per second into Caddy: unknown (see sources)" : "Requests per second into Caddy, all hosts";
    this.renderClock();
  }
  // timeline.js: a moment of the tape on screen, or null for live
  setReplay(at) {
    if (at === this.replayAt) return;
    this.replayAt = at;
    this.renderClock();
  }
  setState(state, detail = "") {
    this.state = state;
    this.detail = detail;
    this.renderClock();
  }
  // a tick whose snapshot build failed, or no snapshot yet: said, not hidden
  setTickError(message) {
    this.tickError = message;
    this.renderClock();
  }
  renderClock() {
    const el = $("clock");
    const age = this.lastAt ? (performance.now() - this.lastRecv) / 1000 : null;
    let state = this.state;
    if (state === "connected") state = !this.lastAt ? "connecting" : age * 1000 > Math.max(this.tick * 2.5, 12000) ? "stale" : "live";
    if (this.replayAt != null && state === "live") {
      el.dataset.state = "replay";
      $("live").textContent = "replay";
      $("utc").textContent = utc(new Date(this.replayAt));
      $("stale").textContent = "";
      el.title = "A moment of the tape is on screen. End, or LIVE on the timeline, goes back to now.";
      return;
    }
    el.dataset.state = state;
    $("live").textContent = state === "connecting" && this.state === "connected" ? "waiting for a snapshot" : state;
    if (state === "live") $("utc").textContent = utc(new Date());
    else if (this.lastAt) $("utc").textContent = utc(this.lastAt);
    const old = (state === "stale" || state === "reconnecting" || state === "refused") && age != null ? `${Math.round(age)} s old` : "";
    $("stale").textContent = [old, this.tickError ? "last tick failed" : "", state === "refused" ? this.detail : ""].filter(Boolean).join(" · ");
    const sock = { connecting: "Opening the socket", connected: "Socket connected", reconnecting: "Socket lost, reconnecting", refused: "Socket refused" }[this.state] ?? this.state;
    el.title = [sock + (this.detail ? `: ${this.detail}` : ""), this.tickError, state === "stale" ? "No snapshot for a while; the socket is open but silent" : ""].filter(Boolean).join("\n");
  }
}

// ---- attention strip ------------------------------------------------------

export function renderAttention(snap, clientProblems, onNode, onSources) {
  const items = [];
  for (const a of snap.attention) items.push({ cls: a.severity === "alert" ? "alert" : "warn", text: a.text, node: a.node });
  for (const [name, s] of Object.entries(snap.sources)) {
    if (!s.ok) items.push({ cls: "src", text: `source ${name} failing: ${s.error ?? "no error given"}`, source: name });
  }
  for (const p of clientProblems) items.push({ cls: "warn", text: `layout: ${p}` });
  const strip = $("attention");
  strip.hidden = items.length === 0;
  document.body.classList.toggle("has-attention", items.length > 0);
  const box = $("attention-items");
  box.textContent = "";
  for (const it of items) {
    const b = document.createElement("button");
    b.className = `att ${it.cls}`;
    const label = it.node ? snap.nodes.find((n) => n.id === it.node)?.label ?? it.node : null;
    const prefix = label && !it.text.toLowerCase().includes(label.toLowerCase()) ? `${esc(label)} · ` : "";
    b.innerHTML = `<span class="sev" aria-hidden="true"></span>${prefix}${esc(it.text)}`;
    if (it.node) b.addEventListener("click", () => onNode(it.node));
    else b.addEventListener("click", onSources);
    box.appendChild(b);
  }
}

// ---- legend ---------------------------------------------------------------

export function renderLegend(snap) {
  const items = [...new Set(snap.edges.map((e) => e.item))];
  $("legend-items").innerHTML = items.map((i) => `<span style="--c:${itemColor(i)}">${esc(i)}</span>`).join("");
  $("sources").innerHTML = Object.entries(snap.sources).map(([name, s]) => `<li>
      <span class="${s.ok ? "ok" : "bad"}">${s.ok ? "ok  " : "FAIL"}</span><b>${esc(name)}</b>
      ${s.ok ? `<span class="unk">${s.at ? esc(utc(new Date(s.at))) : ""}</span>` : `<span class="err">${esc(s.error ?? "no error given")}${s.at ? ` (last ok ${esc(utc(new Date(s.at)))})` : ""}</span>`}
    </li>`).join("");
}

// ---- sites ----------------------------------------------------------------
// Every address the box answers on, one row each, with the service behind
// it. `hosts` are whole hostnames with their own Caddy series (rate known);
// `via` are path routes on someone else's hostname (not metered apart).

export function renderSites(snap, onNode) {
  const rows = [];
  // Caddy carries every hostname; list one under Caddy only when no service
  // behind it claims it (a redirect, the bare IP).
  const owned = new Set(snap.nodes.filter((n) => n.kind !== "proxy").flatMap((n) => (n.hosts ?? []).map((h) => h.host)));
  for (const n of snap.nodes) {
    for (const h of n.hosts ?? []) {
      if (n.kind === "proxy" && owned.has(h.host)) continue;
      rows.push({ addr: h.host, rps: h.rps, metered: true, n });
    }
    for (const v of n.via ?? []) rows.push({ addr: v, rps: null, metered: false, n });
  }
  rows.sort((a, b) => a.addr.localeCompare(b.addr));
  const body = $("sites-rows");
  body.textContent = "";
  for (const r of rows) {
    const tr = document.createElement("tr");
    const status = ["working", "idle", "blocked", "down"].includes(r.n.status) ? r.n.status : "unknown";
    const rate = r.metered ? (isNum(r.rps) ? num(r.rps) : UNKNOWN) : `<span class="unk" title="A path route: Caddy counts it under its hostname">via</span>`;
    tr.innerHTML = `<td><span class="lamp ${status}" title="${esc(r.n.status)}${r.n.reason ? `: ${esc(r.n.reason)}` : ""}"></span></td>
      <td><button type="button" class="go">${esc(r.addr)}</button></td>
      <td class="svc">${esc(r.n.label)}</td><td class="r">${rate}</td>
      <td><a href="https://${esc(r.addr.replace(/\*+$/, ""))}" target="_blank" rel="noopener noreferrer" aria-label="Open ${esc(r.addr)}">↗</a></td>`;
    tr.querySelector(".go").addEventListener("click", () => onNode(r.n.id));
    body.appendChild(tr);
  }
}

export { withUnit };
