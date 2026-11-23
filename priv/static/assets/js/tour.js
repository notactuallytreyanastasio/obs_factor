// The guided tour: a spotlight and a card that walk the real page, from the
// factory floor down to the BEAM processes that read the numbers and their
// log. It drives the page the way a person would (opens the legend, selects
// a building, opens "Under the hood"), and every number it quotes is read
// from the live snapshot or the beam feed at that step. A stop whose subject is
// not on this box (no failing source, no built app) is skipped, not faked.
//
// Start: the Tour button, or ?tour in the URL. Keys: → / Enter next,
// ← back, Esc ends.

import { num, esc, utc, duration } from "./fmt.js";
import { headlineText } from "./overlay.js";

const $ = (id) => document.getElementById(id);
const q = (sel) => document.querySelector(sel);

function waitFor(fn, ms = 3000) {
  return new Promise((resolve) => {
    const t0 = performance.now();
    const tick = () => {
      const v = fn();
      if (v || performance.now() - t0 > ms) return resolve(v || null);
      setTimeout(tick, 60);
    };
    tick();
  });
}

const kinds = (snap, k) => snap.nodes.filter((n) => n.kind === k);
const failing = (snap) => Object.entries(snap.sources).filter(([, s]) => !s.ok);
const label = (snap, id) => snap.nodes.find((n) => n.id === id)?.label ?? id;
const code = (s) => `<code>${esc(s)}</code>`;

// The building a stop is about, picked from what is on the floor now.
const pick = {
  proxy: (s) => kinds(s, "proxy")[0],
  probed: (s) => {
    const p = s.nodes.filter((n) => n.probe && n.container);
    return p.find((n) => !n.probe.ok) ?? p.find((n) => n.probe.ok) ?? null;
  },
  built: (s) => s.nodes.find((n) => n.build && n.build.mode === "github" && n.build.status === "live") ?? s.nodes.find((n) => n.build) ?? null,
};

