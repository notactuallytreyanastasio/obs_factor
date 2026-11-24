// Connect an app (ObsFactor.Connect, docs/CONNECT.md). The form on the left
// (app, service, kind, and what the floor should know: label, hosts,
// databases); on the right what to paste where, in order, and a checklist
// of what the observer sees of the app now, asked again every 5 s while
// the panel is open:
//
//   container  Docker lists a running container of the compose service
//   floor      it is a node with a report URL (its labels, or the topology)
//   report     the reports collector read it
//   observer   its observer engine answers through the pass-through
//   actions    OBSERVER_ACTIONS_TOKEN is set here
//
// Nothing is stored: the form is the query string of GET /api/connect.

import { esc } from "./fmt.js";

const FIELDS = [
  ["app", "OTP app", "ledger", "the atom in mix.exs, my_app"],
  ["service", "Compose service", "", "defaults to the app with - for _"],
  ["label", "Building's name", "", "optional"],
  ["hosts", "Caddy hosts", "", "comma separated, optional"],
  ["databases", "Databases", "", "comma separated, optional"],
  ["probe_port", "HTTP port to probe", "", "optional, e.g. 4000"],
  ["app_dir", "App checkout", "", "for install.sh; default ../<app>"],
];

const MARK = { ok: "✓", wait: "…", bad: "✕" };

export class Connect {
  constructor() {
    this.el = document.createElement("div");
    this.el.id = "connect";
    this.el.hidden = true;
    this.el.setAttribute("role", "dialog");
    this.el.setAttribute("aria-label", "Connect an app");
    document.body.appendChild(this.el);
    this.el.innerHTML = this.shell();
    this.form = this.el.querySelector("form");
    this.el.addEventListener("click", (e) => this.onClick(e));
    this.form.addEventListener("input", () => { clearTimeout(this.t); this.t = setTimeout(() => this.refresh(), 400); });
    this.form.addEventListener("change", () => this.refresh());
    document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !this.el.hidden) { e.preventDefault(); e.stopPropagation(); this.close(); } }, true);
  }

  get open() { return !this.el.hidden; }

  toggle(on = this.el.hidden) { on ? this.show() : this.close(); }

  show() {
    this.el.hidden = false;
    this.refresh();
    clearInterval(this.poll);
    this.poll = setInterval(() => { if (!document.hidden) this.refresh(); }, 5000);
  }

  close() { this.el.hidden = true; clearInterval(this.poll); }

  shell() {
    return `<div class="cn-box">
      <form class="cn-form" onsubmit="return false" autocomplete="off">
        <div class="cn-head"><h3>Connect an app</h3><button type="button" class="cn-x" data-a="close" aria-label="Close">×</button></div>
        <p class="cn-lead">An Elixir app on the box reports to the floor with one library and a few compose labels. No topology edit, no observer restart.</p>
        ${FIELDS.map(([k, l, v, hint]) => `<label class="cn-f">${l}<input name="${k}" value="${esc(v)}" spellcheck="false" placeholder="${esc(hint)}"></label>`).join("")}
        <fieldset><legend>Kind</legend>
          <label><input type="radio" name="kind" value="phoenix" checked> Phoenix</label>
          <label><input type="radio" name="kind" value="elixir"> Elixir, no Phoenix</label>
        </fieldset>
        <p class="cn-err" hidden></p>
      </form>
      <div class="cn-out">
        <section class="cn-check"><h4>What the observer sees</h4><ol></ol></section>
        <section class="cn-steps"></section>
      </div>
    </div>`;
  }

  query() {
    const p = new URLSearchParams();
    for (const [k, v] of new FormData(this.form)) if (String(v).trim() !== "") p.set(k, String(v).trim());
    return p;
  }

  async refresh() {
    const q = this.query();
    const key = q.toString();
    let body, status;
    try {
      const r = await fetch(`/api/connect?${key}`, { headers: { accept: "application/json" } });
      status = r.status;
      body = await r.json();
    } catch (e) {
      body = { error: `the observer did not answer: ${e.message}` };
    }
    if (key !== this.query().toString()) return; // the form moved on meanwhile
    const err = this.el.querySelector(".cn-err");
    if (status !== 200) {
      err.hidden = false;
      err.textContent = body?.error ?? `answered ${status}`;
      return;
    }
    err.hidden = true;
    this.renderChecklist(body.checklist);
    if (key !== this.lastKey) { this.lastKey = key; this.renderSteps(body.snippets); }
  }

  renderChecklist(items) {
    this.el.querySelector(".cn-check ol").innerHTML = items.map((c) =>
      `<li class="cn-${c.state}" data-id="${esc(c.id)}"><span class="cn-mark" aria-label="${esc(c.state)}">${MARK[c.state] ?? "?"}</span><span><b>${esc(c.title)}</b><span class="cn-detail">${esc(c.detail)}</span></span></li>`).join("");
  }

  renderSteps(snippets) {
    this.snippets = snippets;
    this.el.querySelector(".cn-steps").innerHTML = snippets.map((s, n) => `<article>
        <header><span class="cn-n">${n + 1}</span><b>${esc(s.title)}</b>${s.file ? `<code class="cn-file">${esc(s.file)}</code>` : ""}<button type="button" data-a="copy" data-i="${n}">Copy</button></header>
        <pre>${esc(s.text)}</pre>
        <p>${esc(s.note)}</p>
      </article>`).join("");
  }

  onClick(e) {
    const b = e.target.closest("[data-a]");
    if (e.target === this.el) return this.close();
    if (!b) return;
    if (b.dataset.a === "close") this.close();
    if (b.dataset.a === "copy") {
      const s = this.snippets?.[+b.dataset.i];
      if (!s) return;
      navigator.clipboard?.writeText(s.text).then(() => { b.textContent = "Copied"; setTimeout(() => { b.textContent = "Copy"; }, 1200); }, () => { b.textContent = "Copy failed"; });
    }
  }
}
