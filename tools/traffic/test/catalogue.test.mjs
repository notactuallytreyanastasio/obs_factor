import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  avoided, avoidIndex, avoidMatcher, buildPlan, loadCatalogue, pathVariants, pickSite, pickTarget, UsageError, validateCatalogue,
} from '../lib/catalogue.mjs';
import { mulberry32 } from '../lib/shape.mjs';

const FIXTURE = fileURLToPath(new URL('./fixture.json', import.meta.url));
const cat = loadCatalogue(FIXTURE);

test('selection by --site groups every entry sharing the id', () => {
  const plan = buildPlan(cat, { site: ['blimp-blog'] });
  assert.equal(plan.sites.length, 1);
  assert.deepEqual(plan.sites[0].hosts, ['bobbby.online', 'www.bobbby.online']);
  assert.ok(plan.sites[0].targets.some((t) => t.host === 'www.bobbby.online'));
});

test('selection: comma lists, --host, --kind, --path-match, --all', () => {
  assert.deepEqual(buildPlan(cat, { site: ['blinks,soldat'] }).sites.map((s) => s.id), ['soldat', 'blinks']);
  // a host shared by two node ids selects both
  assert.deepEqual(buildPlan(cat, { host: ['bobbby.online'] }).sites.map((s) => s.id), ['blimp-blog', 'soldat']);
  // --site and --host together must both match
  const both = buildPlan(cat, { site: ['blimp-blog'], host: ['www.bobbby.online'] });
  assert.deepEqual(both.sites[0].targets.map((t) => t.host), ['www.bobbby.online']);
  const api = buildPlan(cat, { all: true, kind: ['api'] });
  assert.ok(api.sites.every((s) => s.targets.every((t) => t.kind === 'api')));
  assert.deepEqual(api.sites.map((s) => s.id), ['blimp-blog', 'blinks']);
  const arena = buildPlan(cat, { all: true, pathMatch: '/arena' });
  assert.deepEqual(arena.sites.map((s) => s.id), ['soldat']);
  assert.equal(buildPlan(cat, { all: true }).sites.length, 4);
});

test('selection errors: nothing chosen, unknown id, host not in catalogue, unknown kind', () => {
  assert.throws(() => buildPlan(cat, {}), /--site <id>, --host <hostname> or --all/);
  assert.throws(() => buildPlan(cat, { site: ['nope'] }), /unknown site id "nope"/);
  assert.throws(() => buildPlan(cat, { host: ['evil.example'] }), /not in the catalogue/);
  assert.throws(() => buildPlan(cat, { all: true, kind: ['post'] }), /unknown kind/);
  assert.throws(() => buildPlan(cat, { all: true, pathMatch: 'zzz' }), /nothing selected/);
});

test('rate split: even by default, --weights skews it, unknown weight ids refused', () => {
  const even = buildPlan(cat, { site: ['blimp-blog', 'blinks'] });
  assert.deepEqual(even.sites.map((s) => s.share), [0.5, 0.5]);
  const skew = buildPlan(cat, { site: ['blimp-blog', 'blinks'], weights: 'blimp-blog=3,blinks=1' });
  assert.deepEqual(skew.sites.map((s) => s.share), [0.75, 0.25]);
  const partial = buildPlan(cat, { site: ['blimp-blog', 'blinks', 'soldat'], weights: 'blinks=2' });
  assert.deepEqual(partial.sites.map((s) => s.share), [0.25, 0.25, 0.5]);
  assert.throws(() => buildPlan(cat, { site: ['blinks'], weights: 'soldat=2' }), /not among the selected/);
  assert.throws(() => buildPlan(cat, { site: ['blinks'], weights: 'blinks=0' }), /bad --weights/);
});

test('weighted picking follows site shares and path weights', () => {
  const plan = buildPlan(cat, { site: ['blimp-blog', 'blinks'], weights: 'blimp-blog=3,blinks=1' });
  const r = mulberry32(42);
  const sites = {};
  const paths = {};
  for (let i = 0; i < 20000; i++) {
    const s = pickSite(plan, r());
    sites[s.id] = (sites[s.id] ?? 0) + 1;
    if (s.id === 'blimp-blog') { const t = pickTarget(s, r()); paths[t.host + t.path] = (paths[t.host + t.path] ?? 0) + 1; }
  }
  assert.ok(Math.abs(sites['blimp-blog'] / 20000 - 0.75) < 0.02, JSON.stringify(sites));
  // blimp-blog weights: / 5, /posts 3, /app.css 1, /api/health 1, /nope-404 1, www / 1  (total 12; avoided path dropped)
  const n = sites['blimp-blog'];
  assert.ok(Math.abs(paths['bobbby.online/'] / n - 5 / 12) < 0.02, JSON.stringify(paths));
  assert.ok(Math.abs(paths['bobbby.online/posts'] / n - 3 / 12) < 0.02);
  assert.equal(paths['bobbby.online/dtree-ai/listed-by-mistake'], undefined);
});