function steps(api) {
  return [
    {
      title: "This is the box, as a factory",
      body: (s) => `Every building is a service, every platform is where services run, and the belts between them move requests.
        Nothing on this page is made up. If a number can't be read, it shows as <b>unknown</b> in grey and the page says which source failed.
        <p>This tour drives the real page: ${s.nodes.length} buildings on ${s.platforms.length} platforms right now. It goes from what you see down to the Erlang processes that read the numbers, and their logs.</p>`,
      enter: async () => { api.closeAll(); api.fitAll(); },
    },
    {
      title: "Live, not polled by your browser",
      target: () => $("clock"),
      body: (s) => `The observer builds one snapshot every ${s.tick_ms / 1000} s and broadcasts it on Phoenix PubSub, topic ${code("snapshots")}; this page receives it on its one websocket (${code("/socket")}), the same socket every other live thing here arrives on. Nothing is fetched on a timer.
        This one was built at <b>${esc(utc(new Date(s.at)))}</b> UTC. If snapshots stop arriving, the dot goes red and says how stale the page is, so a frozen screen can't pass for a quiet one.`,
    },
    {
      title: "What's coming in",
      target: () => q(".inrate"),
      body: (s) => {
        const p = pick.proxy(s);
        return `Requests per second into Caddy across every hostname, from Caddy's own Prometheus metrics: <b>${esc(q("#inrate").textContent)}</b> right now.
          ${p ? `It's the same number Caddy's building shows (${esc(headlineText(p.headline))}).` : ""}`;
      },
    },
    {
      title: "Needs attention",
      skip: (s) => s.attention.length + failing(s).length === 0,
      target: () => $("attention"),
      body: (s) => {
        const n = s.attention.length + failing(s).length;
        const first = s.attention[0]?.text ?? (failing(s)[0] ? `source ${failing(s)[0][0]} failing` : "");
        return `${n} thing${n === 1 ? "" : "s"} the page thinks you should look at, worst first. Right now: <b>${esc(first)}</b>.
          Each item is a button: a building's item flies you to it, and a failing source opens the list of sources.`;
      },
    },
    {
      // missions.js; skipped when the observer has no objectives store (OBJECTIVES_PG_URL unset)
      title: "Missions: what to check before you leave",
      skip: () => api.missions.configured !== true,
      target: () => $("missions"),
      enter: async () => { api.closeAll(); api.missions.toggle(true); await waitFor(() => api.missions.loaded, 3000); },
      body: () => {
        const M = api.missions;
        const u = M.list.filter((o) => o.state !== "done");
        const cleared = u.filter((o) => o.state === "cleared").length;
        const pins = u.filter((o) => o.source === "pin").length;
        return `The strip above forgets: it is recomputed every tick. This doesn't. Every alert and warning becomes an objective in Postgres (${code("ObsFactor.Objectives")}, ${code("GET /api/objectives")}), kept until a person crosses it off with a note.
          ${M.error ? `<p class="note err">The store is failing right now, and the panel says so: ${esc(M.error)}</p>` : ""}
          <p>${M.loaded ? "Right now" : "Nothing read yet"}: <b>${u.length}</b> undone${cleared ? `, ${cleared} of them cleared by themselves and not yet checked` : ""}${pins ? `, ${pins} flagged by hand` : ""}.</p>
          ${code("I'm on it")} tells everyone you are looking; ${code("f")} on a selected building flags it; ${code("l")} is the issues lens, the floor veiled except what is on the list. ${code("Before you leave")} writes the handover.`;
      },
    },
    {
      title: "Reading the lamps",
      target: () => q("#legend .lg-grid"),
      enter: async () => api.panel("legend", true),
      body: () => `Every building has a lamp. <b>Working</b> means it's doing something now (requests, CPU). <b>Idle</b> means up and quiet. <b>Blocked</b> means up but stuck on something it needs.
        <b>Down</b> means it's failing its probe or not running. The dashed grey <b>unknown</b> is the important one: it means the source that would tell us is broken, so the page won't guess.`,
    },
    {
      title: "Where every number comes from",
      target: () => $("sources"),
      enter: async () => api.panel("legend", true),
      body: (s) => {
        const names = Object.keys(s.sources);
        const bad = failing(s);
        return `${names.length} sources: ${names.map(code).join(" ")}. Each one is read every ${s.tick_ms / 1000} s by its own process on the server.
          ${bad.length ? `<p><b>${bad.length} failing</b>: ${bad.map(([n, x]) => `${code(n)} ${esc(x.error ?? "")}`).join("; ")}. Everything that depends on ${bad.length === 1 ? "it" : "them"} is grey, not zero.</p>` : "<p>All ok right now.</p>"}
          Keep these names in mind; we'll meet the processes at the end of the tour.`;
      },
    },
    {
      title: "The front door",
      skip: (s) => !pick.proxy(s),
      target: (s) => api.nodeRect(pick.proxy(s).id),
      enter: async (s) => { api.closeAll(); api.centreOn(pick.proxy(s).id); await waitFor(() => false, 700); },
      body: (s) => {
        const p = pick.proxy(s);
        return `<b>${esc(p.label)}</b>. Every request comes in through it, and the belts leaving it go to the apps behind each hostname. A belt's speed is its request rate on a log scale; a dashed belt is a route Caddy doesn't count separately.
          Headline: <b>${esc(headlineText(p.headline))}</b>.`;
      },
    },
    {
      title: "The inspector",
      skip: (s) => !pick.proxy(s),
      target: () => q("#inspector .ins-head"),
      enter: async (s) => { api.select(pick.proxy(s).id); await waitFor(() => q("#inspector .ins-head")); },
      body: (s) => {
        const p = s.nodes.find((n) => n.id === pick.proxy(s).id);
        return `Clicking a building opens this. Status <b>${esc(p.status)}</b>${p.reason ? `, because ${esc(p.reason)}` : ""}.
          The status isn't hand-set: rules in ${code("ObsFactor.Rules")} derive it from the probe, the container's state and its traffic.`;
      },
    },
    {
      title: "Per hostname",
      skip: (s) => !pick.proxy(s)?.hosts?.length,
      target: () => q("#inspector table.hosts"),
      body: (s) => {
        const p = s.nodes.find((n) => n.id === pick.proxy(s).id);
        const top = [...(p.hosts ?? [])].sort((a, b) => (b.rps ?? -1) - (a.rps ?? -1))[0];
        return `Caddy reports each hostname as its own series: requests, errors and average latency.
          ${!top ? "" : top.rps === 0 ? "Nothing is coming in right now, so every row reads 0: a measured zero, not an unknown." : `The busiest right now is <b>${esc(top.host)}</b> at ${top.rps == null ? "unknown" : esc(num(top.rps))} req/s.`}`;
      },
    },
    {
      title: "History",
      target: () => q("#inspector .hist"),
      enter: async () => { await waitFor(() => q("#inspector .hist .chart") || q("#inspector .hist .note.err"), 4000); q("#inspector .hist")?.scrollIntoView({ block: "nearest" }); },
      body: () => `The last hour at 5 s resolution, or 24 h at 1 minute, from ${code("GET /api/history")}. The observer keeps it in memory, so a restart starts the history over.
        A hatched floor under a chart is a gap: the value was unknown then, so the line breaks there instead of drawing zero. Hover a chart to read any moment.`,
    },
    {
      title: "Asking an app if it's alive",
      skip: (s) => !pick.probed(s),
      target: () => q("#inspector .probe")?.closest(".sec"),
      enter: async (s) => { api.select(pick.probed(s).id, true); await waitFor(() => q("#inspector .probe")); q("#inspector .probe")?.scrollIntoView({ block: "center" }); },
      body: (s) => {
        const n = pick.probed(s);
        const p = n.probe;
        return `<b>${esc(n.label)}</b>: the probe collector sends an HTTP GET to its health URL from inside the stack's network, every tick.
          Last answer: ${p.ok ? "<b>OK</b>" : "<b>FAIL</b>"}, ${p.code == null ? "no answer" : `HTTP ${esc(p.code)}`}${p.ms != null ? ` in ${esc(p.ms)} ms` : ""}${p.error ? `, ${esc(p.error)}` : ""}.`;
      },
    },
    {
      title: "The container under it",
      skip: (s) => !pick.probed(s),
      target: () => [...document.querySelectorAll("#inspector .sec h3")].find((h) => h.textContent === "Container")?.parentElement,
      enter: async () => [...document.querySelectorAll("#inspector .sec h3")].find((h) => h.textContent === "Container")?.scrollIntoView({ block: "center" }),
      body: (s) => {
        const c = pick.probed(s).container;
        return `State, restarts, OOM kills, CPU, memory and network come from the Docker API, through ${code("docker-proxy")}: a proxy that allows three read-only GET endpoints and refuses everything else, so the observer can't change the box.
          ${c ? `This one: <b>${esc(c.status_text ?? c.state)}</b>, ${esc(c.restarts ?? "?")} restarts.` : ""}`;
      },
    },
    {
      title: "Every address",
      target: () => $("sites"),
      enter: async () => { api.closeInspector(); api.panel("sites", true); },
      body: () => `Every hostname and path route Caddy serves, the service behind it and its live rate. Click an address to fly to its building. A path route shows <b>via</b> because Caddy counts it under the hostname it lives on.`,
    },
    {
      title: "Real logs, part 1: a build",
      skip: (s) => !pick.built(s),
      target: () => q("#inspector .buildlog pre") ?? q("#inspector .sec.build"),
      enter: async (s) => {
        api.panel("sites", false);
        api.select(pick.built(s).id, true);
        await waitFor(() => q("#inspector .buildlog pre"), 4000);
        q("#inspector .buildlog")?.scrollIntoView({ block: "center" });
      },
      body: (s) => {
        const n = pick.built(s);
        return `<b>${esc(n.label)}</b> was built here: an A record, a Caddy route, a git clone of ${esc((n.build.repo ?? "").replace("https://github.com/", ""))}, an agent that read its README and wrote the build plan, ${code("docker build")}, then a health check through Caddy.
          This is that job's real log from the builder (${code(`GET /api/builds/${n.build.id}`)}), every line as it was written, including what the agent read and how many tokens it used.`;
      },
    },
    {
      title: "Under the hood",
      target: () => q("#beam .bm-vm"),
      enter: async () => { api.closeAll(); api.beam.toggle(true); await waitFor(() => q("#beam .bm-tiles")); },
      body: () => {
        const v = api.beam.data?.vm;
        return v ? `Below the factory: the observer is an Elixir app, and this is its own VM, read live from the ${code("observer:observer:-:beam")} feed on the page's socket.
          <b>OTP ${esc(v.otp)}</b> on ${esc(v.schedulers)} schedulers, up ${esc(duration(v.uptime_s))}, running <b>${esc(num(v.process_count))}</b> lightweight processes in ${esc(Math.round(v.memory.total / 1048576))} MB of memory.
          A run queue above 0 for long means the schedulers can't keep up.` : `The beam feed didn't answer: ${esc(api.beam.error ?? "no data")}.`;
      },
    },
    {
      title: "One process per source",
      target: () => q("#beam tr[data-source='docker']") ?? q("#beam .bm-procs"),
      enter: async () => q("#beam tr[data-source='docker']")?.scrollIntoView({ block: "center" }),
      body: () => {
        const p = api.beam.data?.processes.find((x) => x.source?.name === "docker");
        const n = api.beam.data?.processes.filter((x) => x.source).length ?? 0;
        return `The sources from the legend are these rows: ${n} ${code("ObsFactor.Collector")} GenServers under one supervisor. Each wakes every tick, runs its read in a task with a deadline, and writes the result to an ETS table. A collector that hangs times out; one that crashes is restarted alone.
          ${p ? `<p>The Docker collector is ${code(p.pid)}: ${esc(p.message_queue_len)} messages in its mailbox, ${esc(Math.round(p.memory_bytes / 1024))} KB, last polled ${esc((p.source.attempted_ms_ago / 1000).toFixed(1))} s ago. Reductions per second is how much work a process does; a collector's own count stays small because each read runs in a short-lived task under ${code("TaskSupervisor")}.</p>` : ""}`;
      },
    },
    {
      title: "Where the grey comes from",
      // the snapshot's sources are the collectors' rows: same failure, known up front
      skip: (s) => failing(s).length === 0,
      target: () => q("#beam tr[data-source] .src.bad")?.closest("tr"),
      enter: async () => q("#beam tr[data-source] .src.bad")?.scrollIntoView({ block: "center" }),
      body: () => {
        const p = api.beam.data?.processes.find((x) => x.source && !x.source.ok);
        if (!p) return `The failing source recovered between the snapshot and this read of the VM: every collector's last poll is ok now.`;
        return `${code(p.id)} is alive but its last read failed: <b>${esc(p.source.error)}</b>. That error is the same one the legend showed, and it's why the buildings that depend on ${code(p.source.name)} are unknown rather than zero.
          The process is fine; the thing it reads isn't.`;
      },
    },
    {
      title: "The tables a snapshot is built from",
      target: () => q("#beam .bm-tables"),
      enter: async () => q("#beam .bm-tables")?.scrollIntoView({ block: "center" }),
      body: () => {
        const src = api.beam.data?.tables.find((t) => t.name === "Sources");
        return `${src ? `${code("Sources")} holds ${esc(src.size)} rows, one per source.` : ""} Every tick, ${code("ObsFactor.Ticker")} reads them all, builds the snapshot once and encodes it once into ${code("Store")}. Every open page gets the same bytes, so ten viewers cost about what one does.
          A collector's row older than three ticks is served as "stuck or dead", never as current.`;
      },
    },
    {
      title: "Real logs, part 2: the observer's own",
      target: () => q("#beam .bm-log"),
      enter: async () => { api.beam.setFilter("source"); q("#beam .bm-log")?.scrollIntoView({ block: "center" }); },
      body: () => {
        const lines = (api.beam.data?.log ?? []).filter((l) => l.text.startsWith("source "));
        const last = lines[lines.length - 1];
        return `Its Logger output, the last 2000 events held in memory by a ${code(":logger")} handler (${code("ObsFactor.LogRing")}), filtered here to the collectors. They only log when something changes (ok to failing, failing to ok, a new error), so this reads as a history of what broke and when.
          ${last ? `<p>Latest: <b>${esc(utc(new Date(last.at)))}</b> ${code(last.text)}</p>` : "<p>No collector has changed state since the log ring started.</p>"}
          Clear the filter to see everything, or click the log to search it. The full stream, including boot, is in ${code("docker logs")} for the observer's container.`;
      },
    },
    {
      title: "The same VM, as buildings",
      target: () => q("#apps-info"),
      enter: async () => { api.apps.enterObserver(); await waitFor(() => api.snap()?.apps?.drawn?.length, 5000); },
      body: (s) => {
        const i = s.apps;
        if (!i?.drawn?.length) return `The applications feed didn't answer in 5 s. The line at the bottom of the floor says why, when it knows.`;
        const topics = api.apps.apps.topics();
        return `${code("Applications floor")} in Under the hood turns the observer's own VM into a floor: <b>${esc(i.drawn.length)}</b> of its ${esc(i.count ?? "?")} OTP applications have processes, and each is a platform of its supervision tree. Every building is a process; height is its memory.
          <p>The page joined ${esc(topics.length)} topics for this, ${code(topics[0] ?? "observer:observer:-:apps")} and one ${code("tree:<app>")} per application. On the server one feed process reads each topic every 2 s, however many browsers watch, and stops 10 s after the last one leaves. Click a building to open its process; Kill, GC and Restart are pushed on the same socket, and everyone watching sees the result on ${code("actions")}.</p>
          Any building with a ${code("factory_report")} engine has the same floor: go in, then Applications.`;
      },
    },
    {
      title: "Search every log",
      target: () => q("#logx .lx"),
      enter: async () => {
        api.beam.toggle(false);
        await api.logs.open({});
        await waitFor(() => api.logs.events.length, 4000);
      },
      body: () => {
        const L = api.logs;
        const lv = new Set(L.events.map((e) => e.level));
        return `Click any log on the page and it opens here: the observer's ${L.events.filter((e) => e.service === "observer").length} lines and ${L.builds.size} build${L.builds.size === 1 ? "" : "s"}' logs, one list, tailed live.
          Search like Datadog: ${code("level:warning")}, ${code("-source:docker")}, ${code('"host not found"')}, ${code("job:deci-*")}, ${code("level:(warning OR error)")}.
          The facets on the left count what each value would give you${lv.size ? ` (levels here: ${[...lv].map(code).join(" ")})` : ""}; drag across the histogram to zoom in on a moment, and click a line for its attributes, each one a filter.`;
      },
    },
    {
      title: "That's the whole stack",
      body: () => `From a lamp on a building, to the rule that set it, to the source it came from, to the process that read it, to that process's log line. When something looks wrong upstairs, the same path works backwards.
        <p>Restart the tour with the <b>Tour</b> button, or open the page with ${code("?tour")}.</p>`,
      enter: async () => { api.beam.setFilter(""); api.closeAll(); },
    },
  ];
}

