// The page's one live connection: a Phoenix Channels websocket at /socket
// (ObsFactorWeb.UserSocket). Every feature that shows something live
// subscribes to a topic here; none opens its own socket, EventSource or
// polling loop. Topics and payloads: docs/contract.md "Live: one socket".
//
//   subscribe(topic, onEvent, { params, onJoin, onError }) -> unsubscribe
//     onEvent(event, payload) for every push on the topic;
//     onJoin(reply) on the join and again on every rejoin after a reconnect
//       (the reply is the topic's current state, so that is the resync); a
//       second subscriber to a joined topic gets the topic's current state
//       too: the latest whole-state push, or a fresh rejoin (see WHOLE);
//     onError(reason) when the server refuses the join (it is not retried);
//     params: an object, or a function called at each (re)join, e.g.
//       () => ({ after: lastId }) so a rejoin asks only for what it missed.
//   push(topic, event, payload) -> Promise of the reply; rejects with the
//     server's {error} as an Error. The topic must be subscribed.
//   onState(fn) -> unsubscribe; fn({ state, detail }) now and on each change,
//     state one of connecting | connected | reconnecting | refused.
//
// Connecting needs a short-lived token from GET /api/socket_token, fetched
// before every (re)connect: that GET is also how a reconnect learns the
// session is gone (401: to /login) or that the origin is not allowed (the
// server names what is). Reconnecting is ours, not phoenix.js's, so each
// attempt carries a fresh token.

import { Socket } from "../vendor/phoenix.mjs";

const topics = new Map(); // topic -> { ch, handlers: Set, reply, joined }
const stateFns = new Set();
let current = { state: "connecting", detail: "" };
let socket = null;
let token = null;
let attempt = 0;
let retryTimer = null;
let opening = false;
let openedOnce = false;
let refusedUpgrades = 0;

function setState(state, detail = "") {
  if (current.state === state && current.detail === detail) return;
  current = { state, detail };
  for (const fn of stateFns) fn(current);
}

export function onState(fn) {
  stateFns.add(fn);
  fn(current);
  return () => stateFns.delete(fn);
}

export function state() { return current; }

class Refused extends Error {}

async function fetchToken() {
  let r;
  try {
    r = await fetch(`/api/socket_token?origin=${encodeURIComponent(location.origin)}`, { cache: "no-store", credentials: "same-origin", headers: { accept: "application/json" } });
  } catch (x) {
    throw new Error(`observer unreachable (${x.message})`);
  }
  if (r.status === 401) {
    setState("refused", "signed out");
    window.location.assign("/login");
    throw new Refused("signed out");
  }
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error ? `socket token: ${j.error}` : `socket token answered ${r.status}`);
  if (j.origin && !j.origin.ok) throw new Refused(j.origin.reason);
  return j.token;
}

function ensureSocket() {
  if (socket) return socket;
  socket = new Socket("/socket", {
    params: () => ({ token }),
    // reconnecting is done in reconnect() below; phoenix.js's own timer is
    // stopped there by disconnect() before it fires
    reconnectAfterMs: () => 3_600_000,
  });
  socket.onOpen(() => {
    attempt = 0; refusedUpgrades = 0; openedOnce = true;
    setState("connected");
  });
  socket.onError(() => lost("error"));
  socket.onClose((ev) => lost(`closed${ev && ev.code ? ` (code ${ev.code})` : ""}`));
  open();
  return socket;
}

// a connection failed or dropped: tear it down cleanly and try again
function lost(how) {
  if (opening || retryTimer) return;
  const neverOpened = !socket.isConnected() && current.state !== "connected";
  socket.disconnect();
  if (neverOpened && token) refusedUpgrades++;
  const why = `websocket ${how}`;
  // the token GET worked (the observer is up) yet the upgrade keeps failing
  if (refusedUpgrades >= 3) setState("refused", `the observer answers HTTP but refused the websocket ${refusedUpgrades} times in a row: token or origin, or a proxy that does not pass websockets (${why}); retrying`);
  else setState(openedOnce ? "reconnecting" : "connecting", why);
  schedule();
}

function schedule() {
  clearTimeout(retryTimer);
  const ms = [500, 1000, 2000, 5000, 10000][attempt] ?? 30000;
  attempt++;
  retryTimer = setTimeout(() => { retryTimer = null; open(); }, ms);
}

