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
    this.el.addEventListener("change", () => this.refresh());
    this.el.addEventListener("input", (e) => { if (e.target.name === "title") { clearTimeout(this.tt); this.tt = setTimeout(() => this.refresh(), 500); } });
    document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !this.el.hidden) { e.preventDefault(); e.stopPropagation(); this.close(); } }, true);
    bus.subscribe("tape", (ev, p) => { if (ev === "writeups") { this.shared = p.writeups; this.renderShared(); } }, {});
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
  }

  close() { this.el.hidden = true; document.body.classList.remove("writing"); }

  options() {
    const f = this.el.querySelector("form");
    const sections = [...f.querySelectorAll("[name=section]:checked")].map((x) => x.value);
    const apps = [...f.querySelectorAll("[name=app]:checked")].map((x) => x.value);
    const set = f.querySelector("[name=set]").value;
    const title = f.querySelector("[name=title]").value.trim();
    const o = this.slice.window ? { window: this.slice.window } : { from: Math.round(this.slice.from), to: Math.round(this.slice.to) };
    return { ...o, sections, apps, ...(set ? { set: +set } : {}), ...(title ? { title } : {}) };
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
      </form>
      <article class="wu-doc" aria-live="polite"><p class="dim">writing…</p></article>
    </div>`;
    this.renderShared();
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