test('avoid: catalogue paths that match are dropped with a warning', () => {
  const plan = buildPlan(cat, { site: ['blimp-blog'] });
  assert.ok(!plan.sites[0].targets.some((t) => t.path.startsWith('/dtree-ai')));
  assert.match(plan.warnings.join('\n'), /dropped bobbby\.online\/dtree-ai\/listed-by-mistake/);
});

test('avoid: an explicit --path that matches is refused, including disguised spellings', () => {
  for (const p of ['/dtree-ai/x', '/dtree-ai', '/DTREE-AI/x', '/dtree%2Dai/x', '/%64tree-ai/x', '/a/../dtree-ai/x',
    '/dtree-ai/x?q=1', '/./dtree-ai/', '/admin', '/admin/', '/admin?x=1']) {
    assert.throws(() => buildPlan(cat, { site: ['blimp-blog'], path: [p] }), UsageError, p);
  }
  // the avoid list of another entry on the same host applies too (path routes share a server)
  assert.throws(() => buildPlan(cat, { site: ['blimp-blog'], path: ['/arena/admin/reset'] }), /avoid pattern \/arena\/admin\*/);
  assert.throws(() => buildPlan(cat, { site: ['soldat'], path: ['/dtree-ai/q'] }), /avoid pattern/);
  // but not on a different host
  assert.doesNotThrow(() => buildPlan(cat, { site: ['blinks'], path: ['/dtree-ai/q'] }));
  assert.doesNotThrow(() => buildPlan(cat, { site: ['blimp-blog'], path: ['/administrator-guide', '/dtree-aix'] }));
});

test('explicit paths must be plain absolute paths (no URLs, no //host)', () => {
  for (const p of ['http://evil.example/', '//evil.example/x', 'relative', '/a b', '/x\\y']) {
    assert.throws(() => buildPlan(cat, { site: ['blinks'], path: [p] }), /plain absolute path/, p);
  }
});

test('avoidMatcher and pathVariants basics', () => {
  const m = avoidMatcher('/dtree-ai/*');
  assert.ok(m('/dtree-ai/') && m('/dtree-ai/a/b') && m('/dtree-ai'));
  assert.ok(!m('/dtree-aix') && !m('/x/dtree-ai/'));
  assert.ok(avoidMatcher('/search?q=*')('/search?q=hello'));
  assert.ok(!avoidMatcher('/search?q=*')('/searchXq=hello'), '? is literal');
  assert.ok(pathVariants('//dtree-ai//x').includes('/dtree-ai/x'));
  const idx = avoidIndex(cat);
  assert.equal(avoided(idx, 'bobbby.online', '/fine'), null);
  assert.equal(avoided(idx, 'bobbby.online', '/dtree-ai/a').pattern, '/dtree-ai/*');
});

test('validation rejects bad catalogues', () => {
  const site = (over) => ({ sites: [{ id: 'a', host: 'a.test', paths: [{ path: '/' }], ...over }] });
  assert.doesNotThrow(() => validateCatalogue(site({})));
  assert.throws(() => validateCatalogue({}), /non-empty "sites"/);
  assert.throws(() => validateCatalogue(site({ host: 'http://a.test' })), /bad "host"/);
  assert.throws(() => validateCatalogue(site({ scheme: 'ftp' })), /scheme/);
  assert.throws(() => validateCatalogue(site({ paths: [{ path: 'x' }] })), /plain absolute path/);
  assert.throws(() => validateCatalogue(site({ paths: [{ path: '/', kind: 'post' }] })), /kind/);
  assert.throws(() => validateCatalogue(site({ paths: [{ path: '/', weight: -1 }] })), /weight/);
  assert.throws(() => validateCatalogue(site({ avoid: [{ pattern: 'x' }] })), /pattern/);
  assert.throws(() => loadCatalogue('/nonexistent/targets.json'), /cannot read catalogue/);
});

test('visit selection keeps only page paths', () => {
  const plan = buildPlan(cat, { all: true, visit: true });
  assert.ok(plan.sites.every((s) => s.targets.every((t) => t.kind === 'page')));
});
