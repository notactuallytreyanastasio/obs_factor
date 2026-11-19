// Live data: one GET /api/snapshot to start, then `snapshot` events on
// /api/stream. A 401 anywhere sends the browser to /login.
//
// EventSource hides the HTTP status of a failed connection, so when the
// stream errors we ask /api/snapshot directly: 401 means the session is
// gone; anything else means the observer is unreachable and we keep trying.

export function connect({ onSnapshot, onState }) {
  let es = null;
  let backoff = 1000;
  let retryTimer = null;
  let closed = false;

  const toLogin = () => { window.location.assign("/login"); };

  async function probe() {
    try {
      const r = await fetch("/api/snapshot", { cache: "no-store", credentials: "same-origin", headers: { accept: "application/json" } });
      if (r.status === 401) return toLogin();
      if (!r.ok) { onState("reconnecting", `snapshot answered ${r.status}`); return; }
      onSnapshot(await r.json());
    } catch (err) {
      onState("reconnecting", `observer unreachable (${err.message})`);
    }
  }

  function open() {
    if (closed) return;
    clearTimeout(retryTimer);
    es = new EventSource("/api/stream", { withCredentials: true });
    es.addEventListener("open", () => { backoff = 1000; onState("live"); });
    es.addEventListener("snapshot", (ev) => {
      let snap;
      try { snap = JSON.parse(ev.data); } catch (err) {
        console.error("obs_factor: snapshot event is not JSON", err, ev.data.slice(0, 200));
        onState("live", "bad snapshot event");
        return;
      }
      onSnapshot(snap);
    });
    es.addEventListener("error", () => {
      onState("reconnecting");
      probe();
      if (es.readyState === EventSource.CLOSED) {
        // The browser gave up (HTTP error, wrong content type): retry ourselves.
        es.close();
        retryTimer = setTimeout(open, backoff);
        backoff = Math.min(backoff * 2, 30000);
      }
    });
  }

  probe().then(open);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && es && es.readyState === EventSource.CLOSED) open();
  });
  return { close() { closed = true; es?.close(); } };
}

export async function fetchHistory(node, res) {
  const r = await fetch(`/api/history?node=${encodeURIComponent(node)}&res=${res}`, { cache: "no-store", credentials: "same-origin" });
  if (r.status === 401) { window.location.assign("/login"); throw new Error("signed out"); }
  if (r.status === 404) throw new Error("the observer has no history for this node");
  if (!r.ok) throw new Error(`history answered ${r.status}`);
  return r.json();
}
