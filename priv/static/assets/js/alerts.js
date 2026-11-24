// Alerts (ObsFactor.Alerts): where a message goes when something breaks, so
// nobody has to be watching the floor to know. The panel lists the routes
// (a webhook each: Slack's incoming webhooks work, anything that takes JSON
// does), with each one's last send and last error, and adds, edits,
// enables or disables, test-sends and deletes them.
//
// The URL of a route is never sent back to the page (it is the credential):
// a route shows a hint of it, and editing one with the URL left blank keeps
// the URL it has.

import * as bus from "./bus.js";
import { esc } from "./fmt.js";

const pad = (n) => String(n).padStart(2, "0");
const stamp = (ms) => { const d = new Date(ms); return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())} ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`; };
const ago = (ms) => { const s = Math.max(0, (Date.now() - ms) / 1000); return s < 90 ? `${Math.round(s)} s ago` : s < 5400 ? `${Math.round(s / 60)} min ago` : s < 129600 ? `${Math.round(s / 3600)} h ago` : stamp(ms) + " UTC"; };
const hours = (sel) => `<option value="">none</option>${Array.from({ length: 24 }, (_, h) => `<option value="${h}"${sel === h ? " selected" : ""}>${pad(h)}:00</option>`).join("")}`;

export class AlertsPanel {
  constructor(api) {
    this.api = api; // { apps(), sets(), who() }
    this.routes = []; this.filters = []; this.editing = null; this.joined = false;
    this.el = document.createElement("aside");
    this.el.id = "alerts";
    this.el.hidden = true;
    this.el.setAttribute("aria-label", "Alerts: where a message goes when something breaks");
    document.body.appendChild(this.el);
    this.btn = document.getElementById("alertsbtn");
    this.btn?.addEventListener("click", () => this.toggle());
    this.el.addEventListener("click", (e) => this.onClick(e));
    this.el.addEventListener("change", (e) => { if (e.target.name === "enabled" && e.target.dataset.rid) this.setEnabled(+e.target.dataset.rid, e.target.checked); });
    document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !this.el.hidden) { e.preventDefault(); e.stopPropagation(); this.toggle(false); } }, true);
  }

  // joined the first time it is opened, kept after
  join() {
    if (this.joined) return;
    this.joined = true;
    bus.subscribe("alerts", (ev, p) => { if (ev === "routes") { this.routes = p.routes; this.renderList(); } }, {
      onJoin: (r) => {
        if (r.error) { this.error = r.error; return this.render(); }
        this.error = null; this.routes = r.routes; this.filters = r.filters ?? []; this.dedup = r.dedup_minutes; this.allowPrivate = r.allow_private;
        this.render();
      },
      onError: (why) => { this.error = why; this.render(); },
    });
  }

  toggle(open = this.el.hidden) {
    this.el.hidden = !open;
    this.btn?.setAttribute("aria-expanded", String(open));
    if (open) { this.join(); this.render(); }
  }

  sets() { const s = this.api.sets?.() ?? []; return s.length ? s : this.filters; }

  render() {
    if (this.el.hidden) return;
    if (this.error) { this.el.innerHTML = `${this.head()}<p class="al-err">${esc(this.error)}</p>`; return; }
    this.el.innerHTML = `${this.head()}
      <p class="al-dim">An alert objective opening or coming back, and BEAM wire alerts (a crash, a partition, a failing stream, an error, atoms past 80 %, Postgres full), go to every route that wants them: one message per tick, the same thing at most once per ${esc(this.dedup ?? 15)} min, and a resolved message when it clears or is crossed off.</p>
      <div class="al-list"></div>
      <p class="al-msg" hidden></p>
      ${this.editing ? this.form(this.editing) : `<div class="al-acts"><button type="button" class="go" data-a="new">Add a route</button></div>`}`;
    this.renderList();
  }

  head() { return `<div class="al-head"><h3>Alerts</h3><button type="button" class="fi-x" data-a="close" aria-label="Close">×</button></div>`; }

  renderList() {
    const box = this.el.querySelector(".al-list");
    if (!box) return;
    const sets = this.sets();
    box.innerHTML = this.routes.length ? `<ul>${this.routes.map((r) => {
      const what = [r.min_severity === "warn" ? "alerts and warnings" : "alerts",
        r.apps.length ? `only ${r.apps.map(esc).join(", ")}` : null,
        r.filter_id ? `wire: ${esc(sets.find((s) => s.id === r.filter_id)?.name ?? `set ${r.filter_id} (gone)`)}` : null,
        r.quiet_from != null ? `quiet ${pad(r.quiet_from)}:00–${pad(r.quiet_to)}:00 UTC` : null,
        `once per ${r.dedup_minutes} min`].filter(Boolean).join(" · ");
      return `<li data-rid="${r.id}" class="${r.enabled ? "" : "off"}">
        <div class="al-row"><label class="al-sw" title="${r.enabled ? "enabled: click to disable" : "disabled: click to enable"}"><input type="checkbox" name="enabled" data-rid="${r.id}"${r.enabled ? " checked" : ""}></label><b>${esc(r.name)}</b><span class="al-dim al-hint">${esc(r.url_hint)}</span></div>
        <div class="al-dim">${what}</div>
        <div class="al-dim">${r.last_sent_at ? `last sent ${ago(r.last_sent_at)} · ${r.sent_count} in all` : "never sent"}${r.by ? ` · by ${esc(r.by)}` : ""}</div>
        ${r.last_error ? `<div class="al-err" title="${r.last_error_at ? stamp(r.last_error_at) + " UTC" : ""}">${r.last_error_at && (!r.last_sent_at || r.last_error_at > r.last_sent_at) ? "failing" : "failed"} ${r.last_error_at ? ago(r.last_error_at) : ""}: ${esc(r.last_error)}</div>` : ""}
        <div class="al-l"><button type="button" data-a="test">test</button><button type="button" data-a="edit">edit</button><button type="button" class="bad" data-a="delete">delete</button></div></li>`;
    }).join("")}</ul>` : `<p class="al-dim">No routes yet: nothing is sent anywhere.</p>`;
  }

  form(r) {
    const isNew = r === "new";
    const v = isNew ? { name: "", min_severity: "alert", apps: [], filter_id: null, quiet_from: null, quiet_to: null, dedup_minutes: this.dedup ?? 15, enabled: true } : r;
    const apps = this.api.apps?.() ?? [];
    return `<form class="al-form" onsubmit="return false" autocomplete="off">
      <h4>${isNew ? "A new route" : `Edit ${esc(v.name)}`}</h4>
      <label class="al-f">Name <input name="name" maxlength="80" required value="${esc(v.name)}" placeholder="ops channel"></label>
      <label class="al-f">Webhook URL <input name="url" spellcheck="false" placeholder="${isNew ? "https://hooks.slack.com/services/…" : `blank keeps ${esc(v.url_hint)}`}"></label>
      ${this.allowPrivate ? "" : `<p class="al-dim">Private, loopback and link-local addresses are refused (ALERT_ALLOW_PRIVATE_HOSTS=true allows them).</p>`}
      <div class="al-grid">
        <label class="al-f">Send <select name="min_severity"><option value="alert"${v.min_severity === "alert" ? " selected" : ""}>alerts</option><option value="warn"${v.min_severity === "warn" ? " selected" : ""}>alerts and warnings</option></select></label>
        <label class="al-f">Wire filter <select name="filter_id"><option value="">the whole wire</option>${this.sets().map((s) => `<option value="${s.id}"${s.id === v.filter_id ? " selected" : ""}>${esc(s.name)}</option>`).join("")}</select></label>
        <label class="al-f">Quiet from (UTC) <select name="quiet_from">${hours(v.quiet_from)}</select></label>
        <label class="al-f">to <select name="quiet_to">${hours(v.quiet_to)}</select></label>
        <label class="al-f">Same thing at most once per <span><input name="dedup_minutes" type="number" min="0" max="1440" value="${esc(v.dedup_minutes)}"> min</span></label>
        <label class="al-f al-chk"><span><input type="checkbox" name="on"${v.enabled ? " checked" : ""}> enabled</span></label>
      </div>
      <fieldset><legend>Only these apps <span class="al-dim">(none: the whole floor)</span></legend>${apps.map((a) => `<label><input type="checkbox" name="app" value="${esc(a.id)}"${v.apps.includes(a.id) ? " checked" : ""}> ${esc(a.label)}</label>`).join("") || `<span class="al-dim">no app on the floor yet</span>`}
        ${v.apps.filter((id) => !apps.some((a) => a.id === id)).map((id) => `<label><input type="checkbox" name="app" value="${esc(id)}" checked> ${esc(id)} <span class="al-dim">(not on the floor)</span></label>`).join("")}</fieldset>
      <div class="al-acts"><button type="button" class="go" data-a="save">${isNew ? "Add route" : "Save"}</button><button type="button" data-a="cancel">Cancel</button></div>
    </form>`;
  }

  values() {
    const f = this.el.querySelector(".al-form");
    const el = f.elements; // not f.name: that is the form's own name
    const int = (x) => x === "" ? null : +x;
    const p = {
      name: el.name.value, min_severity: el.min_severity.value, filter_id: int(el.filter_id.value),
      quiet_from: int(el.quiet_from.value), quiet_to: int(el.quiet_to.value), dedup_minutes: int(el.dedup_minutes.value),
      enabled: el.on.checked, apps: [...f.querySelectorAll("[name=app]:checked")].map((x) => x.value), url: el.url.value.trim(),
      by: this.api.who?.() ?? null,
    };
    if (this.editing !== "new") p.id = this.editing.id;
    return p;
  }

  say(text, bad = false) {
    const m = this.el.querySelector(".al-msg");
    if (!m) return;
    m.hidden = false; m.textContent = text; m.classList.toggle("bad", bad);
  }

  route(id) { return this.routes.find((r) => r.id === id); }

  // a toggle is a save of the route as it is, enabled or not
  setEnabled(id, on) {
    const r = this.route(id);
    if (!r) return;
    bus.push("alerts", "save_route", { ...this.asParams(r), enabled: on })
      .then(() => this.say(`${r.name} ${on ? "enabled" : "disabled"}`))
      .catch((x) => { this.say(x.message, true); this.renderList(); });
  }

  asParams(r) {
    return { id: r.id, name: r.name, min_severity: r.min_severity, apps: r.apps, filter_id: r.filter_id, quiet_from: r.quiet_from, quiet_to: r.quiet_to, dedup_minutes: r.dedup_minutes, enabled: r.enabled };
  }

  onClick(e) {
    const b = e.target.closest("[data-a]");
    if (!b) return;
    const a = b.dataset.a;
    const id = +(b.closest("[data-rid]")?.dataset.rid ?? NaN);
    if (a === "close") return this.toggle(false);
    if (a === "new") { this.editing = "new"; return this.render(); }
    if (a === "cancel") { this.editing = null; return this.render(); }
    if (a === "edit") { this.editing = this.route(id); return this.render(); }
    if (a === "save") {
      b.disabled = true;
      return bus.push("alerts", "save_route", this.values())
        .then((r) => { this.editing = null; this.render(); this.say(`saved ${r.route.name}: test it to see a message arrive`); })
        .catch((x) => this.say(x.message, true))
        .finally(() => { b.disabled = false; });
    }
    if (a === "test") {
      b.disabled = true; b.textContent = "sending…";
      return bus.push("alerts", "test_route", { id })
        .then(() => this.say(`${this.route(id)?.name}: the webhook took it`))
        .catch((x) => this.say(`${this.route(id)?.name}: ${x.message}`, true))
        .finally(() => { b.disabled = false; b.textContent = "test"; });
    }
    if (a === "delete") {
      const r = this.route(id);
      if (!r || !confirm(`Delete the route ${r.name}? Nothing more will be sent to it.`)) return;
      return bus.push("alerts", "delete_route", { id }).then(() => this.say(`deleted ${r.name}`)).catch((x) => this.say(x.message, true));
    }
  }
}
