const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const read = file => fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
const plain = value => JSON.parse(JSON.stringify(value));
function config() {
  const context = vm.createContext({});
  vm.runInContext(read('config.js'), context);
  return context.Unscroll;
}

test('defaults and legacy migration preserve each site’s effective blocking', () => {
  const ns = config();
  for (const site of ns.SITES) {
    assert.equal(ns.DEFAULT_TOGGLES[site].all, site === 'tiktok');
    for (const [value, expected] of [
      ['off', { shorts: false, feed: false, all: false }],
      ['shorts', { shorts: site !== 'tiktok', feed: false, all: false }],
      ['feed', { shorts: site !== 'tiktok', feed: ['instagram', 'facebook'].includes(site), all: false }],
      ['all', { ...plain(ns.DEFAULT_TOGGLES[site]), all: true }],
      [false, { shorts: false, feed: false, all: false }]
    ]) assert.deepEqual(plain(ns.normalizeSiteSettings(site, value)), expected);
  }
  for (const shorts of [false, true]) for (const feed of [false, true]) for (const all of [false, true]) {
    const flags = { shorts, feed, all };
    assert.deepEqual(plain(ns.normalizeSiteSettings('instagram', flags)), flags);
  }
});

function contentHarness(site, flags, pathname = '/') {
  let state = { toggles: { [site]: flags } };
  let messageListener;
  const attrs = new Map(), elements = new Map(), listeners = new Map(), timers = [];
  const redirects = [];
  const root = {
    style: {},
    setAttribute(key, value) { attrs.set(key, value); },
    getAttribute(key) { return attrs.get(key); },
    appendChild(el) { elements.set(el.id, el); el.parentNode = root; },
    removeChild(el) { elements.delete(el.id); }
  };
  const context = vm.createContext({
    location: { pathname, search: '', href: `https://${site}.com${pathname}`, origin: `https://${site}.com`, replace(url) { redirects.push(url); } },
    document: { documentElement: root, body: root, readyState: 'complete', visibilityState: 'visible',
      getElementById: id => elements.get(id), createElement: () => ({
        setAttribute() {}, querySelector: () => ({ setAttribute() {}, addEventListener() {} }),
        remove() { elements.delete(this.id); }
      }), querySelectorAll: () => [] },
    window: { innerHeight: 800, innerWidth: 400, scrollY: 0, stop() {},
      addEventListener(event, fn) { listeners.set(event, fn); },
      removeEventListener(event) { listeners.delete(event); } },
    setInterval(fn, delay) { timers.push({ fn, delay }); },
    MutationObserver: class { observe() {} },
    browser: { runtime: {
      getURL: name => `safari-web-extension://test/${name}`,
      sendMessage(_, cb) { cb(state); },
      onMessage: { addListener(fn) { messageListener = fn; } }
    } }
  });
  vm.runInContext(read('config.js'), context);
  context.Unscroll.i18n = { t: key => key, locale: 'en', setLocale() {} };
  vm.runInContext(read('content/common.js'), context);
  return { context, redirects, elements, listeners, timers,
    async start() { context.Unscroll.content.siteContentScript(site); await Promise.resolve(); },
    async update(flags) { state.toggles[site] = flags; messageListener({ type: 'unscroll-state-updated' }); await Promise.resolve(); }
  };
}

for (const site of ['instagram', 'facebook']) {
  test(`${site}: feed alone does not hide or redirect Reels; live changes remove Reels CSS`, async () => {
    const h = contentHarness(site, { shorts: false, feed: true, all: false }, '/reel/123/');
    await h.start();
    assert.equal(h.redirects.length, 0);
    assert.equal(h.elements.size, 0);
    assert.equal(h.context.Unscroll.content.featureEnabled(site, 'feed'), true);
    await h.update({ shorts: true, feed: false, all: false });
    assert.equal(h.redirects.length, 1);
    assert.ok(h.elements.get(`unscroll-${site}-style`).textContent.length);
    assert.equal(h.context.Unscroll.content.featureEnabled(site, 'feed'), false);
    await h.update({ shorts: false, feed: true, all: false });
    assert.equal(h.elements.size, 0);
    assert.equal(h.redirects.length, 1);
    await h.update({ shorts: false, feed: true, all: true });
    assert.match(h.redirects.at(-1), /blocked.html/);
    assert.equal(h.context.Unscroll.content.featureEnabled(site, 'feed'), false);
  });

  test(`${site}: independent feed switch attaches and removes home scrolling guard`, async () => {
    const h = contentHarness(site, { shorts: true, feed: false, all: false });
    vm.runInContext(read(`content/${site}.js`), h.context);
    await Promise.resolve();
    const tick = h.timers.find(timer => timer.delay === 400).fn;
    tick();
    assert.equal(h.listeners.has('scroll'), false);
    await h.update({ shorts: false, feed: true, all: false });
    tick();
    assert.equal(h.listeners.has('scroll'), true);
    h.context.window.scrollY = 4000;
    h.listeners.get('scroll')();
    assert.ok(h.elements.has('unscroll-block-overlay'));
    await h.update({ shorts: true, feed: false, all: false });
    tick();
    assert.equal(h.listeners.has('scroll'), false);
    assert.equal(h.elements.has('unscroll-block-overlay'), false);
  });
}