async function open() {
  if (opening) return;
  opening = true;
  try {
    token = await fetchToken();
  } catch (x) {
    opening = false;
    if (x instanceof Refused) { setState("refused", x.message); if (x.message !== "signed out") schedule(); return; }
    setState(openedOnce ? "reconnecting" : "connecting", x.message);
    schedule();
    return;
  }
  opening = false;
  socket.connect();
}

// Pushes that carry a topic's whole state, in the shape of its join reply:
// they replace the reply kept for a late subscriber. Pushes that carry no
// state (an action relayed, a tick that failed) leave it. Any other push
// changes the state by a step (an `objective` row): the kept reply is
// stale from then on, and a late subscriber rejoins for a fresh one.
const WHOLE = { feed: (p) => p, list: (p) => p, snapshot: (p) => ({ snapshot: p }) };
// a tape `tick` grows the tape by a frame; the join reply (its range) is
// read again by nobody who needs it exact, so it is not a reason to rejoin
const NO_STATE = new Set(["action", "error", "tick"]);

function openChannel(topic, entry) {
  const ch = socket.channel(topic, entry.params);
  entry.ch = ch;
  ch.onMessage = (event, payload) => {
    if (entry.ch !== ch) return payload; // a channel this topic has left for a newer join
    if (!event.startsWith("phx_") && !event.startsWith("chan_reply_")) {
      if (WHOLE[event]) entry.reply = WHOLE[event](payload);
      else if (!NO_STATE.has(event)) entry.stale = true;
      for (const x of entry.handlers) {
        try { x.onEvent?.(event, payload); } catch (e) { console.error(`obs_factor: ${topic} ${event} handler`, e); }
      }
    }
    return payload;
  };
  ch.join()
    .receive("ok", (reply) => {
      if (entry.ch !== ch) return;
      entry.reply = reply; entry.joined = true; entry.stale = false;
      for (const x of entry.handlers) x.onJoin?.(reply);
    })
    .receive("error", (r) => {
      if (entry.ch !== ch) return;
      const reason = r?.reason ?? JSON.stringify(r);
      console.error(`obs_factor: join ${topic} refused: ${reason}`);
      for (const x of entry.handlers) x.onError?.(reason);
      // a refused join is the server saying no, not a transient failure
      ch.leave(); topics.delete(topic);
    })
    .receive("timeout", () => {
      if (entry.ch !== ch) return;
      for (const x of entry.handlers) x.onError?.(`join ${topic} timed out; retrying`);
    });
}

export function subscribe(topic, onEvent, { params = {}, onJoin, onError } = {}) {
  ensureSocket();
  let t = topics.get(topic);
  const h = { onEvent, onJoin, onError };
  if (!t) {
    t = { ch: null, handlers: new Set(), reply: null, joined: false, stale: false, params: typeof params === "function" ? params : () => params };
    topics.set(topic, t);
    openChannel(topic, t);
  } else if (t.joined && !t.stale) {
    // already joined for someone else on this page, and the kept reply is
    // still the topic's state: hand it over
    queueMicrotask(() => onJoin?.(t.reply));
  } else if (t.joined) {
    // the kept reply predates a change: join again, and every subscriber
    // gets the fresh reply (onJoin is the resync, as after a reconnect)
    // (the leave goes out first: a join of a topic still open on the
    // socket would make phoenix.js leave it itself, out of our order)
    t.joined = false;
    t.ch.leave();
    openChannel(topic, t);
  }
  t.handlers.add(h);
  return () => {
    const e = topics.get(topic);
    if (!e || !e.handlers.delete(h)) return;
    if (!e.handlers.size) { e.ch.leave(); topics.delete(topic); }
  };
}

export function push(topic, event, payload = {}) {
  const t = topics.get(topic);
  if (!t) return Promise.reject(new Error(`push to ${topic}: not subscribed`));
  return new Promise((resolve, reject) => {
    t.ch.push(event, payload)
      .receive("ok", resolve)
      .receive("error", (r) => reject(new Error(r?.error ?? JSON.stringify(r))))
      .receive("timeout", () => reject(new Error(`${topic} ${event}: no reply within 10 s`)));
  });
}