export class Tour {
  constructor(api) {
    this.api = api;
    this.steps = steps(api);
    this.i = -1;
    this.root = document.createElement("div");
    this.root.id = "tour";
    this.root.hidden = true;
    this.root.innerHTML = `<div class="tour-spot"></div><div class="tour-card" role="dialog" aria-live="polite" aria-labelledby="tour-title">
      <div class="tour-meta"><span class="tour-n"></span><button type="button" class="tour-end">End tour</button></div>
      <h3 id="tour-title"></h3><div class="tour-body"></div>
      <div class="tour-nav"><button type="button" class="tour-back">Back</button><span class="tour-dots"></span><button type="button" class="tour-next">Next</button></div></div>`;
    document.body.appendChild(this.root);
    this.spot = this.root.querySelector(".tour-spot");
    this.card = this.root.querySelector(".tour-card");
    this.root.querySelector(".tour-end").addEventListener("click", () => this.stop());
    this.root.querySelector(".tour-back").addEventListener("click", () => this.move(-1));
    this.root.querySelector(".tour-next").addEventListener("click", () => this.move(1));
    window.addEventListener("keydown", (e) => {
      if (this.i < 0) return;
      if (e.key === "ArrowRight" || (e.key === "Enter" && !e.target.closest("input, select, textarea"))) { e.preventDefault(); this.move(1); }
      else if (e.key === "ArrowLeft") { e.preventDefault(); this.move(-1); }
      else if (e.key === "Escape") this.stop();
    });
    this.raf = null;
    this.busy = false;
  }

