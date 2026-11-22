// Virtual time for engine tests: sleep() registers a timer, runUntil() jumps
// the clock to the next timer whenever everything else is idle.

export function virtualClock() {
  let now = 0;
  let seq = 0;
  const timers = [];
  return {
    now: () => now,
    sleep: (ms) => new Promise((r) => { timers.push({ at: now + Math.max(0, ms), seq: seq++, r }); }),
    async runUntil(promise, maxSteps = 2e6) {
      let done = false;
      promise.then(() => { done = true; }, () => { done = true; });
      for (let i = 0; i < maxSteps && !done; i++) {
        await new Promise(setImmediate);
        if (done || !timers.length) continue;
        timers.sort((a, b) => a.at - b.at || a.seq - b.seq);
        const t = timers.shift();
        now = Math.max(now, t.at);
        t.r();
      }
      return promise;
    },
  };
}

/** Largest number of entries of sorted `times` (seconds) inside any half-open 1 s window. */
export function maxInAnyWindow(times, width = 1) {
  const s = [...times].sort((a, b) => a - b);
  let best = 0;
  for (let i = 0, j = 0; i < s.length; i++) {
    while (s[i] - s[j] >= width) j++;
    best = Math.max(best, i - j + 1);
  }
  return best;
}
