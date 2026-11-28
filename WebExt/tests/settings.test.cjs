const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const read = file => fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
const plain = value => JSON.parse(JSON.stringify(value));
function config() {
  const context = vm.createContext({ URL });
  vm.runInContext(read('config.js'), context);
  return context.Unscroll;
}

test('defaults and legacy migration preserve each site’s effective blocking', () => {
  const ns = config();
  for (const site of ns.SITES) {
    assert.equal(ns.DEFAULT_TOGGLES[site].all, site === 'tiktok');
    const allOff = Object.fromEntries(Object.keys(ns.DEFAULT_TOGGLES[site]).map(feature => [feature, false]));
    for (const [value, expected] of [
      ['off', { shorts: false, feed: false, all: false }],
      ['shorts', { shorts: ['youtube', 'instagram', 'facebook', 'x'].includes(site), feed: false, all: false }],
      ['feed', { shorts: ['youtube', 'instagram', 'facebook', 'x'].includes(site), feed: ['instagram', 'facebook'].includes(site), all: false }],
      ['all', { ...plain(ns.DEFAULT_TOGGLES[site]), all: true }],
      [false, { shorts: false, feed: false, all: false }]
    ]) assert.deepEqual(plain(ns.normalizeSiteSettings(site, value)), { ...allOff, ...expected });
  }
  for (const shorts of [false, true]) for (const feed of [false, true]) for (const all of [false, true]) {
    const flags = { shorts, feed, all };
    assert.deepEqual(plain(ns.normalizeSiteSettings('instagram', flags)), { ...flags, stories: false, following: false, hideSuggestions: false });
  }
});

