// Missions: the objectives the floor has raised (ObsFactor.Objectives, over
// the "objectives" channel), as things to check out and cross off before you
// leave.
//
//   * the Missions control in the top bar: how many are undone, red when one
//     is an alert. Hidden only when the observer says it has no store (the
//     join reply's error starts "no objectives store"); any other failure
//     is shown, with its text.
//   * the panel: open (alerts first), cleared itself (went away, nobody
//     checked), done in the last 24 h. Go flies to the building, "I'm on
//     it" says so to everyone, Cross off takes a note.
//   * Flag: pin an objective on the selected building (button in the
//     inspector, or the key f).
//   * the issues lens (key l): scene.focus, only buildings with an undone
//     objective drawn above a veil.
//   * Before you leave: the debrief, and a plain-text handover.
//
// Live over the page's one socket (bus.js): the "objectives" channel's join
// reply is the list, and every change anyone makes (a rule, a pin, a look,
// a cross-off, the 30 s last-seen write) arrives as an `objective` push that
// replaces that row here. Pin and act are channel pushes; their reply is
// only used for errors and for what this browser crossed off, the list
// itself changes when the broadcast comes back, so every viewer sees the same
// thing at the same moment. Nothing is fetched on a timer. The "actions"
// topic feeds the debrief's "Actions this session".
//
// Who you are is a name kept in localStorage: there is one password and no
// accounts, so it is a label, not an identity.

import { esc, duration, utc, bytes } from "./fmt.js";
import * as bus from "./bus.js";

const $ = (id) => document.getElementById(id);
const RECENT_MS = 24 * 3600 * 1000; // done rows the server keeps in its list
const ACTIONS_KEY = "obs_factor.actions";
const ACTIONS_KEPT = 200;
const WHO_KEY = "obs_factor.who";
const CROSSED_KEY = "obs_factor.crossed";
const LENS_KEY = "obs_factor.lens";
const NO_STORE = "no objectives store";

const store = {
  get(area, k) { try { return window[area].getItem(k); } catch { return null; } },
  set(area, k, v) { try { window[area].setItem(k, v); return true; } catch { return false; } },
};

const undone = (o) => o.state !== "done";
const sevRank = (o) => (o.severity === "alert" ? 0 : 1);
const ago = (iso) => (iso ? `${duration((Date.now() - Date.parse(iso)) / 1000)} ago` : "-");
const typing = (el) => !!el?.closest?.("input, textarea, select, [contenteditable=true]");

// An action the observer's engine pass-through published (ObserverProxy, the
// "actions" topic): {at, node, member, path, params, by, status, result, error}.
// Read as "gc 0.230.0 on fakeapp — ok" with what it did, not as raw JSON.
function observerActionText(a, seen) {
  const parts = a.path.split("/");
  const p = a.params ?? {};
  const r = a.result ?? {};
  let verb = parts[parts.length - 1], target = parts.slice(0, -1).join("/");
  if (parts[0] === "proc") target = parts[1];
  else if (parts[0] === "tree" && verb === "restart") target = `${p.child_id ?? "?"} under ${p.supervisor ?? "?"} (${parts[1]})`;
  else if (parts[0] === "logger") { verb = "logger level"; target = p.level ?? ""; }
  if (verb === "exit" && p.reason) verb = `exit(${p.reason})`;
  const where = `${a.node ?? "?"}${a.member ? ` (${a.member})` : ""}`;
  const ok = a.status >= 200 && a.status < 300;
  const state = ok ? "ok" : `${a.status === 403 || a.status === 409 ? "refused" : "failed"} (${a.status})`;
  let did = null;
  if (ok) {
    if (r.action === "gc") did = `memory ${bytes(r.memory_before)} → ${bytes(r.memory_after)}`;
    else if (r.action === "kill" || r.action === "exit") did = `alive after: ${r.alive_after}, exit reason ${r.exit_reason}`;
    else if (r.action === "restart") did = `${r.old_pid ?? "?"} → ${r.new_pid ?? "?"}`;
    else if (r.action === "logger_level") did = `${r.before} → ${r.level}`;
    else did = JSON.stringify(r);
  }
  return {
    head: `${verb} ${target} on ${where} — ${state}`,
    by: a.by ?? null,
    at: a.at ?? seen,
    err: a.error ?? null,
    result: did,
    rest: null,
  };
}

