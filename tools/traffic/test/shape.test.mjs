import assert from 'node:assert/strict';
import { test } from 'node:test';
import { checkRps, Health, makeShape, mulberry32, Pacer, resolveMaxRps } from '../lib/shape.mjs';
import { maxInAnyWindow } from './helpers.mjs';

function arrivals(shape, seconds, { seed = 1, maxRps = 100 } = {}) {
  const p = new Pacer({ shape, random: mulberry32(seed), maxRps });
  const out = [];
  for (let t = p.next(0); t < seconds; t = p.next(t)) out.push(t);
  return out;
}

test('cap: 20 by default, raised only by --i-know-max-rps, never above 100', () => {
  assert.equal(resolveMaxRps(undefined), 20);
  assert.equal(resolveMaxRps('50'), 50);
  assert.equal(resolveMaxRps(100), 100);
  assert.throws(() => resolveMaxRps(101), /absolute ceiling of 100/);
  assert.throws(() => resolveMaxRps('lots'), /positive number/);
  assert.doesNotThrow(() => checkRps(20, 20));
  assert.throws(() => checkRps(21, 20), /--i-know-max-rps/);
  assert.throws(() => checkRps(60, 50), /cap of 50/);
  assert.throws(() => checkRps(0, 20), /positive/);
  assert.throws(() => checkRps(Infinity, 100), /positive/);
});

test('steady: Poisson arrivals average the rate, and are not a metronome', () => {
  const a = arrivals(makeShape('steady', 5), 200);
  assert.ok(Math.abs(a.length - 1000) < 80, `got ${a.length}`);
  const gaps = a.slice(1).map((t, i) => t - a[i]);
  const mean = gaps.reduce((x, y) => x + y, 0) / gaps.length;
  const sd = Math.sqrt(gaps.reduce((x, g) => x + (g - mean) ** 2, 0) / gaps.length);
  // exponential gaps: sd ~= mean (a metronome would have sd 0)
  assert.ok(sd / mean > 0.8 && sd / mean < 1.2, `cv ${sd / mean}`);
});

test('hard cap: never more than floor(maxRps) starts in any 1 s window, whatever the randomness', () => {
  const a = arrivals(makeShape('steady', 20), 120, { maxRps: 20 });
  assert.ok(maxInAnyWindow(a) <= 20, `max ${maxInAnyWindow(a)}`);
  assert.ok(a.length > 2000, `still close to the rate: ${a.length}`);
  // a pathological random source (always ~0 gap) is still held to the cap
  const p = new Pacer({ shape: makeShape('steady', 20), random: () => 0, maxRps: 20 });
  const b = [];
  for (let t = p.next(0); t < 10; t = p.next(t)) b.push(t);
  assert.ok(maxInAnyWindow(b) <= 20 && b.length <= 200, `${b.length} ${maxInAnyWindow(b)}`);
});

test('burst: arrivals only inside the bursts, at the peak rate', () => {
  const shape = makeShape('burst', 10, { period: 20, burstLen: 3 });
  const a = arrivals(shape, 400);
  assert.ok(a.every((t) => t % 20 < 3), 'nothing between bursts');
  assert.ok(Math.abs(a.length - 600) < 70, `20 bursts x 3 s x 10/s ~ 600, got ${a.length}`);
  assert.equal(shape.average(400).toFixed(2), '1.50');
});

test('wave: 10% of the rate at the trough, 100% at the crest', () => {
  const shape = makeShape('wave', 10, { period: 60 });
  assert.ok(Math.abs(shape.rateAt(0) - 1) < 1e-9);
  assert.equal(Math.round(shape.rateAt(30) * 1000) / 1000, 10);
  const a = arrivals(shape, 6000, { seed: 7 });
  const cycles = 100;
  const inPhase = (lo, hi) => a.filter((t) => (t % 60) >= lo && (t % 60) < hi).length / cycles / (hi - lo);
  const trough = (inPhase(0, 3) + inPhase(57, 60)) / 2;
  const crest = inPhase(28.5, 31.5);
  assert.ok(trough > 0.6 && trough < 1.8, `trough ${trough}/s`);
  assert.ok(crest > 9 && crest < 11, `crest ${crest}/s`);
  assert.ok(Math.abs(shape.average(60) - 5.5) < 0.01);
});

test('scenario validation', () => {
  assert.throws(() => makeShape('flood', 1), /unknown --scenario/);
  assert.throws(() => makeShape('burst', 1, { period: 5, burstLen: 5 }), /--burst-len/);
  assert.equal(makeShape('visit', 3).rateAt(99), 3);
});

test('pacer multiplier slows arrivals to 10%', () => {
  const p = new Pacer({ shape: makeShape('steady', 10), random: mulberry32(3), maxRps: 20 });
  p.multiplier = 0.1;
  let n = 0;
  for (let t = p.next(0); t < 500; t = p.next(t)) n++;
  assert.ok(Math.abs(n - 500) < 70, `got ${n}`);
});

test('health: >30% bad backs off, a healthy window recovers, 3 in a row aborts', () => {
  const ok = { status: 200 }; const bad = { status: 503 };
  const h = new Health();
  for (let i = 0; i < 9; i++) assert.equal(h.record(i < 4 ? bad : ok), null);
  // 4 of 10 bad = 40% > 30%
  assert.deepEqual(h.record(ok).event, 'backoff');
  assert.equal(h.multiplier, 0.1);
  const staleEpoch = h.epoch - 1;
  assert.equal(h.record(bad, staleEpoch), null, 'responses to requests from before the back-off are ignored');
  let ev;
  for (let i = 0; i < 10; i++) ev = h.record(ok) ?? ev;
  assert.equal(ev.event, 'recover');
  assert.equal(h.multiplier, 1);
  // 3 consecutive back-offs -> abort; 429 and connection errors count as bad
  const events = [];
  for (const r of [{ status: 429 }, { status: 0, error: 'ECONNREFUSED' }, { status: 500 }]) {
    for (let i = 0; i < 10; i++) { const e = h.record(r); if (e) events.push(e.event); }
  }
  assert.deepEqual(events, ['backoff', 'backoff', 'abort']);
  // exactly 30% is not "more than 30%"
  const h2 = new Health();
  const out = [];
  for (let i = 0; i < 50; i++) out.push(h2.record(i % 10 >= 7 ? bad : ok));
  assert.ok(out.every((x) => x === null));
  // 404 is not a bad sign
  assert.ok(!Health.isBad({ status: 404 }) && Health.isBad({ status: 429 }) && Health.isBad({ status: 502 }));
});
