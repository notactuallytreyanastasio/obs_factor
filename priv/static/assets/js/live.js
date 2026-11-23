// Live data: the "snapshots" channel on the page's one socket (bus.js). The
// join reply is the current snapshot, so the first load and the resync after
// a reconnect are the same thing; then one `snapshot` push per tick, and an
// `error` push for a tick whose build failed.

import * as bus from "./bus.js";

export function connect({ onSnapshot, onState, onTickError }) {
  bus.onState(({ state, detail }) => onState(state, detail));
  const unsub = bus.subscribe("snapshots", (event, payload) => {
    if (event === "snapshot") onSnapshot(payload);
    else if (event === "error") onTickError(payload.error);
  }, {
    onJoin: (reply) => (reply.snapshot ? onSnapshot(reply.snapshot) : onTickError(reply.error)),
    onError: (reason) => onTickError(`snapshots refused: ${reason}`),
  });
  return { close: unsub };
}