export class Missions {
  // api: snap() what is on screen, outer() the floor, insideOf() the building
  // we are in or null, scenes() [scene, under], go(id) -> null | why not,
  // target() -> {id, label, part} | null (what Flag would pin), onOpen(),
  // redraw().
  constructor(api) {
    this.api = api;
    this.list = [];
    this.configured = null; // null: not asked yet; false: the observer has no store
    this.error = null;
    this.loaded = false;
    this.lens = store.get("localStorage", LENS_KEY) === "on";
    this.expanded = new Set();
    this.crossing = null; // id whose cross-off note is being written
    this.drafts = new Map(); // id -> note text, kept across re-renders
    this.itemErr = new Map(); // id -> message from the last thing done to it
    this.who = store.get("localStorage", WHO_KEY) || "";
    this.crossed = this.loadCrossed();
    this.noticed = false;
    this.leaving = false;
    this.link = bus.state(); // the socket's state, shown when it is not connected
    this.actions = this.loadActions();
    this.actionsErr = null;
    this.resyncing = false;

    this.btn = $("missionsbtn");
    this.el = $("missions");
    this.flagBtn = $("inspector-flag");
    this.el.innerHTML = `
      <div class="ms-head"><h3>Missions <span class="unk ms-sum"></span></h3>
        <button class="iconbtn" data-close aria-label="Close">×</button></div>
      <div class="ms-who"></div>
      <div class="ms-bar">
        <button type="button" class="ms-lens" aria-pressed="false" title="Key l">Issues lens</button>
        <button type="button" class="ms-debrief">Before you leave</button>
      </div>
      <p class="ms-lensnote unk" hidden></p>
      <p class="ms-err" hidden></p>
      <div class="ms-list"></div>`;
    this.whoEl = this.el.querySelector(".ms-who");
    this.listEl = this.el.querySelector(".ms-list");
    this.errEl = this.el.querySelector(".ms-err");
    this.lensBtn = this.el.querySelector(".ms-lens");
    this.lensNote = this.el.querySelector(".ms-lensnote");

    this.modal = document.createElement("div");
    this.modal.id = "ms-modal";
    this.modal.hidden = true;
    document.body.appendChild(this.modal);
    this.toast = document.createElement("button");
    this.toast.type = "button";
    this.toast.id = "ms-toast";
    this.toast.hidden = true;
    document.body.appendChild(this.toast);

    this.btn.addEventListener("click", () => this.toggle());
    this.el.querySelector("[data-close]").addEventListener("click", () => this.toggle(false));
    this.lensBtn.addEventListener("click", () => this.setLens(!this.lens));
    this.el.querySelector(".ms-debrief").addEventListener("click", () => this.debrief());
    this.el.addEventListener("click", (e) => this.onClick(e));
    this.el.addEventListener("input", (e) => { const id = e.target.dataset.note; if (id) this.drafts.set(id, e.target.value); });
    this.el.addEventListener("submit", (e) => this.onSubmit(e));
    this.el.addEventListener("toggle", (e) => {
      const d = e.target.closest?.("details[data-id]");
      if (d) d.open ? this.expanded.add(d.dataset.id) : this.expanded.delete(d.dataset.id);
    }, true);
    this.flagBtn.addEventListener("click", () => this.flag());
    this.toast.addEventListener("click", () => { this.toast.hidden = true; this.toggle(true); });
    this.modal.addEventListener("click", (e) => { if (e.target === this.modal) this.closeModal(); });

    // f and l from anywhere on the floor; Escape closes a form before anything else sees it
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && !this.modal.hidden) { e.stopPropagation(); this.closeModal(); return; }
      if (e.metaKey || e.ctrlKey || e.altKey || typing(e.target) || !this.modal.hidden) return;
      if (!this.configured) return;
      if (e.key === "f" && this.api.target()) { e.preventDefault(); this.flag(); }
      else if (e.key === "l") { e.preventDefault(); this.setLens(!this.lens); }
    }, true);

    // Logging out with something crossed off this session: the debrief first.
    const out = document.querySelector('form[action="/logout"]');
    out?.addEventListener("submit", (e) => {
      if (this.leaving || !this.configured || !this.crossed.length) return;
      e.preventDefault();
      this.debrief(out);
    });

    this.connect();
  }

  get open() { return !this.el.hidden; }

  toggle(open) {
    const want = open ?? this.el.hidden;
    if (want && !this.configured) return;
    this.el.hidden = !want;
    this.btn.setAttribute("aria-expanded", String(want));
    document.body.classList.toggle("missions-open", want);
    if (want) { this.api.onOpen(); this.toast.hidden = true; this.render(); }
    this.api.redraw();
  }

  // ---- live -------------------------------------------------------------

  connect() {
    bus.onState((st) => { this.link = st; this.renderButton(); if (this.open) this.render(); });
    bus.subscribe("objectives", (event, payload) => {
      if (event === "objective") this.merge(payload);
      else if (event === "list") this.replace(payload);
    }, {
      // the join reply, and again after every reconnect: the whole list
      onJoin: (reply) => this.replace(reply),
      onError: (reason) => { this.configured = true; this.error = `the objectives channel refused the join: ${reason}`; this.changed(); },
    });
    bus.subscribe("actions", (event, payload) => {
      if (event === "action") this.addAction(payload);
    }, {
      onJoin: () => { this.actionsErr = null; },
      onError: (reason) => { this.actionsErr = `the actions channel refused the join: ${reason}`; },
    });
  }

  // {objectives} or {error}, from a join reply or a `list` push
  replace(r) {
    if (r && Array.isArray(r.objectives)) {
      this.configured = true; this.error = null; this.loaded = true;
      this.list = r.objectives;
    } else if (typeof r?.error === "string" && r.error.startsWith(NO_STORE)) {
      this.configured = false; this.error = r.error; this.list = []; this.loaded = false;
      if (this.open) this.toggle(false);
      this.flagBtn.hidden = true;
    } else {
      // the store is there but failing: say so, keep what we had
      this.configured = true;
      this.error = r?.error ?? `the objectives join answered ${JSON.stringify(r)}`;
    }
    this.changed();
  }

  // one changed row, whoever changed it
  merge(row) {
    if (!row || row.id == null) return;
    const i = this.list.findIndex((o) => o.id === row.id);
    if (i >= 0) this.list[i] = row; else this.list.unshift(row);
    if (row.state !== "done") this.crossed = this.crossed.filter((c) => c.id !== row.id);
    this.saveCrossed();
    // The list could not be read when we joined and the store is answering
    // again: read it once, since changes alone do not make a whole list.
    if (this.error && !this.resyncing) this.resync();
    this.changed();
  }

  async resync() {
    this.resyncing = true;
    try {
      const r = await fetch("/api/objectives", { cache: "no-store", credentials: "same-origin", headers: { accept: "application/json" } });
      if (r.status === 401) { window.location.assign("/login"); return; }
      const j = await r.json().catch(() => null);
      if (r.ok && j) this.replace(j);
      else this.replace({ error: j?.error || `GET /api/objectives answered ${r.status} without a reason` });
    } catch (x) {
      this.replace({ error: `GET /api/objectives: the observer did not answer: ${x.message}` });
    } finally {
      this.resyncing = false;
    }
  }

  changed() {
    // the server's list keeps done rows for 24 h; one merged in here does too
    const cut = Date.now() - RECENT_MS;
    this.list = this.list.filter((o) => o.state !== "done" || !o.done_at || Date.parse(o.done_at) > cut);
    this.renderButton();
    this.applyLens();
    if (this.open) this.render();
    if (!this.noticed && this.loaded) { this.noticed = true; this.notice(); }
  }

  async act(id, action, note) {
    if (!this.requireWho()) return false;
    this.itemErr.delete(String(id));
    let row;
    try {
      row = await bus.push("objectives", "act", { id: Number(id), action, by: this.who, note: note || undefined });
    } catch (x) {
      this.itemErr.set(String(id), `${action === "done" ? "Cross off" : action === "look" ? "I'm on it" : "Reopen"} failed: ${x.message}`);
      this.render(true);
      return false;
    }
    // the list changes when the broadcast arrives; this only remembers what *I* crossed off
    if (action === "done") {
      this.crossed = this.crossed.filter((c) => c.id !== row.id);
      this.crossed.push({ id: row.id, title: row.title, node: row.node, label: this.label(row.node).text, severity: row.severity, note: row.note, by: row.done_by, at: row.done_at });
      this.saveCrossed();
    }
    if (action === "reopen") { this.crossed = this.crossed.filter((c) => c.id !== row.id); this.saveCrossed(); }
    return true;
  }

  // ---- actions this session (the "actions" topic) ---------------------------

  addAction(a) {
    if (!a || typeof a !== "object") return;
    this.actions.push({ seen: new Date().toISOString(), a });
    if (this.actions.length > ACTIONS_KEPT) this.actions = this.actions.slice(-ACTIONS_KEPT);
    store.set("sessionStorage", ACTIONS_KEY, JSON.stringify(this.actions));
  }

  loadActions() {
    try { return JSON.parse(store.get("sessionStorage", ACTIONS_KEY) || "[]"); } catch { return []; }
  }

  // One line for whatever the engine published: it names its own fields, so
  // the known ones are picked out and the rest is shown as it came.
  actionText({ seen, a }) {
    if (typeof a.path === "string" && typeof a.status === "number") return observerActionText(a, seen);
    const what = a.action ?? a.kind ?? a.name ?? a.type ?? "action";
    const on = a.target ?? a.node ?? a.container ?? a.pid ?? a.id;
    const state = a.state ?? a.status ?? (a.error ? "failed" : a.ok === true ? "ok" : null);
    const known = new Set(["action", "kind", "name", "type", "target", "node", "container", "pid", "id", "state", "status", "ok", "error", "result", "by", "at"]);
    const rest = Object.entries(a).filter(([k]) => !known.has(k));
    return {
      head: `${what}${on != null ? ` ${on}` : ""}${state ? ` — ${state}` : ""}`,
      by: a.by ?? null,
      at: a.at ?? seen,
      err: a.error != null ? (typeof a.error === "string" ? a.error : JSON.stringify(a.error)) : null,
      result: a.result != null ? (typeof a.result === "string" ? a.result : JSON.stringify(a.result)) : null,
      rest: rest.length ? JSON.stringify(Object.fromEntries(rest)) : null,
    };
  }

  loadCrossed() {
    try { return JSON.parse(store.get("sessionStorage", CROSSED_KEY) || "[]"); } catch { return []; }
  }
  saveCrossed() { store.set("sessionStorage", CROSSED_KEY, JSON.stringify(this.crossed)); }

  // ---- who you are ----------------------------------------------------------

  requireWho() {
    if (this.who) return true;
    if (!this.open) this.toggle(true);
    this.whoMsg = "Say who you are first: what you do here is signed with it.";
    this.renderWho(this.whoMsg);
    this.whoEl.querySelector("input")?.focus();
    return false;
  }

  setWho(name) {
    this.who = name.trim().slice(0, 60);
    this.whoMsg = null;
    if (!store.set("localStorage", WHO_KEY, this.who)) this.whoNote = "this browser will not keep it: you will be asked again next time";
    this.renderWho();
  }

  // ---- the lens ---------------------------------------------------------------

  setLens(on) {
    this.lens = on;
    store.set("localStorage", LENS_KEY, on ? "on" : "off");
    this.applyLens();
    if (this.open) this.render();
  }

  // Every building with an undone objective: alert beats warn. The ids are
  // the floor's, so inside a building the lens is on the floor underneath,
  // not on the inside (whose ids are its own and can collide with them).
  focusMap() {
    const m = new Map();
    for (const o of this.list) {
      if (!undone(o) || !o.node) continue;
      if (o.severity === "alert" || !m.has(o.node)) m.set(o.node, o.severity === "alert" ? "alert" : "warn");
    }
    return m;
  }

  applyLens() {
    const [scene, under] = this.api.scenes();
    const on = this.lens && this.configured;
    const m = on ? this.focusMap() : null;
    if (this.api.lens) {
      // main.js's lens owner: one lens at a time; another taking it turns this one off
      if (on) this.api.lens.claim("missions", { map: m, label: "Issues lens", detail: "buildings with an undone objective", onDrop: () => this.setLens(false) });
      else this.api.lens.drop("missions");
    } else {
      scene.focus = on && !this.api.insideOf() ? m : null;
      under.focus = on && this.api.insideOf() ? m : null;
    }
    this.lensBtn.setAttribute("aria-pressed", String(!!on));
    this.lensBtn.classList.toggle("on", !!on);
    const outer = this.api.outer();
    if (on && outer) {
      const ids = new Set(outer.nodes.map((n) => n.id));
      const lit = [...m.keys()].filter((id) => ids.has(id)).length;
      const n = this.list.filter(undone).length;
      this.lensNote.textContent = `Lens on: ${lit} building${lit === 1 ? "" : "s"} lit for ${n} undone objective${n === 1 ? "" : "s"}` +
        (n > lit ? ` (the rest have no building on the floor)` : "") + (this.api.insideOf() ? ". Inside a building it lights the floor underneath." : ".") +
        (window.innerWidth < 760 ? " Close this panel to see it." : "");
      this.lensNote.hidden = false;
    } else this.lensNote.hidden = true;
    this.api.redraw();
  }

  // ---- labels ---------------------------------------------------------------

  // The node's label from the snapshot on screen; says so when it is not there.
  label(id) {
    if (!id) return { text: "no building", on: false, none: true };
    const outer = this.api.outer();
    const n = outer?.nodes.find((x) => x.id === id);
    if (n) return { text: n.label, on: true };
    return { text: `${id}, not on the floor now`, on: false };
  }

  // ---- rendering ------------------------------------------------------------

  renderButton() {
    const b = this.btn;
    if (this.configured === false || this.configured === null) { b.hidden = true; this.flagBtn.hidden = true; return; }
    b.hidden = false;
    this.flagBtn.hidden = false;
    const u = this.list.filter(undone);
    const alerts = u.filter((o) => o.severity === "alert").length;
    b.dataset.level = this.error ? "error" : alerts ? "alert" : u.length ? "warn" : "none";
    b.querySelector(".n").textContent = this.error ? "!" : String(u.length);
    b.title = this.error ? `Missions: ${this.error}` : `${u.length} undone: ${alerts} alert${alerts === 1 ? "" : "s"}, ${u.length - alerts} warning${u.length - alerts === 1 ? "" : "s"}`;
  }

  renderWho(msg, edit = false) {
    if (this.who && !msg && !edit) {
      this.whoEl.innerHTML = `<span class="unk">you are</span> <b>${esc(this.who)}</b> <button type="button" class="ms-link" data-who-change>change</button>${this.whoNote ? ` <span class="ms-warn">${esc(this.whoNote)}</span>` : ""}`;
      return;
    }
    this.whoEl.innerHTML = `<form class="ms-whoform" data-form="who"><label>Who's on the floor? <input name="who" maxlength="60" required placeholder="your name" value="${esc(this.who)}" autocomplete="nickname" spellcheck="false"></label><button type="submit">Save</button></form>${msg ? `<p class="ms-warn">${esc(msg)}</p>` : ""}`;
  }

  render(force = false) {
    // Never pull an input out from under someone typing; the next change renders.
    if (!force && this.el.contains(document.activeElement) && typing(document.activeElement) && !this.whoEl.contains(document.activeElement)) return;
    if (!this.whoEl.contains(document.activeElement)) this.renderWho(this.whoMsg);
    const offline = this.link.state !== "connected" ? `Not live (${this.link.state}${this.link.detail ? `: ${this.link.detail}` : ""}): changes made elsewhere will show once the socket is back.` : "";
    const msg = [this.error ? `Could not read the objectives: ${this.error}` : "", offline].filter(Boolean).join(" ");
    this.errEl.hidden = !msg;
    this.errEl.textContent = msg;
    const u = this.list.filter(undone);
    const open = u.filter((o) => o.state === "open" || o.state === "looking").sort((a, b) => sevRank(a) - sevRank(b) || Date.parse(b.opened_at) - Date.parse(a.opened_at));
    const cleared = u.filter((o) => o.state === "cleared");
    const done = this.list.filter((o) => o.state === "done");
    this.el.querySelector(".ms-sum").textContent = this.loaded ? `${open.length} open · ${cleared.length} to check · ${done.length} done in 24 h` : this.error ? "not read" : "loading…";
    const section = (title, items, hint) => `<section><h4>${title} <span class="unk">${items.length}</span></h4>${hint && items.length ? `<p class="unk ms-hint">${hint}</p>` : ""}${items.length ? items.map((o) => this.item(o)).join("") : '<p class="unk ms-none">nothing</p>'}</section>`;
    this.listEl.innerHTML = !this.loaded ? (this.error ? "" : '<p class="unk">Loading…</p>') :
      section("Open", open) +
      section("Cleared itself — check and cross off", cleared, "These went away on their own and nobody has looked. Cross off once you know why.") +
      section("Done in the last 24 h", done);
    if (this.crossing) this.listEl.querySelector(`[data-note="${this.crossing}"]`)?.focus();
  }

  item(o) {
    const id = String(o.id);
    const lab = this.label(o.node);
    const pinnedBy = o.source === "pin" ? o.events.find((e) => e.kind === "pinned")?.by : null;
    const state = o.state === "looking" ? `<span class="ms-looking">looking — ${esc(o.looking_by || "someone")}</span>`
      : o.state === "cleared" ? `<span class="ms-cleared">cleared itself ${esc(ago(o.cleared_at))}</span>`
      : o.state === "done" ? `<span class="ms-done">crossed off by ${esc(o.done_by || "someone")} ${esc(ago(o.done_at))}</span>` : "";
    const acts = [];
    if (o.node) acts.push(`<button type="button" data-go="${esc(o.node)}"${lab.on ? "" : ' class="ms-gone"'}>Go</button>`);
    if (o.state === "open" || o.state === "cleared" || (o.state === "looking" && o.looking_by !== this.who)) acts.push(`<button type="button" data-act="look" data-id="${id}">I'm on it</button>`);
    if (undone(o)) acts.push(`<button type="button" class="ms-cross" data-cross="${id}">Cross off</button>`);
    if (o.state === "done") acts.push(`<button type="button" data-act="reopen" data-id="${id}">Reopen</button>`);
    const form = this.crossing === id ? `<form class="ms-crossform" data-form="cross" data-id="${id}">
        <textarea data-note="${id}" rows="2" maxlength="1000" placeholder="What was it, what did you do? (goes in the handover)">${esc(this.drafts.get(id) ?? "")}</textarea>
        <div><button type="submit" class="ms-cross">Cross off</button><button type="button" data-cancel>Cancel</button></div></form>` : "";
    const err = this.itemErr.get(id);
    const events = o.events.map((e) => `<li><time title="${esc(e.at)}">${esc(ago(e.at))}</time> <b>${esc(e.kind)}</b>${e.by ? ` by ${esc(e.by)}` : ""}${e.note ? `: ${esc(e.note)}` : ""}</li>`).join("");
    return `<article class="ms-item sev-${esc(o.severity)} st-${esc(o.state)}" data-oid="${id}">
      <div class="ms-top"><span class="ms-sev">${esc(o.severity)}</span><span class="ms-title">${esc(o.title)}</span></div>
      <div class="ms-meta"><span class="${lab.on ? "" : lab.none ? "ms-nobldg" : "ms-off"}">${esc(lab.text)}</span> · opened ${esc(ago(o.opened_at))} · seen ${esc(o.seen_count)}× · ${o.source === "pin" ? `flagged${pinnedBy ? ` by ${esc(pinnedBy)}` : ""}` : "from a rule"} ${state}</div>
      ${o.note ? `<div class="ms-note">“${esc(o.note)}”</div>` : ""}
      <div class="ms-acts">${acts.join("")}</div>
      ${form}
      ${err ? `<p class="ms-warn">${esc(err)}</p>` : ""}
      <details data-id="${id}" ${this.expanded.has(id) ? "open" : ""}><summary>history <span class="unk">${o.events.length}</span></summary><ol class="ms-events">${events || "<li class=unk>no events</li>"}</ol></details>
    </article>`;
  }

  onClick(e) {
    const b = e.target.closest("button");
    if (!b || !this.el.contains(b)) return;
    if (b.hasAttribute("data-who-change")) { this.renderWho(null, true); this.whoEl.querySelector("input")?.select(); return; }
    if (b.dataset.go !== undefined) {
      const id = b.dataset.go;
      const why = id ? this.api.go(id) : "this objective is not about a building";
      const oid = b.closest("[data-oid]")?.dataset.oid;
      if (why && oid) { this.itemErr.set(oid, `Go: ${why}`); this.render(true); }
      return;
    }
    if (b.dataset.act) { this.act(b.dataset.id, b.dataset.act); return; }
    if (b.dataset.cross) {
      if (!this.requireWho()) return;
      this.crossing = b.dataset.cross; this.render(true); return;
    }
    if (b.hasAttribute("data-cancel")) { this.crossing = null; this.render(true); }
  }

  async onSubmit(e) {
    const f = e.target;
    e.preventDefault();
    if (f.dataset.form === "who") { this.setWho(f.elements.who.value); this.render(true); return; }
    if (f.dataset.form === "cross") {
      const id = f.dataset.id;
      const note = f.querySelector("textarea").value.trim();
      f.querySelectorAll("button").forEach((x) => { x.disabled = true; });
      if (await this.act(id, "done", note)) { this.crossing = null; this.drafts.delete(id); this.render(true); }
    }
  }

  // ---- the notice on load -----------------------------------------------------

  notice() {
    const u = this.list.filter(undone);
    if (!u.length || this.open) return;
    const alerts = u.filter((o) => o.severity === "alert").length;
    this.toast.innerHTML = `<b>${u.length}</b> objective${u.length === 1 ? "" : "s"} waiting${alerts ? ` <span class="ms-a">${alerts} alert${alerts === 1 ? "" : "s"}</span>` : ""} <span class="unk">open missions →</span>`;
    this.toast.hidden = false;
    setTimeout(() => { this.toast.hidden = true; }, 9000);
  }

  // ---- flag a building ---------------------------------------------------------

  flag() {
    if (!this.configured) return;
    const t = this.api.target();
    if (!t) return;
    const who = this.who ? "" : `<label>Who are you? <input name="who" maxlength="60" required placeholder="your name" autocomplete="nickname" spellcheck="false"></label>`;
    this.showModal(`<form class="ms-flag" data-form="flag">
      <h3>Flag <b>${esc(t.label)}</b></h3>
      <p class="unk">An objective pinned to this building: open until someone crosses it off. Everyone with the page sees it.</p>
      ${who}
      <label>What looks wrong <input name="title" maxlength="200" required value="${esc(t.part ? `${t.part} inside ${t.label} looks wrong` : "")}" placeholder="${esc(t.label)} feels slow" spellcheck="false"></label>
      <label>Note <textarea name="note" rows="3" maxlength="1000" placeholder="what you saw, where to look"></textarea></label>
      <p class="ms-warn" hidden></p>
      <div class="ms-mbtns"><button type="submit" class="ms-cross">Flag it</button><button type="button" data-cancel>Cancel</button></div>
    </form>`);
    const f = this.modal.querySelector("form");
    (f.elements.who ?? f.elements.title).focus();
    f.querySelector("[data-cancel]").addEventListener("click", () => this.closeModal());
    f.addEventListener("submit", async (e) => {
      e.preventDefault();
      if (f.elements.who) this.setWho(f.elements.who.value);
      const err = f.querySelector(".ms-warn");
      f.querySelectorAll("button").forEach((x) => { x.disabled = true; });
      try {
        await bus.push("objectives", "pin", { node: t.id, title: f.elements.title.value, note: f.elements.note.value, by: this.who });
      } catch (x) {
        err.textContent = `Not flagged: ${x.message}`; err.hidden = false; f.querySelectorAll("button").forEach((b) => { b.disabled = false; }); return;
      }
      // the pin is in the list when its broadcast arrives (already, or in a moment)
      this.closeModal();
      this.toggle(true);
    });
  }

  // ---- before you leave ---------------------------------------------------------

  debrief(logoutForm = null) {
    const u = this.list.filter(undone);
    const open = u.filter((o) => o.state !== "cleared").sort((a, b) => sevRank(a) - sevRank(b));
    const cleared = u.filter((o) => o.state === "cleared");
    const text = this.handover(open, cleared);
    const li = (o) => `<li class="sev-${esc(o.severity)}"><span class="ms-sev">${esc(o.severity)}</span> ${esc(o.title)} <span class="unk">— ${esc(this.label(o.node).text)}${o.state === "looking" ? `, looking: ${esc(o.looking_by)}` : ""}, opened ${esc(ago(o.opened_at))}</span></li>`;
    const sec = (t, items, f) => `<h4>${t} <span class="unk">${items.length}</span></h4>${items.length ? `<ul>${items.map(f).join("")}</ul>` : '<p class="unk">none</p>'}`;
    this.showModal(`<div class="ms-debriefbox" role="dialog" aria-labelledby="ms-dt">
      <h3 id="ms-dt">Before you leave</h3>
      ${this.error ? `<p class="ms-warn">The list may be stale: ${esc(this.error)}</p>` : ""}
      ${sec("Still open", open, li)}
      ${sec("Cleared itself, nobody checked", cleared, li)}
      ${sec("Actions this session", this.actions, (x) => { const t = this.actionText(x); return `<li><b>${esc(t.head)}</b> <span class="unk">${t.by ? `by ${esc(t.by)}, ` : ""}${esc(ago(t.at))}</span>${t.err ? `<div class="ms-warn">${esc(t.err)}</div>` : ""}${t.result ? `<div class="unk">${esc(t.result)}</div>` : ""}${t.rest ? `<div class="unk ms-raw">${esc(t.rest)}</div>` : ""}</li>`; })}
      ${this.actionsErr ? `<p class="ms-warn">${esc(this.actionsErr)}</p>` : !this.actions.length ? '<p class="unk">Everything anyone asks the observer to do, and what came of it, is listed here as it happens (the "actions" topic). Nothing has been asked since this tab opened.</p>' : ""}
      ${sec("You crossed off this session", this.crossed, (c) => `<li><span class="ms-sev">${esc(c.severity)}</span> ${esc(c.title)} <span class="unk">— ${esc(c.label)}</span>${c.note ? `<div class="ms-note">“${esc(c.note)}”</div>` : '<div class="unk">no note</div>'}</li>`)}
      <h4>Handover <span class="unk">plain text</span></h4>
      <textarea class="ms-handover" rows="8" readonly>${esc(text)}</textarea>
      <p class="ms-copied unk" hidden></p>
      <div class="ms-mbtns"><button type="button" data-copy class="ms-cross">Copy handover</button>${logoutForm ? '<button type="button" data-out>Log out</button>' : ""}<button type="button" data-cancel>${logoutForm ? "Stay" : "Close"}</button></div>
    </div>`);
    const box = this.modal.querySelector(".ms-debriefbox");
    box.querySelector("[data-cancel]").addEventListener("click", () => this.closeModal());
    box.querySelector("[data-copy]").addEventListener("click", async () => {
      const ta = box.querySelector("textarea"), msg = box.querySelector(".ms-copied");
      try { await navigator.clipboard.writeText(text); msg.textContent = "Copied."; }
      catch (x) { ta.focus(); ta.select(); msg.textContent = `The browser would not copy (${x.message}); it is selected, copy it yourself.`; }
      msg.hidden = false;
    });
    box.querySelector("[data-out]")?.addEventListener("click", () => { this.leaving = true; logoutForm.submit(); });
  }

  handover(open, cleared) {
    const line = (o) => `  [${o.severity}] ${o.title} — ${this.label(o.node).text}; opened ${ago(o.opened_at)}, seen ${o.seen_count}x${o.state === "looking" ? `, looking: ${o.looking_by}` : ""}${o.note ? `; note: ${o.note}` : ""}`;
    const now = new Date();
    return [
      `obs_factor handover, ${now.toISOString().slice(0, 10)} ${utc(now)} UTC${this.who ? `, from ${this.who}` : ""}`,
      ...(this.error ? [`(the objectives could not be read just now: ${this.error})`] : []),
      "",
      `Still open (${open.length}):`, ...(open.length ? open.map(line) : ["  none"]),
      "",
      `Cleared itself, nobody checked (${cleared.length}):`, ...(cleared.length ? cleared.map(line) : ["  none"]),
      "",
      `Crossed off this session (${this.crossed.length}):`,
      ...(this.crossed.length ? this.crossed.map((c) => `  [${c.severity}] ${c.title} — ${c.label}: ${c.note || "no note"}`) : ["  none"]),
      "",
      `Actions this session (${this.actions.length}):`,
      ...(this.actionsErr ? [`  (${this.actionsErr})`] : []),
      ...(this.actions.length ? this.actions.map((x) => { const t = this.actionText(x); return `  ${t.head}${t.by ? ` by ${t.by}` : ""}, ${ago(t.at)}${t.err ? `: ${t.err}` : ""}${t.result ? `: ${t.result}` : ""}`; }) : ["  none"]),
    ].join("\n");
  }

  showModal(html) {
    this.modal.innerHTML = html;
    this.modal.hidden = false;
  }

  closeModal() {
    this.modal.hidden = true;
    this.modal.innerHTML = "";
  }
}
