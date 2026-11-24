// Writeups: a slice of the tape as a Markdown document (ObsFactor.Writeup),
// for people who are not on the floor. Opened on a stretch (a selection, a
// saved window, what Fires is reading, the last 24 hours), it shows:
//
//   left    the title, the stretch, which sections, a wire filter set,
//           which apps; the writeups shared so far (copy the link, revoke)
//   right   the document, as it will read
//
// and gives it away three ways: Download .md, Copy the Markdown, or Share,
// which keeps it on the observer under an unguessable link that works
// without a login until it is revoked.

import * as bus from "./bus.js";
import { esc } from "./fmt.js";

const SECTIONS = [["summary", "Summary"], ["incidents", "Incidents"], ["timeline", "Timeline"], ["hot", "Where it burned"], ["beam", "The BEAM"], ["errors", "Errors"], ["db", "Databases"], ["method", "How it was made"]];
const pad = (n) => String(n).padStart(2, "0");
const stamp = (ms) => { const d = new Date(ms); return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())} ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`; };

export class Writeups {
  constructor(api) {
    this.api = api; // { sets(), apps(), who(), label(id) }
    this.el = document.createElement("div");
    this.el.id = "writeup";
    this.el.hidden = true;
    this.el.setAttribute("role", "dialog");
    this.el.setAttribute("aria-label", "Write up a stretch of the tape");
    document.body.appendChild(this.el);
    this.shared = [];
    this.el.addEventListener("click", (e) => this.onClick(e));
    this.el.addEventListener("change", (e) => { if (e.target.closest(".wu-more")) this.renderEvery(); else this.refresh(); });
    this.el.addEventListener("input", (e) => { if (e.target.name === "title") { clearTimeout(this.tt); this.tt = setTimeout(() => this.refresh(), 500); } });
    document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !this.el.hidden) { e.preventDefault(); e.stopPropagation(); this.close(); } }, true);
    this.schedules = []; this.tokens = [];
    bus.subscribe("tape", (ev, p) => {
      if (ev === "writeups") { this.shared = p.writeups; this.renderShared(); }
      else if (ev === "schedules") { this.schedules = p.schedules; this.renderSchedules(); }
      else if (ev === "api_tokens") { this.tokens = p.tokens; this.renderTokens(); }
    }, {});
  }

  get open() { return !this.el.hidden; }

  // slice: {from, to, window?, title?}
  open(slice) {
    this.slice = slice;
    this.el.hidden = false;
    document.body.classList.add("writing");
    this.render();
    this.refresh();
    bus.push("tape", "writeups", {}).then((r) => { this.shared = r.writeups; this.renderShared(); }).catch(() => {});
    bus.push("tape", "schedules", {}).then((r) => { this.schedules = r.schedules; this.renderSchedules(); }).catch(() => {});
    bus.push("tape", "api_tokens", {}).then((r) => { this.tokens = r.tokens; this.renderTokens(); }).catch(() => {});
  }

  close() { this.el.hidden = true; document.body.classList.remove("writing"); }

  options() {
    const f = this.el.querySelector("form");
    const sections = [...f.querySelectorAll("[name=section]:checked")].map((x) => x.value);
    const apps = [...f.querySelectorAll("[name=app]:checked")].map((x) => x.value);
    const set = f.querySelector("[name=set]").value;
    const title = f.querySelector("[name=title]").value.trim();
    let o = this.slice.window ? { window: this.slice.window } : { from: Math.round(this.slice.from), to: Math.round(this.slice.to) };
    // the last N days instead of the stretch it was opened on (up to 92:
    // past the tape's 7, from hourly rollups), and a comparison (Rollups)
    const days = +(f.querySelector("[name=days]")?.value || 0);
    if (days) { const to = Date.now(); o = { from: to - days * 86400e3, to }; }
    const compare = f.querySelector("[name=compare]")?.value;
    return { ...o, sections, apps, ...(set ? { set: +set } : {}), ...(title ? { title } : {}), ...(compare ? { compare } : {}) };
  }

  render() {
    const s = this.slice;
    const sets = this.api.sets();
    const apps = this.api.apps();
    this.el.innerHTML = `<div class="wu-box">
      <form class="wu-opts" onsubmit="return false">
        <div class="wu-head"><h3>Write up</h3><button type="button" class="fi-x" data-a="close" aria-label="Close">×</button></div>
        <label class="wu-f">Title <input name="title" maxlength="120" value="${esc(s.title ?? "")}" placeholder="obs_factor: the stretch, in UTC"></label>
        <p class="wu-range">${s.window ? `window <b>${esc(s.title ?? `#${s.window}`)}</b><br>` : ""}${stamp(s.from)} – ${stamp(s.to)} UTC</p>
        <div class="wu-grid wu-rollups">
          <label class="wu-f">Stretch <select name="days"><option value="">as opened</option><option value="7">the last 7 days</option><option value="30">the last 30 days</option><option value="92">the last 92 days</option></select></label>
          <label class="wu-f">Compare with <select name="compare"><option value="">nothing</option><option value="week">the same period last week</option><option value="month">the same period last month</option></select></label>
        </div>
        <fieldset><legend>Sections</legend>${SECTIONS.map(([k, l]) => `<label><input type="checkbox" name="section" value="${k}" checked> ${l}</label>`).join("")}</fieldset>
        <label class="wu-f">Wire filter <select name="set"><option value="">the whole wire</option>${sets.map((x) => `<option value="${x.id}">${esc(x.name)}</option>`).join("")}</select></label>
        <fieldset><legend>Only these apps <span class="dim">(none: the whole floor)</span></legend>${apps.map((a) => `<label><input type="checkbox" name="app" value="${esc(a.id)}"> ${esc(a.label)}</label>`).join("") || `<span class="dim">no app on the floor</span>`}</fieldset>
        <div class="wu-acts">
          <button type="button" class="go" data-a="download">Download .md</button>
          <button type="button" data-a="copy">Copy Markdown</button>
          <button type="button" data-a="share" title="Keep it on the observer under an unguessable link anyone can read without logging in, until revoked">Share link</button>
        </div>
        <p class="wu-msg" hidden></p>
        <div class="wu-shared"></div>
        <details class="wu-more"><summary>Schedule this</summary>
          <p class="dim">Writes itself up every day or week with these options, saves it as a shared link, and posts the link to a webhook if you give one (Slack's incoming webhooks work).</p>
          <div class="wu-grid">
            <label class="wu-f">Name <input name="sname" maxlength="80" value="${esc(s.title || "Daily writeup")}"></label>
            <label class="wu-f">Every <select name="every"><option value="daily">day</option><option value="weekly">week</option></select></label>
            <label class="wu-f wu-wd">On <select name="weekday">${["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map((d, i) => `<option value="${i + 1}">${d}</option>`).join("")}</select></label>
            <label class="wu-f">At (UTC) <select name="hour">${Array.from({ length: 24 }, (_, h) => `<option value="${h}"${h === 8 ? " selected" : ""}>${String(h).padStart(2, "0")}:00</option>`).join("")}</select></label>
            <label class="wu-f wu-wide">Webhook <span class="dim">(optional)</span> <input name="webhook" placeholder="https://hooks.slack.com/services/…" spellcheck="false"></label>
          </div>
          <div class="wu-acts"><button type="button" data-a="schedule">Save schedule</button></div>
          <div class="wu-schedules"></div>
        </details>
        <details class="wu-more"><summary>Script access</summary>
          <p class="dim">A token lets a script fetch writeups without logging in. It is shown once.</p>
          <div class="wu-acts"><input name="tname" maxlength="60" placeholder="what will use it (e.g. nightly cron)"><button type="button" data-a="token">Make token</button></div>
          <div class="wu-newtoken" hidden></div>
          <div class="wu-tokens"></div>
        </details>
      </form>
      <article class="wu-doc" aria-live="polite"><p class="dim">writing…</p></article>
    </div>`;
    this.renderShared(); this.renderSchedules(); this.renderTokens(); this.renderEvery();
  }

  // the weekday only for a weekly schedule
  renderEvery() {
    const f = this.el.querySelector("form");
    const wd = this.el.querySelector(".wu-wd");
    if (f && wd) wd.hidden = f.every.value !== "weekly";
  }

  renderSchedules() {
    const box = this.el.querySelector(".wu-schedules");
    if (!box) return;
    const every = (x) => x.every === "daily" ? `daily at ${String(x.hour).padStart(2, "0")}:00` : `${["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][x.weekday - 1]}s at ${String(x.hour).padStart(2, "0")}:00`;
    box.innerHTML = this.schedules.length ? `<ul>${this.schedules.map((x) => `<li data-sid="${x.id}"><b>${esc(x.name)}</b><span class="dim">${every(x)} UTC · next ${stamp(x.next_at)}${x.webhook ? " · webhook" : ""}</span>
        ${x.last_run_at ? `<span class="dim">last ${stamp(x.last_run_at)}${x.last_slug ? ` · <a href="/w/${esc(x.last_slug)}.md" target="_blank" rel="noopener">read it</a>` : ""}</span>` : ""}
        ${x.last_error ? `<span class="bad">${esc(x.last_error)}</span>` : ""}
        <span class="wu-l"><button type="button" data-a="runnow">run now</button><button type="button" class="bad" data-a="unschedule">delete</button></span></li>`).join("")}</ul>` : "";
  }

  renderTokens() {
    const box = this.el.querySelector(".wu-tokens");
    if (!box) return;
    box.innerHTML = this.tokens.length ? `<ul>${this.tokens.map((t) => `<li data-tid="${t.id}"><b>${esc(t.name)}</b><span class="dim">${esc(t.hint)} · ${t.last_used_at ? `used ${stamp(t.last_used_at)}` : "never used"}${t.by ? ` · ${esc(t.by)}` : ""}</span>
        <span class="wu-l"><button type="button" class="bad" data-a="revoketoken">revoke</button></span></li>`).join("")}</ul>` : "";
  }

  // what a script would send for the options on screen
  curl(token) {
    const o = this.options();
    const q = new URLSearchParams();
    for (const [k, v] of Object.entries(o)) q.set(k, Array.isArray(v) ? v.join(",") : String(v));
    return `curl -fsS -H "Authorization: Bearer ${token}" "${location.origin}/api/writeup.md?${q}" -o writeup.md`;
  }

  renderShared() {
    const box = this.el.querySelector(".wu-shared");
    if (!box) return;
    box.innerHTML = this.shared.length
      ? `<h4>Shared writeups <span class="dim">· readable by anyone with the link</span></h4><ul>${this.shared.slice(0, 20).map((w) => `<li data-slug="${esc(w.slug)}"><b>${esc(w.title)}</b><span class="dim">${stamp(w.created_at)}${w.by ? ` · ${esc(w.by)}` : ""}</span>
          <span class="wu-l"><button type="button" data-a="copylink" data-url="${esc(w.url)}">copy link</button><a href="${esc(w.url)}" target="_blank" rel="noopener">open</a><button type="button" class="bad" data-a="revoke">revoke</button></span></li>`).join("")}</ul>`
      : "";
  }

  refresh() {
    if (!this.open) return;
    const ask = this.options();
    this.asked = ask;
    bus.push("tape", "writeup", ask)
      .then((r) => { if (this.asked !== ask) return; this.doc = r; this.el.querySelector(".wu-doc").innerHTML = markdown(r.markdown); })
      .catch((e) => { this.el.querySelector(".wu-doc").innerHTML = `<p class="fi-err">${esc(e.message)}</p>`; });
  }

  say(text, bad = false) {
    const m = this.el.querySelector(".wu-msg");
    m.hidden = false; m.textContent = text; m.classList.toggle("bad", bad);
  }

  onClick(e) {
    if (e.target === this.el) return this.close();
    const b = e.target.closest("[data-a]");
    if (!b) return;
    const a = b.dataset.a;
    if (a === "close") return this.close();
    if (a === "download") {
      if (!this.doc) return;
      const blob = new Blob([this.doc.markdown], { type: "text/markdown" });
      const link = document.createElement("a");
      link.href = URL.createObjectURL(blob);
      link.download = `${this.doc.title.replace(/[^\w.-]+/g, "-").replace(/^-|-$/g, "").slice(0, 80)}.md`;
      link.click();
      setTimeout(() => URL.revokeObjectURL(link.href), 1000);
      return this.say("downloaded");
    }
    if (a === "copy") return this.doc && copy(this.doc.markdown).then(() => this.say("Markdown copied"), () => this.say("the browser would not copy", true));
    if (a === "share") {
      b.disabled = true;
      return bus.push("tape", "save_writeup", { ...this.options(), by: this.api.who() })
        .then((r) => copy(r.writeup.url).then(() => this.say(`shared: ${r.writeup.url} (copied)`), () => this.say(`shared: ${r.writeup.url}`)))
        .catch((x) => this.say(x.message, true))
        .finally(() => { b.disabled = false; });
    }
    if (a === "schedule") {
      const f = this.el.querySelector("form");
      const o = this.options();
      const body = { name: f.sname.value, every: f.every.value, hour: +f.hour.value, weekday: f.every.value === "weekly" ? +f.weekday.value : null,
        webhook: f.webhook.value.trim() || null, options: { apps: o.apps, sections: o.sections, ...(o.set ? { set: o.set } : {}) }, by: this.api.who() };
      return bus.push("tape", "save_schedule", body).then((r) => this.say(`scheduled “${r.schedule.name}”: next ${stamp(r.schedule.next_at)} UTC`)).catch((x) => this.say(x.message, true));
    }
    if (a === "runnow") {
      const id = +b.closest("[data-sid]").dataset.sid;
      b.disabled = true;
      return bus.push("tape", "run_schedule", { id }).then((r) => this.say(`written: ${location.origin}/w/${r.writeup.slug}.md`)).catch((x) => this.say(x.message, true)).finally(() => { b.disabled = false; });
    }
    if (a === "unschedule") {
      const id = +b.closest("[data-sid]").dataset.sid;
      if (!window.confirm("Delete this schedule? Writeups it already wrote stay shared.")) return;
      return bus.push("tape", "delete_schedule", { id }).then(() => this.say("schedule deleted")).catch((x) => this.say(x.message, true));
    }
    if (a === "token") {
      const name = this.el.querySelector("[name=tname]").value;
      return bus.push("tape", "create_token", { name, by: this.api.who() }).then((r) => {
        const box = this.el.querySelector(".wu-newtoken");
        box.hidden = false;
        const c = this.curl(r.token.token);
        box.innerHTML = `<p><b>${esc(r.token.name)}</b>: copy it now, it is not shown again.</p><code>${esc(r.token.token)}</code>
          <p class="dim">For these options:</p><code>${esc(c)}</code>
          <div class="wu-acts"><button type="button" data-a="copytoken" data-v="${esc(r.token.token)}">copy token</button><button type="button" data-a="copytoken" data-v="${esc(c)}">copy curl</button></div>`;
      }).catch((x) => this.say(x.message, true));
    }
    if (a === "copytoken") return copy(b.dataset.v).then(() => this.say("copied"), () => this.say("the browser would not copy", true));
    if (a === "revoketoken") {
      const id = +b.closest("[data-tid]").dataset.tid;
      if (!window.confirm("Revoke this token? Scripts using it get 401 from now on.")) return;
      return bus.push("tape", "revoke_token", { id }).then(() => this.say("token revoked")).catch((x) => this.say(x.message, true));
    }
    if (a === "copylink") return copy(b.dataset.url).then(() => this.say("link copied"), () => this.say(b.dataset.url));
    if (a === "revoke") {
      const slug = b.closest("[data-slug]").dataset.slug;
      if (!window.confirm("Revoke this writeup? Its link stops working for everyone.")) return;
      return bus.push("tape", "delete_writeup", { slug }).then(() => this.say("revoked")).catch((x) => this.say(x.message, true));
    }
  }
}

function copy(text) { return navigator.clipboard ? navigator.clipboard.writeText(text) : Promise.reject(new Error("no clipboard")); }

// Just enough Markdown for what ObsFactor.Writeup writes: headings, tables,
// lists, quotes, paragraphs, **bold**, _italic_, [links](url). Everything
// is escaped first; only the server's own markup becomes HTML, and links
// must be http(s).
export function markdown(md) {
  // the server writes "<" as &lt; for other renderers; it is escaped here anyway
  const inline = (t) => esc(t.replace(/&lt;/g, "<"))
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|\W)_([^_]+)_(?=\W|$)/g, "$1<em>$2</em>")
    .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, (m, txt, url) => `<a href="${url}" target="_blank" rel="noopener">${txt}</a>`);
  const out = [];
  const lines = md.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (/^#{1,4} /.test(l)) { const n = l.match(/^#+/)[0].length; out.push(`<h${n}>${inline(l.slice(n + 1))}</h${n}>`); continue; }
    if (l.startsWith("|")) {
      const rows = [];
      while (i < lines.length && lines[i].startsWith("|")) rows.push(lines[i++]);
      i--;
      const cells = (r) => r.slice(1, -1).split(/(?<!\\)\|/).map((c) => c.trim().replace(/\\\|/g, "|"));
      const [head, , ...body] = rows;
      out.push(`<table><thead><tr>${cells(head).map((c) => `<th>${inline(c)}</th>`).join("")}</tr></thead><tbody>${body.map((r) => `<tr>${cells(r).map((c) => `<td>${inline(c)}</td>`).join("")}</tr>`).join("")}</tbody></table>`);
      continue;
    }
    if (l.startsWith("- ")) {
      const items = [];
      while (i < lines.length && lines[i].startsWith("- ")) items.push(lines[i++].slice(2));
      i--;
      out.push(`<ul>${items.map((x) => `<li>${inline(x)}</li>`).join("")}</ul>`);
      continue;
    }
    if (l.startsWith("> ")) { out.push(`<blockquote>${inline(l.slice(2))}</blockquote>`); continue; }
    if (l.trim()) out.push(`<p>${inline(l)}</p>`);
  }
  return out.join("");
}