test('Instagram Stories are controlled by Infinite Feed, independently of Reels', async () => {
  const h = contentHarness('instagram', { shorts: true, feed: false, all: false }, '/stories/person/123/');
  vm.runInContext(read('content/instagram.js'), h.context);
  await Promise.resolve();
  const tick = h.timers.find(timer => timer.delay === 400).fn;
  tick();
  assert.equal(h.listeners.has('wheel'), false);
  await h.update({ shorts: false, feed: true, all: false });
  tick();
  assert.equal(h.listeners.has('wheel'), true);
  await h.update({ shorts: false, feed: false, all: false });
  tick();
  assert.equal(h.listeners.has('wheel'), false);
});

test('background navigation enforces only the selected features', async () => {
  let onNavigate;
  const updates = [];
  const ns = config();
  let state;
  ns.getStateCached = async () => state;
  ns.setOnboardingDone = async () => {};
  const context = vm.createContext({ URL, Unscroll: ns, browser: {
    runtime: { getURL: name => `safari-web-extension://test/${name}`, onInstalled: { addListener() {} }, onMessage: { addListener() {} } },
    webNavigation: { onBeforeNavigate: { addListener(fn) { onNavigate = fn; } } },
    tabs: { update(id, change) { updates.push(change.url); } }
  } });
  vm.runInContext(read('background.js'), context);
  for (const site of ['instagram', 'facebook']) {
    state = { toggles: { [site]: { shorts: false, feed: true, all: false } }, rules: ns.DEFAULT_RULES };
    const nav = { frameId: 0, tabId: 1, url: `https://${site}.com/reel/123/` };
    const count = updates.length;
    await onNavigate(nav);
    assert.equal(updates.length, count);
    state.toggles[site].shorts = true;
    await onNavigate(nav);
    assert.equal(updates.length, count + 1);
    state.toggles[site] = { shorts: false, feed: false, all: true };
    await onNavigate({ ...nav, url: `https://${site}.com/messages/` });
    assert.match(updates.at(-1), /blocked.html/);
  }
});

test('cache migration, transient native failures and per-feature writes preserve choices', async () => {
  const storage = { cachedAt: Date.now(), cachedState: { toggles: { instagram: 'off' } } };
  const sent = [];
  let response = { ok: true, state: { toggles: { instagram: { shorts: false, feed: true, all: false } } } };
  const ns = config();
  storage.cachedState.rules = ns.DEFAULT_RULES;
  const context = vm.createContext({ Unscroll: ns, browser: {
    runtime: { sendNativeMessage(_, payload, cb) { sent.push(payload); cb(response); } },
    storage: { local: { get(_, cb) { cb(storage); }, set(items, cb) { Object.assign(storage, items); cb(); } } }
  } });
  vm.runInContext(read('rules-loader.js'), context);
  let state = await ns.getStateCached();
  assert.equal(sent.length, 1, 'old cache must re-read native settings');
  assert.deepEqual(plain(state.toggles.instagram), { shorts: false, feed: true, all: false });
  response = null;
  state = await ns.getStateFresh();
  assert.deepEqual(plain(state.toggles.instagram), { shorts: false, feed: true, all: false });
  await ns.setToggle('instagram', 'all', true);
  assert.deepEqual(plain(sent.at(-1)), { action: 'setToggle', site: 'instagram', feature: 'all', enabled: true });
});