  get active() { return this.i >= 0; }

  start() {
    if (!this.api.snap()) return;
    this.root.hidden = false;
    document.body.classList.add("touring");
    this.i = -1;
    const s0 = this.api.snap();
    this.shown = this.steps.filter((x) => !x.skip?.(s0));
    this.move(1);
    const loop = () => { this.place(); this.raf = requestAnimationFrame(loop); };
    cancelAnimationFrame(this.raf);
    this.raf = requestAnimationFrame(loop);
  }

  stop() {
    if (this.i < 0) return;
    this.i = -1;
    this.root.hidden = true;
    document.body.classList.remove("touring");
    cancelAnimationFrame(this.raf);
  }

  // Skips forward or back over stops whose subject isn't on this box.
  async move(dir) {
    if (this.busy) return;
    this.busy = true;
    try {
      let j = this.i + dir;
      while (j >= 0 && j < this.steps.length && this.steps[j].skip?.(this.api.snap())) j += dir;
      if (j >= this.steps.length) return this.stop();
      if (j < 0) return;
      const st = this.steps[j];
      this.card.classList.add("moving");
      await st.enter?.(this.api.snap());
      // a stop can depend on the page the enter step produced: re-check
      if (st.skip?.(this.api.snap())) { this.i = j; this.busy = false; return this.move(dir); }
      this.i = j;
      this.render();
    } finally {
      this.busy = false;
      this.card.classList.remove("moving");
    }
  }

