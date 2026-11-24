// The tour's chapters (tour.js runs them). Each chapter is a short tour of
// one part of the product, with an anchor on the page where its beacon
// sits; the whole tour is every chapter in order. Like the stops already in
// tour.js, every number here is read from the live page at that step, and a
// stop whose subject isn't on this box is skipped rather than faked:
// `skip(snap)` is checked before a stop is entered, `skipAfter()` after (for
// stops that need the page the enter step produced, like a captured
// evidence button).

import { num, esc, utc } from "./fmt.js";
import { span } from "./timeline.js";
import { me } from "./identity.js";

const $ = (id) => document.getElementById(id);
const q = (sel) => document.querySelector(sel);
const code = (s) => `<code>${esc(s)}</code>`;
const hm = (ms) => new Date(ms).toISOString().slice(11, 16);
const plural = (n, w) => `${n} ${w}${n === 1 ? "" : "s"}`;

export function waitFor(fn, ms = 3000) {
  return new Promise((resolve) => {
    const t0 = performance.now();
    const tick = () => {
      let v = null;
      try { v = fn(); } catch { v = null; }
      if (v || performance.now() - t0 > ms) return resolve(v || null);
      setTimeout(tick, 60);
    };
    tick();
  });
}

const pause = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- the tape --------------------------------------------------------------