test('new networks start with one light filter and honor stored choices', () => {
  const ns = config();
  for (const [site, feature] of Object.entries({threads: 'following', reddit: 'hidePromoted', linkedin: 'hidePromoted'})) {
    const initial = ns.normalizeSiteSettings(site, undefined);
    assert.deepEqual(Object.keys(initial).filter(key => initial[key]), [feature]);
    assert.equal(ns.normalizeSiteSettings(site, { [feature]: false })[feature], false);
    assert.equal(ns.normalizeSiteSettings(site, { all: true }).all, true);
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
    setTimeout(fn, delay) { const timer = { fn, delay }; timers.push(timer); return timer; },
    clearTimeout(timer) { timer.cancelled = true; },
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
    async update(flags, preferences = {}) { Object.assign(state, preferences); state.toggles[site] = flags; messageListener({ type: 'unscroll-state-updated' }); await Promise.resolve(); }
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

test('Instagram preserves the existing optional Stories nudge under Infinite Feed', async () => {
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

test('Instagram Stories hard block is independent, live, and covers direct and SPA routes', async () => {
  const h = contentHarness('instagram', { shorts: false, feed: false, all: false, stories: false }, '/stories/person/123/');
  await h.start();
  assert.equal(h.redirects.length, 0);
  await h.update({ shorts: false, feed: false, all: false, stories: true });
  assert.equal(h.redirects.at(-1), 'https://instagram.com/');
  assert.match(h.elements.get('unscroll-instagram-style').textContent, /stories/);
  assert.doesNotMatch(h.elements.get('unscroll-instagram-style').textContent, /reels/);
  assert.equal(h.context.Unscroll.content.featureEnabled('instagram', 'stories'), true);
  const tick = h.timers.find(timer => timer.delay === 400).fn;
  h.context.location.pathname = '/stories/other/456/';
  h.context.location.href = 'https://instagram.com/stories/other/456/';
  const before = h.redirects.length;
  tick();
  assert.equal(h.redirects.length, before + 1);
  await h.update({ shorts: false, feed: false, all: false, stories: false, following: false, hideSuggestions: false });
  assert.equal(h.elements.has('unscroll-instagram-style'), false);
  const after = h.redirects.length;
  h.context.location.href += '?next=1';
  tick();
  assert.equal(h.redirects.length, after);
  for (const pathname of ['/', '/person/', '/direct/inbox/', '/reel/123/', '/stories_archive/']) {
    const page = contentHarness('instagram', { shorts: false, feed: false, all: false, stories: true }, pathname);
    await page.start();
    assert.equal(page.redirects.length, 0, pathname);
  }
  await h.update({ shorts: false, feed: false, all: true, stories: true });
  assert.match(h.redirects.at(-1), /blocked.html/);
  assert.equal(h.context.Unscroll.content.featureEnabled('instagram', 'stories'), false);
});

test('background navigation enforces only the selected features', async () => {
  let onNavigate;
  const updates = [];
  const ns = config();
  let state;
  ns.getStateCached = async () => state;
  ns.getStateFresh = async () => state;
  ns.setOnboardingDone = async () => {};
  const context = vm.createContext({ URL, Unscroll: ns, browser: {
    runtime: { getURL: name => `safari-web-extension://test/${name}`, onInstalled: { addListener() {} }, onMessage: { addListener() {} } },
    webNavigation: { onBeforeNavigate: { addListener(fn) { onNavigate = fn; } } },
    tabs: { update(id, change) { updates.push(change.url); } }
  } });
  vm.runInContext(read('background.js'), context);
  state = { toggles: { instagram: { shorts: false, feed: false, all: false, stories: true } }, rules: ns.DEFAULT_RULES };
  await onNavigate({ frameId: 0, tabId: 1, url: 'https://www.instagram.com/stories/person/123/?next=1' });
  assert.equal(updates.at(-1), 'https://www.instagram.com/');
  const storiesCount = updates.length;
  state.toggles.instagram.stories = false;
  await onNavigate({ frameId: 0, tabId: 1, url: 'https://www.instagram.com/stories/person/123/' });
  assert.equal(updates.length, storiesCount);
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
  const storage = { cachedAt: Date.now(), cachedState: { settingsVersion: 4, toggles: { instagram: 'off', reddit: { hidePromoted: false } } } };
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
  assert.equal(state.toggles.reddit.hidePromoted, true);
  assert.deepEqual(plain(state.toggles.instagram), { shorts: false, feed: true, all: false, stories: false, following: false, hideSuggestions: false });
  response = null;
  state = await ns.getStateFresh();
  assert.deepEqual(plain(state.toggles.instagram), { shorts: false, feed: true, all: false, stories: false, following: false, hideSuggestions: false });
  await ns.setToggle('instagram', 'all', true);
  assert.deepEqual(plain(sent.at(-1)), { action: 'setToggle', site: 'instagram', feature: 'all', enabled: true });
});

test('five-site stored rules remain valid with the added platform settings', async () => {
  const context = vm.createContext({ URL, chrome: {} });
  vm.runInContext(read('config.js') + read('rules-loader.js'), context);
  const ns = context.Unscroll;
  const remote = plain(ns.DEFAULT_RULES);
  remote.instagram.hideSelectors.push('.from-stored-rules');
  assert.ok(ns.isValidRules(remote));
  delete remote.x;
  assert.equal(ns.isValidRules(remote), false);
});

test('feed destinations preserve explicit navigation and full-site blocking', () => {
  const context = vm.createContext({ URL });
  vm.runInContext(read('config.js') + read('content/feed-filters.js'), context);
  const ns = context.Unscroll;
  const flags = { following: true, facebookFeeds: true, networkFeed: true, oldReddit: true };
  for (const [url, expected] of [
    ['https://www.instagram.com/?utm_source=link', '/?variant=following'],
    ['https://www.instagram.com/?variant=favorites', null],
    ['https://www.instagram.com/direct/inbox/', null],
    ['https://www.facebook.com/', '/?filter=all&sk=h_chr'],
    ['https://m.facebook.com/home.php', '/?filter=all&sk=h_chr'],
    ['https://www.facebook.com/?filter=friends&sk=h_chr', null],
    ['https://www.facebook.com/?sk=groups', null],
    ['https://www.tiktok.com/de-DE/', '/following'],
    ['https://www.tiktok.com/foryou/', '/following'],
    ['https://www.tiktok.com/following', null],
    ['https://www.tiktok.com/@user/video/123', null],
    ['https://www.threads.net/', '/following'],
    ['https://threads.com/@user/post/123', null],
    ['https://www.linkedin.com/feed/foryou/', '/feed/network/'],
    ['https://www.linkedin.com/feed/', null],
    ['https://www.reddit.com/r/test/comments/1/?sort=new#comment', 'https://old.reddit.com/r/test/comments/1/?sort=new#comment'],
    ['https://old.reddit.com/r/test', null],
    ['https://oauth.reddit.com/', null],
    ['https://www.x.com/home', null],
    ['https://instagram.com.attacker.invalid/', null]
  ]) {
    const target = new URL(url);
    const site = ns.siteForURL(url);
    assert.equal(ns.feedFilters.feedDestination(site, target, flags), expected, url);
    assert.equal(ns.feedFilters.feedDestination(site, target, {}), null);
    assert.equal(ns.feedFilters.feedDestination(site, target, { ...flags, all: true }), null);
    if (expected) assert.equal(ns.feedFilters.feedDestination(site, new URL(expected, url), flags), null);
  }
});

test('saved site filters apply immediately with a cached snapshot from the previous build', async () => {
  const flags = { following: true, hideSuggestions: true, feed: true };
  const page = contentHarness('instagram', flags);
  await page.start();
  await page.update(flags, { feedPauseUntil: Date.now() / 1000 + 3600 });
  for (const key of Object.keys(flags)) {
    assert.equal(page.context.Unscroll.content.featureEnabled('instagram', key), true, key);
  }
});
