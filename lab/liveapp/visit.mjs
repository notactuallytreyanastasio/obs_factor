#!/usr/bin/env node
// Visitors for the lab's LiveView app without a browser: opens each given
// page the way a browser does (GET the HTML, then join the LiveView over
// the websocket with the tokens found in it), clicks once a second where
// the page has a button, and leaves after HOLD seconds.
//
//   node lab/liveapp/visit.mjs http://127.0.0.1:14100 / /clock /room/42
//   HOLD=120 node lab/liveapp/visit.mjs http://127.0.0.1:14100 / / / /room/7
//
// Needs Node 22+ (global WebSocket and fetch). Prints one line per page
// when its LiveView has joined: only then is it "connected" in the report.

const [base, ...paths] = process.argv.slice(2);
if (!base || paths.length === 0) {
  console.error("usage: visit.mjs <base url> <path> [<path> ...]");
  process.exit(2);
}
const hold = Number(process.env.HOLD ?? 30) * 1000;
const clicks = [[/^\/room\//, "knock"], [/^\/clock/, null], [/^\/$/, "inc"]];

function attr(html, name) {
  const m = html.match(new RegExp(`${name}="([^"]*)"`));
  if (!m) throw new Error(`no ${name} in the page`);
  return m[1].replaceAll("&amp;", "&").replaceAll("&quot;", '"');
}

async function visit(path, n) {
  const url = new URL(path, base);
  const res = await fetch(url);
  if (!res.ok) throw new Error(`GET ${path}: ${res.status}`);
  const cookie = res.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
  const html = await res.text();

  const csrf = attr(html, 'name="csrf-token" content');
  const main = html.match(/<div[^>]*data-phx-main[^>]*>/)?.[0];
  if (!main) throw new Error(`GET ${path}: no LiveView in the page`);
  const topic = `lv:${attr(main, " id")}`;
  const join = {
    url: url.href,
    params: { _csrf_token: csrf, _mounts: 0 },
    session: attr(main, "data-phx-session"),
    static: attr(main, "data-phx-static"),
  };

  const wsUrl = new URL("/live/websocket", base);
  wsUrl.protocol = wsUrl.protocol === "https:" ? "wss:" : "ws:";
  wsUrl.searchParams.set("_csrf_token", csrf);
  wsUrl.searchParams.set("vsn", "2.0.0");
  // The session cookie rides on the upgrade request, as in a browser.
  const ws = new WebSocket(wsUrl, { headers: { cookie, origin: url.origin } });

  let ref = 0;
  const send = (joinRef, topic, event, payload) =>
    ws.send(JSON.stringify([joinRef, String(++ref), topic, event, payload]));

  await new Promise((resolve, reject) => {
    ws.onerror = (e) => reject(new Error(`websocket ${path}: ${e.message ?? "error"}`));
    ws.onopen = () => send("1", topic, "phx_join", join);
    ws.onmessage = ({ data }) => {
      const [, , t, event, payload] = JSON.parse(data);
      if (t !== topic || event !== "phx_reply") return;
      if (payload.status === "ok" && payload.response.rendered) {
        console.log(`joined ${path} as ${topic} (visitor ${n})`);
        resolve();
      } else if (payload.status !== "ok") {
        reject(new Error(`join ${path}: ${JSON.stringify(payload.response)}`));
      }
    };
  });

  const click = clicks.find(([re]) => re.test(url.pathname))?.[1];
  const timers = [setInterval(() => send(null, "phoenix", "heartbeat", {}), 30_000)];
  if (click) {
    send("1", topic, "event", { type: "click", event: click, value: {} });
    timers.push(setInterval(() => send("1", topic, "event", { type: "click", event: click, value: {} }), 1000));
  }
  return () => {
    timers.forEach(clearInterval);
    ws.close();
  };
}

const leave = await Promise.all(paths.map((p, i) => visit(p, i + 1)));
console.log(`${leave.length} connected; holding ${hold / 1000}s`);
const done = () => {
  leave.forEach((f) => f());
  console.log("left");
  process.exit(0);
};
process.on("SIGINT", done);
process.on("SIGTERM", done);
setTimeout(done, hold);