  render() {
    const st = this.steps[this.i];
    const s = this.api.snap();
    const shown = this.shown.includes(st) ? this.shown : this.steps.filter((x) => !x.skip?.(s));
    const k = shown.indexOf(st);
    this.root.querySelector(".tour-n").textContent = `${k + 1} of ${shown.length}`;
    this.root.querySelector("#tour-title").textContent = st.title;
    let body;
    try { body = st.body(s); } catch (x) { body = `<p class="note err">This stop couldn't read what it needed: ${esc(x.message)}</p>`; }
    this.root.querySelector(".tour-body").innerHTML = body;
    this.root.querySelector(".tour-back").disabled = k <= 0;
    this.root.querySelector(".tour-next").textContent = k === shown.length - 1 ? "Finish" : "Next";
    this.root.querySelector(".tour-dots").innerHTML = shown.map((_, n) => `<i class="${n === k ? "on" : n < k ? "past" : ""}"></i>`).join("");
    this.place();
    this.card.querySelector(".tour-next").focus({ preventScroll: true });
  }

  // Every frame: targets move (the camera flies, panels scroll, data re-renders).
  place() {
    if (this.i < 0) return;
    const st = this.steps[this.i];
    let r = null;
    try { r = st.target?.(this.api.snap()) ?? null; } catch { r = null; }
    // offsetParent is null for position: fixed, so ask for boxes instead
    if (r instanceof Element) r = r.isConnected && r.getClientRects().length && !r.closest("[hidden]") ? r.getBoundingClientRect() : null;
    const W = window.innerWidth, H = window.innerHeight, pad = 6;
    if (r && r.width > 0 && r.height > 0) {
      const x = Math.max(4, r.left - pad), y = Math.max(4, r.top - pad);
      const w = Math.min(W - 8, r.right + pad) - x, h = Math.min(H - 8, r.bottom + pad) - y;
      Object.assign(this.spot.style, { left: `${x}px`, top: `${y}px`, width: `${w}px`, height: `${h}px` });
      this.spot.classList.remove("none");
      r = { left: x, top: y, right: x + w, bottom: y + h, width: w, height: h };
    } else {
      this.spot.classList.add("none");
      r = null;
    }
    const cw = this.card.offsetWidth, ch = this.card.offsetHeight, gap = 14;
    let cx, cy;
    if (!r) { cx = (W - cw) / 2; cy = (H - ch) / 2; }
    else if (W < 600) { cx = (W - cw) / 2; cy = r.bottom + gap + ch < H ? r.bottom + gap : r.top - gap - ch >= 0 ? r.top - gap - ch : H - ch - 10; }
    else if (r.right + gap + cw < W) { cx = r.right + gap; cy = r.top + r.height / 2 - ch / 2; }
    else if (r.left - gap - cw > 0) { cx = r.left - gap - cw; cy = r.top + r.height / 2 - ch / 2; }
    else if (r.bottom + gap + ch < H) { cx = r.left + r.width / 2 - cw / 2; cy = r.bottom + gap; }
    else if (r.top - gap - ch > 0) { cx = r.left + r.width / 2 - cw / 2; cy = r.top - gap - ch; }
    else { cx = (W - cw) / 2; cy = H - ch - 10; }
    cx = Math.max(10, Math.min(W - cw - 10, cx));
    cy = Math.max(10, Math.min(H - ch - 10, cy));
    this.card.style.transform = `translate3d(${Math.round(cx)}px, ${Math.round(cy)}px, 0)`;
  }
}