function tape(api) {
  const tl = () => api.timeline;
  // the moment to replay: the worst fire Fires found, else 10 minutes ago
  const replayAt = () => {
    const w = api.fires?.data?.worst?.at;
    const r = tl().range;
    return w && r && w >= r.from ? w : Math.max(r?.from ?? 0, Date.now() - 10 * 60e3);
  };
  return [
    {
      title: "The tape: everything is recorded",
      target: () => q("#timeline .tl-strip"),
      enter: async () => { api.closeAll(); tl().setSpan(3600e3); await waitFor(() => tl().ok || tl().range, 3000); },
      body: () => {
        const r = tl().range;
        return `Every snapshot the floor has ever drawn is on the tape (${code("ObsFactor.Tape")}, Postgres): every tick for 6 hours, then one a minute for 7 days.
          ${r ? `<p>Right now it holds <b>${esc(num(r.frames))}</b> frames, from <b>${esc(utc(new Date(r.from)))}</b> UTC.</p>` : `<p class="note err">The tape hasn't answered on this page yet, so the strip is empty.</p>`}
          Red is an alert, amber a warning, and the ticks above are BEAM news from the wire. Click anywhere to replay that moment; scroll to zoom; drag to pan.`;
      },
    },
    {
      title: "One lane per building that burned",
      target: () => q("#timeline .tl-strip"),
      enter: async () => { tl().setExpanded(true); await pause(400); },
      body: () => {
        const l = tl().lanes ?? [];
        const w = l[0];
        return `Lanes (${code("t")}) split the tape into a row per building that had trouble in view, worst first, so you can see which fire started first and which one followed.
          ${w ? `<p>Worst in this hour: <b>${esc(api.label(w.node))}</b>, ${w.alert_ms ? `${esc(span(w.alert_ms))} on fire` : `${esc(span(w.warn_ms))} smoking`}${l.length > 1 ? `, then ${plural(l.length - 1, "more")}` : ""}.</p>` : "<p>Nothing burned in the last hour, so there are no lanes: a quiet hour looks quiet.</p>"}
          The heat rows under the lanes are each BEAM's reductions, memory or run queue (pick in the corner) over the same span.`;
      },
    },
    {
      title: "How much to look at",
      target: () => q("#timeline .tl-spans"),
      body: () => `15 minutes to 7 days. Older than the tape's 7 days, the view and the writeups read the hourly rollups (${code("tape_rollups")}, kept 13 months): maxima, time-weighted means and alert seconds per building, per hour.
        ${tl().index?.rollups_to ? `<p>This view reaches back past the tape: the grey band marked “hourly rollups” is that history.</p>` : ""}`,
    },
    {
      title: "Jump from fire to fire",
      target: () => q("#timeline .tl-ctl"),
      body: () => `${code("[")} and ${code("]")} jump to the previous and next fire; ${code("Space")} plays. On the live floor, Play is an instant replay of the last 2 minutes.
        Playback runs at 1× to 60× (the speed button), and the floor redraws every frame exactly as it was.`,
    },
    {
      title: "Replaying the past",
      target: () => q("#timeline .tl-back:not([hidden])") ?? q("#timeline .tl-live"),
      enter: async () => { tl().seek(replayAt()); await waitFor(() => tl().replaying, 1500); await pause(500); },
      body: () => `The whole page is now at <b>${esc(hm(tl().cursor ?? Date.now()))}</b> UTC${api.fires?.data?.worst ? ", the worst moment on the tape" : ""}: floor, lamps, board, inspector. The top bar says so, and the floor is tinted so a replay can't pass for now.
        <p>Nothing acts on the live system from here. Kill, GC and Restart are refused while you replay (${code("bus.js")} guards the socket), because they would hit the system as it is now, not as you're seeing it.</p>
        The pill is the way back: one click, or ${code("End")}.`,
    },
    {
      title: "Select a stretch, keep it",
      target: () => q("#timeline .tl-sel:not([hidden])") ?? q("#timeline .tl-strip"),
      enter: async () => {
        const t = tl(), now = Date.now();
        t.goLive();
        t.sel = { a: now - 20 * 60e3, b: now - 5 * 60e3 };
        t.render();
        await pause(300);
      },
      body: () => `Drag across the strip (here, 20 to 5 minutes ago) and the stretch gets its own bar: zoom to it, count its fires, write it up, or save it as a <b>window</b>.
        A saved window is kept at full detail when the rest of the tape is thinned, so the incident you want to show someone next week is still there tick by tick.`,
    },
    {
      title: "Windows",
      target: () => q("#timeline .tl-wins:not([hidden])"),
      enter: async () => { const t = tl(); t.sel = null; t.render(); t.toggleWins(true); await pause(300); },
      body: () => {
        const n = (tl().windows ?? []).filter((w) => !w.pruned_at).length;
        return `${n ? `<b>${plural(n, "saved window")}</b>, shared by everyone on this observer.` : "No saved windows yet."} Open one to replay it, loop it, trim its edges by dragging, or prune it.
          Pruning lets the tape thin it like any other stretch, and can be undone for an hour.`;
      },
    },
    {
      title: "What code went out, and when",
      skip: () => !(api.deploys?.list ?? []).length,
      target: () => q("#timeline .tl-strip"),
      enter: async () => {
        tl().toggleWins(false);
        const d = api.deploys.list[0];
        const age = Date.now() - (d?.at ?? 0);
        tl().setSpan(age < 3600e3 ? 3600e3 : age < 86400e3 ? 86400e3 : 7 * 86400e3);
        await pause(500);
      },
      body: () => {
        const l = api.deploys.list;
        const d = [...l].sort((a, b) => b.at - a.at)[0];
        return `The dotted lines are deploys, read from each app's ${code(".deployed")} file on the box (${code("ObsFactor.Deploys")}): the short sha, with ${code("+")} when it went out with uncommitted changes.
          <p>Latest: <b>${esc(api.label(d.node))}</b> ${code(`${d.sha}${d.dirty ? "+" : ""}`)} at ${esc(hm(d.at))} UTC${d.subject ? `, “${esc(d.subject)}”` : ""}. ${plural(l.length, "deploy")} in the last 31 days.</p>
          A restart that lines up with one is said on the wire as a deploy, not a crash.`;
      },
    },
    {
      title: "Back to live",
      target: () => q("#timeline .tl-live"),
      enter: async () => { const t = tl(); t.toggleWins(false); t.setSpan(3600e3); t.goLive(); t.setExpanded(false); await pause(200); },
      body: () => `The green dot means the floor is live. ${code("End")} from anywhere brings you back here, and the view slides along with now.`,
    },
  ];
}

// ---- fires -------------------------------------------------------------------

function fires(api) {
  return [
    {
      title: "Fires: how the shift is going",
      target: () => $("fires"),
      enter: async () => { api.closeAll(); api.fires.toggle(true); await waitFor(() => api.fires.data || api.fires.error, 5000); },
      body: () => {
        const F = api.fires;
        if (!F.data) return `Fires reads the tape, and the tape didn't answer: ${esc(F.error ?? "no data")}.`;
        const d = F.data, s = d.score;
        const calm = d.calm.share == null ? null : Math.round(d.calm.share * 100);
        return `The game part: over the window in view, how many fires started, how many someone put out, and how long the floor has been calm.
          <p>Last hour: <b>${esc(s.started)}</b> started, <b>${esc(s.put_out)}</b> put out${calm != null ? `, calm <b>${calm}%</b> of the time` : ""}.
          ${d.hot?.[0] ? ` Burned longest: <b>${esc(api.label(d.hot[0].node))}</b>.` : ""}</p>
          Every row is a link: a building flies you to it, a moment replays it. Select a stretch on the tape and Fires scores just that.`;
      },
    },
  ];
}

