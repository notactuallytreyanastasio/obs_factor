// The lab's memory-limited upstream: a tiny Node HTTP server in the shape of
// production's skee-relay / lumines / slides-relay (node:24-alpine, bind-mounted
// read-only, one file, no dependencies).
//
// It exists to be broken on purpose. Its controls are files in lab/state/,
// which the host writes and the container only reads (the mount is :ro), so
// breaking it needs no endpoint that changes state:
//
//   lab/state/relay.crash     present at boot -> exit 1 (restart: always
//                             turns that into a restart loop)
//   lab/state/relay.fail      present -> every request answers 503
//   lab/state/relay.eat-mb    a number N -> hold N MiB of live heap
//                             (re-read every second; shrink it to free)
//
// GET /health answers 200 "ok" unless relay.fail is present.

import http from "node:http";
import fs from "node:fs";

const PORT = Number(process.env.PORT ?? 8788);
const STATE = process.env.STATE_DIR ?? "/state";

const exists = (f) => fs.existsSync(`${STATE}/${f}`);

if (exists("relay.crash")) {
  console.error(`relay: ${STATE}/relay.crash is present, exiting 1`);
  process.exit(1);
}

// Held memory: an array of 1 MiB Buffers filled with bytes, so the pages are
// actually touched and count against the cgroup (an unfilled allocation would
// not show up in RSS and would never get near the limit).
let held = [];
setInterval(() => {
  let want = 0;
  try {
    want = Number.parseInt(fs.readFileSync(`${STATE}/relay.eat-mb`, "utf8").trim(), 10);
  } catch (e) {
    if (e.code !== "ENOENT") throw e;
  }
  if (!Number.isInteger(want) || want < 0) {
    throw new Error(`relay.eat-mb must be a non-negative integer, got ${JSON.stringify(want)}`);
  }
  if (want !== held.length) {
    while (held.length < want) held.push(Buffer.alloc(1 << 20, 0x61));
    held.length = Math.min(held.length, want);
    console.log(`relay: holding ${held.length} MiB, rss ${(process.memoryUsage().rss / 1048576).toFixed(0)} MiB`);
  }
}, 1000);

http
  .createServer((req, res) => {
    if (exists("relay.fail")) {
      res.writeHead(503, { "content-type": "text/plain" });
      res.end("relay.fail is present\n");
      return;
    }
    res.writeHead(200, { "content-type": "text/plain" });
    res.end(req.url === "/health" ? "ok\n" : `relay ${req.method} ${req.url}\n`);
  })
  .listen(PORT, () => console.log(`relay: listening on ${PORT}`));
