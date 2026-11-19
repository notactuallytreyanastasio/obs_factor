// How fast: the rate caps, the scenario rate shapes, the Poisson pacer that
// turns a shape into arrival times, and the health window that backs off.
// Everything here is pure (clock and randomness are passed in) so tests are
// deterministic and need no real time.

import { UsageError } from './catalogue.mjs';

export const DEFAULT_MAX_RPS = 20;
export const ABSOLUTE_MAX_RPS = 100;
export const SCENARIOS = ['steady', 'burst', 'wave', 'visit'];

/** The cap in force: 20 unless --i-know-max-rps raises it, never above 100. */
export function resolveMaxRps(iKnow) {
  if (iKnow == null) return DEFAULT_MAX_RPS;
  const n = Number(iKnow);
  if (!Number.isFinite(n) || n <= 0) throw new UsageError(`--i-know-max-rps must be a positive number`);
  if (n > ABSOLUTE_MAX_RPS) throw new UsageError(`--i-know-max-rps ${n} is above the absolute ceiling of ${ABSOLUTE_MAX_RPS} req/s`);
  return n;
}

export function checkRps(rps, maxRps) {
  if (!Number.isFinite(rps) || rps <= 0) throw new UsageError(`--rps must be a positive number`);
  if (rps > maxRps) {
    throw new UsageError(maxRps < ABSOLUTE_MAX_RPS && maxRps === DEFAULT_MAX_RPS
      ? `--rps ${rps} is above the ${DEFAULT_MAX_RPS} req/s cap; pass --i-know-max-rps <n> (at most ${ABSOLUTE_MAX_RPS}) to raise it`
      : `--rps ${rps} is above the cap of ${maxRps} req/s`);
  }
}

/** Small seeded PRNG (mulberry32), so --seed and tests are reproducible. */
export function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * The target request rate over time. `rps` is always the PEAK:
 *   steady: rps throughout
 *   burst:  rps for `burstLen` seconds at the start of every `period`, 0 in between
 *   wave:   10% of rps at t=0, rising to 100% at period/2, back to 10% at period
 *   visit:  rps is the ceiling the visitors share (think time keeps the real rate below it)
 */
export function makeShape(scenario, rps, { period, burstLen } = {}) {
  if (!SCENARIOS.includes(scenario)) throw new UsageError(`unknown --scenario "${scenario}" (one of ${SCENARIOS.join('|')})`);
  const P = period ?? (scenario === 'wave' ? 60 : 20);
  const B = burstLen ?? 3;
  if (!(P > 0)) throw new UsageError('--period must be > 0');
  if (scenario === 'burst' && !(B > 0 && B < P)) throw new UsageError('--burst-len must be > 0 and shorter than --period');
  const rateAt = {
    steady: () => rps,
    visit: () => rps,
    burst: (t) => ((t % P) < B ? rps : 0),
    wave: (t) => rps * (0.55 - 0.45 * Math.cos((2 * Math.PI * t) / P)),
  }[scenario];
  return {
    scenario, peak: rps, period: P, burstLen: B, rateAt,
    /** mean rate over [0, duration], numerically */
    average(duration) {
      const steps = Math.max(100, Math.ceil(duration * 20));
      let sum = 0;
      for (let i = 0; i < steps; i++) sum += rateAt(((i + 0.5) / steps) * duration);
      return sum / steps;
    },
  };
}

/**
 * Arrival times for a non-homogeneous Poisson process (thinning), plus a hard
 * sliding-window cap: never more than floor(maxRps) starts in any 1 s window,
 * whatever the randomness does. Times are in seconds from the start of the run.
 */
export class Pacer {
  constructor({ shape, random, maxRps }) {
    this.shape = shape;
    this.random = random;
    this.capCount = Math.max(1, Math.floor(maxRps));
    this.multiplier = 1;
    this.last = 0;
    this.starts = [];
  }

  /** Reserve and return the next arrival at or after `now`. */
  next(now) {
    // Poisson is memoryless: if we fell behind (or sat idle), restart from now
    // rather than firing a catch-up burst.
    let t = Math.max(this.last, now);
    const peak = this.shape.peak * this.multiplier;
    for (let i = 0; i < 1e6; i++) {
      t += -Math.log(1 - this.random()) / peak;
      if (this.random() * peak < this.shape.rateAt(t) * this.multiplier) break;
    }
    if (this.starts.length >= this.capCount) {
      const nth = this.starts[this.starts.length - this.capCount];
      if (t - nth < 1) t = nth + 1 + 1e-9; // epsilon: (a + 1) - a can round below 1
    }
    this.starts.push(t);
    if (this.starts.length > this.capCount) this.starts.shift();
    this.last = t;
    return t;
  }
}

/**
 * The last `window` responses. More than `threshold` bad (429, 5xx, connection
 * error, timeout) -> back off to 10%; a healthy window at the reduced rate ->
 * recover; the `maxBackoffs`-th back-off in a row -> abort. Only responses to
 * requests started in the current epoch count, so stragglers from before a
 * back-off are not held against the reduced rate.
 */
export class Health {
  constructor({ window = 50, threshold = 0.3, minSamples = 10, maxBackoffs = 3, backoffTo = 0.1 } = {}) {
    Object.assign(this, { window, threshold, minSamples, maxBackoffs, backoffTo });
    this.samples = [];
    this.epoch = 0;
    this.consecutive = 0;
    this.total = 0;
    this.multiplier = 1;
  }

  static isBad(result) {
    return result.status === 0 || result.status === 429 || result.status >= 500;
  }

  /** Returns null | {event:'backoff'|'recover'|'abort', ratio, n}. */
  record(result, epoch = this.epoch) {
    if (epoch !== this.epoch) return null;
    this.samples.push(Health.isBad(result));
    if (this.samples.length > this.window) this.samples.shift();
    const n = this.samples.length;
    if (n < this.minSamples) return null;
    const ratio = this.samples.filter(Boolean).length / n;
    if (ratio > this.threshold) {
      this.consecutive++;
      this.total++;
      this.reset(this.backoffTo);
      return { event: this.consecutive >= this.maxBackoffs ? 'abort' : 'backoff', ratio, n, consecutive: this.consecutive };
    }
    if (this.multiplier < 1) {
      this.consecutive = 0;
      this.reset(1);
      return { event: 'recover', ratio, n };
    }
    return null;
  }

  reset(multiplier) {
    this.multiplier = multiplier;
    this.samples = [];
    this.epoch++;
  }
}