// ---- the board ------------------------------------------------------------------

function board(api) {
  const B = () => api.board;
  const tab = async (t) => { const b = B(); if (!b.open) b.toggle(true); b.tab = t; b.renderMonitor(); await pause(350); };
  return [
    {
      title: "The index row",
      target: () => $("indexrow"),
      enter: async () => { api.closeAll(); },
      body: () => `The ticker across the top is every BEAM on the box added up: processes, run queue, memory, reductions, mailboxes, distribution traffic, repos, Postgres connections. Each has a sparkline of the last minutes and its move.
        It follows the tape, so in a replay it shows that moment's numbers.`,
    },
    {
      title: "The news",
      target: () => $("news"),
      body: () => {
        const w = B().wire ?? [];
        return `The chyron and crawl are the BEAM wire: what changed between ticks, written as headlines. A node restarted or left, a mailbox piled up, a stream started failing, reductions jumped past the baseline, a deploy went out, PubSub subscriptions crept up.
          <p><b>${esc(num(w.length))}</b> items in view${w[0] ? `; latest: “${esc(`${w[0].label ?? w[0].app ?? ""} · ${w[0].head}`)}”` : ""}.</p> Click a headline to go to it.`;
      },
    },
    {
      title: "The board",
      target: () => $("board"),
      enter: async () => { await tab("wire"); },
      body: () => `${code("b")} opens it. Six tabs, every one following the tape: the wire, errors, every BEAM node, each app's database, error budgets and PubSub.
        <p>The Wire tab is the whole feed, filterable by app, kind and severity, or by search.</p>`,
    },
    {
      title: "Filter sets, and what's on air",
      target: () => q("#board .bd-sets"),
      body: () => {
        const s = B().sets ?? [];
        const air = s.find((x) => String(x.id) === B().air);
        return `Filter the wire, then <b>Save as set</b>. Sets are shared by everyone on this observer${s.length ? `, and there ${s.length === 1 ? "is" : "are"} ${plural(s.length, "set")}: ${s.map((x) => code(x.name)).join(" ")}` : ", and none are saved yet"}.
          <p><b>air</b> puts a set on air: the chyron and crawl then show only what matches it, on this screen. ${air ? `On air now: ${code(air.name)}.` : ""}</p>
          Writeups and alert routes can take a set, too.`;
      },
    },
    {
      title: "Evidence, captured when it happened",
      skipAfter: () => !q("#board .ev-btn"),
      target: () => q("#board .ev-btn")?.closest("li, .row, tr, div"),
      enter: async () => { q("#board .ev-btn")?.scrollIntoView({ block: "center" }); await pause(200); },
      body: () => `When the wire sees a crash, a burst or a mailbox flood, the observer asks that BEAM straight away what it was doing: top processes by reductions and mailbox, and its recent log lines. That is kept with the item (${code("wire_evidence")}).
        <p>Click <b>evidence</b> to see it. Minutes later, the processes that caused it are often gone, and this is the only record of them.</p>`,
    },
    {
      title: "Errors, grouped",
      target: () => $("board"),
      enter: async () => { await tab("errors"); },
      body: () => {
        const g = B().fingerprints();
        return `Every error and warning the apps reported, grouped by fingerprint, so one bug that fired 400 times is one row with ×400, first and last seen. <b>${plural(g.length, "group")}</b> in view.`;
      },
    },
    {
      title: "Every BEAM node",
      target: () => $("board"),
      enter: async () => { await tab("beam"); },
      body: () => `One row per node: processes, reductions, run queue, memory, binary, mailboxes, distribution. <b>Movers</b> are what changed most in 5 minutes, and the cluster map shows which members see each other, so a partition shows as a broken line.
        <p>${plural(B().keys("beam:").length, "node")} reporting.</p>`,
    },
    {
      title: "Each app's database",
      target: () => $("board"),
      enter: async () => { await tab("db"); },
      body: () => `Connections and commits per database, and per table which queries cost the most time (from each app's Ecto telemetry, through ${code("factory_report")}). A table that starts eating time is usually the next fire.`,
    },
    {
      title: "Error budgets",
      target: () => $("board"),
      enter: async () => { await tab("slo"); },
      body: () => {
        const S = B().slo;
        return `Set a target per app, say 99.5% of requests not a 5xx over 30 days, and the board keeps the budget: how much is left, and how fast it is burning (${code("ObsFactor.SLOs")}, read off the tape).
          <p>${S.reports.length ? `<b>${plural(S.reports.length, "budget")}</b> set${S.burning() ? `, <b>${S.burning()} burning</b> fast enough to raise a flag` : ", none burning"}.` : "No budget is set on this observer yet; the form is right here."}</p>
          A fast burn goes out as an alert, like any other.`;
      },
    },
    {
      title: "PubSub: who listens to what",
      target: () => q("#board #ps-side .ps-graph") ? q("#board #ps-side") : $("board"),
      enter: async () => {
        await tab("pubsub");
        const pat = await waitFor(() => q("#board [data-ps-pat]"), 2000);
        if (!pat) return;
        pat.click();
        const top = await waitFor(() => q("#board [data-ps-topic]"), 3000);
        top?.click();
        await waitFor(() => q("#board #ps-side .ps-graph svg"), 3000);
      },
      body: () => {
        const n = B().pubsub.count();
        const topic = q("#board [data-ps-topic]")?.dataset.psTopic;
        return `Every Phoenix.PubSub in every app: topics and subscriptions over time. The report ranks topic <b>patterns</b> (${code("post:#")}), never the topics, so no user id leaves an app.
          ${topic ? `<p>Opened ${code(topic)}: the graph is live, one dot per subscriber, sized by its mailbox, coloured LiveView, channel or plain process. Click one to open that process.</p>` : ""}
          ${plural(n, "server")} reporting. A subscription count that climbs for 30 minutes is said on the wire as a leak.`;
      },
    },
  ];
}

// ---- reporting ----------------------------------------------------------------------

function reporting(api) {
  const W = () => api.writeups;
  return [
    {
      title: "Write it up",
      target: () => q("#writeup .wu-opts") ?? $("writeup"),
      enter: async () => {
        api.closeAll();
        const to = Date.now();
        W().open({ from: to - 3600e3, to, title: "obs_factor: the last hour" });
        await waitFor(() => q("#writeup .wu-doc")?.textContent.trim().length > 40, 6000);
      },
      body: () => `Any stretch of the tape becomes a Markdown document: summary, incidents, timeline, where it burned, the BEAM, errors, databases, error budgets, PubSub, deploys, evidence, and how it was measured.
        Pick the apps, a wire filter set and the sections; compare with the same period last week or last month (from the rollups).
        <p>Open it from the Fires panel (✎), from a selected stretch, or from the menu.</p>`,
    },
    {
      title: "The document",
      target: () => q("#writeup .wu-doc"),
      body: () => {
        const h = [...document.querySelectorAll("#writeup .wu-doc h2")].map((x) => x.textContent);
        return `This is the real document for the last hour${h.length ? `, ${plural(h.length, "section")}: ${h.map(code).join(" ")}` : ""}. Copy it, download it, or <b>share</b> it: a shared writeup gets a link at ${code("/w/<slug>.md")} that reads without a login, so it can go in a ticket or a postmortem.`;
      },
    },
    {
      title: "Writeups that write themselves",
      target: () => q("#writeup .wu-schedules"),
      enter: async () => { q("#writeup .wu-schedules")?.scrollIntoView({ block: "center" }); await pause(200); },
      body: () => {
        const s = W().schedules ?? [];
        return `A schedule writes up the last day or week at an hour you pick (UTC), shares it, and posts the link to a webhook (Slack's incoming webhooks read it as is). ${s.length ? `${plural(s.length, "schedule")} on this observer.` : "None set up yet."}
          <p>Scripts read writeups too: make a token (${code("obsf_…")}, shown once, kept only as a hash) and ${code("curl -H 'Authorization: Bearer …' /api/writeup.md?from=…&to=…")}.</p>`;
      },
    },
  ];
}

// ---- running it --------------------------------------------------------------------

function operating(api) {
  return [
    {
      title: "Alerts that leave the page",
      target: () => $("alerts"),
      enter: async () => { api.closeAll(); api.alerts.toggle(true); await pause(500); },
      body: () => {
        const r = api.alerts.routes ?? [];
        return `A page nobody is looking at can't wake anyone. A route sends alerts to a webhook (Slack, or anything that takes JSON): objectives opening and clearing, crashes, partitions, failing streams, atoms past 80%, a full Postgres, a fast budget burn. Narrow a route by app, severity or a wire filter set.
          <p>${r.length ? `<b>${plural(r.length, "route")}</b> set up.` : "No route set up yet: until one is, alerts stay on this page."} <b>Test</b> sends one now. A route that fails is said on the page, not dropped.</p>`;
      },
    },
    {
      title: "Who you are here",
      target: () => $("whoami") ?? $("menu"),
      enter: async () => { api.alerts.toggle(false); api.menu(true); await pause(250); },
      body: () => {
        if (!me) return `This page couldn't read who it is signed in as (${code("/api/me")}).`;
        const how = me.via === "github" ? `signed in with GitHub as <b>${esc(me.login)}</b>` : "signed in with the shared password";
        return `You are ${how}, as ${me.role === "operator" ? "an <b>operator</b>" : "a <b>viewer</b>"}.
          <p>Viewers watch, replay, filter and write up. Operators also act: ${me.operator_only?.length ? `${plural(me.operator_only.length, "action")}, including killing a process, making tokens, schedules, alert routes and error budgets` : "processes, tokens, schedules, alert routes, budgets"}. The server checks the role on every one of them, whatever the page shows, and logs who did it.</p>`;
      },
    },
    {
      title: "Connect an app",
      target: () => q("#connect .cn-steps") ?? $("connect"),
      enter: async () => { api.menu(false); api.connect.show(); await pause(500); },
      body: () => `Adding an Elixir app to the floor takes no change to the observer: add ${code("factory_report")}, put a few labels on its compose service (${code("obs_factor.report")}, ${code("obs_factor.hosts")}, …), and deploy.
        <p>Fill in the form and it writes the exact lines for your app, then watches: each check turns green as the box sees the container, the labels, the report and the first tick.</p>`,
    },
  ];
}

// ---- the chapters ----------------------------------------------------------------------

/**
 * `old` is the tour's original stops, by title (tour.js). Chapters:
 * `{id, title, blurb, anchor(): Element|null, steps}`.
 */
export function chapters(api, old) {
  const pickOld = (...titles) => titles.map((t) => old.get(t)).filter(Boolean);
  return [
    {
      id: "floor", title: "The floor", blurb: "Buildings, lamps, belts, the inspector and where every number comes from",
      anchor: () => $("legendbtn"),
      steps: pickOld("This is the box, as a factory", "Live, not polled by your browser", "What's coming in", "Needs attention", "Reading the lamps", "Where every number comes from",
        "The front door", "The inspector", "Per hostname", "History", "Asking an app if it's alive", "The container under it", "Every address", "Real logs, part 1: a build"),
    },
    { id: "tape", title: "Replay", blurb: "The tape, lanes, fire to fire, windows, deploys and back to live", anchor: () => q("#timeline .tl-live"), steps: tape(api) },
    {
      id: "fires", title: "Fires and missions", blurb: "The score of the shift, and what to check before you leave",
      anchor: () => $("firesbtn"), steps: [...fires(api), ...pickOld("Missions: what to check before you leave")],
    },
    { id: "board", title: "The board", blurb: "The BEAM wire, filter sets, evidence, errors, nodes, databases, budgets, PubSub", anchor: () => $("boardbtn"), steps: board(api) },
    { id: "reporting", title: "Writeups", blurb: "Any stretch as Markdown: shared links, schedules, script tokens", anchor: () => $("menubtn"), steps: reporting(api) },
    { id: "operating", title: "Running it", blurb: "Alerts out, roles, and connecting a new app", anchor: () => $("alertsbtn"), steps: operating(api) },
    {
      id: "hood", title: "Under the hood", blurb: "The observer's own VM, processes, logs and every BEAM's process table",
      anchor: () => $("beambtn"),
      steps: pickOld("Under the hood", "One process per source", "Where the grey comes from", "The tables a snapshot is built from", "Real logs, part 2: the observer's own",
        "The same VM, as buildings", "Search every log", "Every BEAM's processes, in one table"),
    },
  ];
}

