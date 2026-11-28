const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const read = file => fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
const plain = value => JSON.parse(JSON.stringify(value));

async function harness({ feed = true, shorts = false, all = false, hideHomeFeed = false, route = '/',
  host = 'www.youtube.com', scrollY = 0, loading = false } = {}) {
  let flags = { feed, shorts, all, hideHomeFeed }, messageListener;
  const elements = new Map(), timers = new Map(), redirects = [];
  function eventTarget() {
    const listeners = new Map();
    return {
      addEventListener(name, fn) {
        if (!listeners.has(name)) listeners.set(name, new Set());
        listeners.get(name).add(fn);
      },
      removeEventListener(name, fn) { listeners.get(name)?.delete(fn); },
      emit(name) { for (const fn of listeners.get(name) || []) fn(); }
    };
  }
  function element() {
    const attrs = new Map(), children = new Map();
    return { ...eventTarget(), style: {}, textContent: '',
      setAttribute(key, value) { attrs.set(key, value); },
      getAttribute(key) { return attrs.get(key); },
      appendChild(el) { elements.set(el.id, el); el.parentNode = this; },
      removeChild(el) { elements.delete(el.id); el.parentNode = null; },
      remove() { this.parentNode?.removeChild(this); },
      querySelector(selector) {
        if (!children.has(selector)) children.set(selector, element());
        return children.get(selector);
      },
      focus() { this.focused = true; }
    };
  }
  const root = element(), body = element();
  root.style.overflow = 'clip';
  body.style.overflow = 'auto';
  const location = { replace(url) { redirects.push(url); } };
  function navigate(route) {
    const url = new URL(route, `https://${host}`);
    Object.assign(location, { href: url.href, origin: url.origin, pathname: url.pathname, search: url.search });
  }
  navigate(route);
  const window = { ...eventTarget(), innerHeight: 800, scrollY, stop() {},
    scrollTo(options) { this.scrollY = options.top; } };
  const document = { ...eventTarget(), documentElement: root, body,
    readyState: loading ? 'loading' : 'complete', visibilityState: 'visible',
    getElementById: id => elements.get(id), createElement: element, querySelectorAll: () => [] };
  const context = vm.createContext({ window, document, location,
    setInterval(fn, delay) { const token = {}; timers.set(token, { fn, delay }); return token; },
    clearInterval(token) { timers.delete(token); },
    MutationObserver: class { observe() {} },
    browser: { runtime: {
      getURL: file => `safari-web-extension://test/${file}`,
      sendMessage(_, cb) { cb({ toggles: { youtube: flags } }); },
      onMessage: { addListener(fn) { messageListener = fn; } }
    } }
  });
  vm.runInContext(read('config.js'), context);
  context.Unscroll.i18n = { t: key => `localized:${key}`, setLocale(el) { el.lang = 'ru'; } };
  for (const file of ['content/common.js', 'content/youtube.js']) vm.runInContext(read(file), context);
  await Promise.resolve();
  return { context, window, document, root, body, elements, redirects, navigate,
    overlay: () => elements.get('unscroll-block-overlay'),
    tick() { for (const timer of timers.values()) if (timer.delay === 400) timer.fn(); },
    async update(next) {
      flags = { ...flags, ...next };
      messageListener({ type: 'unscroll-state-updated' });
      await Promise.resolve();
    }
  };
}

for (const host of ['www.youtube.com', 'm.youtube.com']) {
  test(`${host}: blocks at exactly four window heights, with a localized home action`, async () => {
    const h = await harness({ host, route: '/?app=desktop' });
    h.window.scrollY = 3199;
    h.window.emit('scroll');
    assert.equal(h.overlay(), undefined);
    h.window.scrollY = 3200;
    h.window.emit('scroll');
    const overlay = h.overlay();
    assert.ok(overlay);
    assert.equal(overlay.lang, 'ru');
    assert.equal(overlay.querySelector('h1').textContent, 'localized:feedTitle');
    assert.equal(overlay.querySelector('.uo-lede').textContent, 'localized:feedSubtitle');
    assert.equal(overlay.querySelector('.uo-btn').textContent, 'localized:backHome');
    assert.equal(overlay.querySelector('.uo-btn').focused, true);
    assert.match(h.elements.get('unscroll-youtube-scroll-lock').textContent, /overflow:hidden!important/);
    h.window.scrollY = 0;
    h.tick();
    assert.equal(h.overlay(), overlay, 'layout changes cannot dismiss a reached limit');
    overlay.querySelector('.uo-btn').emit('click');
    assert.equal(h.context.location.href, '/');
    assert.equal(h.window.scrollY, 0);
    assert.equal(h.overlay(), undefined);
    assert.equal(h.elements.has('unscroll-youtube-scroll-lock'), false);
    assert.equal(h.root.style.overflow, 'clip');
    assert.equal(h.body.style.overflow, 'auto');
    h.tick();
    assert.equal(h.overlay(), undefined, 'home action resets the visit');
    h.window.scrollY = 3200;
    h.window.emit('scroll');
    assert.ok(h.overlay(), 'a fresh four screens blocks again');
  });
}

for (const route of ['/results?search_query=test', '/feed/subscriptions', '/feed/trending',
  '/@creator', '/channel/123', '/watch?v=123', '/shorts/123', '/playlist?list=123']) {
  test(`does not limit ${route}`, async () => {
    const h = await harness({ route, scrollY: 10000 });
    h.window.emit('scroll');
    h.tick();
    assert.equal(h.overlay(), undefined);
    assert.deepEqual(h.redirects, []);
  });
}

test('late settings and DOM readiness check an already restored scroll position', async () => {
  const h = await harness({ scrollY: 4000, loading: true });
  assert.ok(h.overlay(), 'initial asynchronous state checks the existing position');
  h.document.emit('DOMContentLoaded');
  assert.ok(h.overlay());
});

for (const event of ['yt-navigate-finish', 'popstate', 'pageshow', 'timer']) {
  test(`${event}: leaving home unlocks; returning at a restored offset blocks immediately`, async () => {
    const h = await harness({ scrollY: 4000 });
    const check = () => event === 'timer' ? h.tick() : h.window.emit(event);
    assert.ok(h.overlay());
    h.navigate('/watch?v=123');
    check();
    assert.equal(h.overlay(), undefined);
    assert.equal(h.elements.has('unscroll-youtube-scroll-lock'), false);
    h.navigate('/?persist_gl=1');
    check();
    assert.ok(h.overlay());
    h.navigate('/feed/subscriptions');
    check();
    h.navigate('/');
    h.window.scrollY = 0;
    check();
    assert.equal(h.overlay(), undefined);
    h.window.scrollY = 4000; // Safari may restore after pageshow/popstate.
    h.window.emit('scroll');
    assert.ok(h.overlay());
  });
}

test('live feed changes check immediately, preserve Shorts, and defer to whole-site blocking', async () => {
  const h = await harness({ feed: false, shorts: true, scrollY: 4000 });
  assert.equal(h.overlay(), undefined);
  assert.ok(h.elements.has('unscroll-youtube-style'));
  await h.update({ feed: true });
  assert.ok(h.overlay());
  await h.update({ feed: false });
  assert.equal(h.overlay(), undefined);
  assert.ok(h.elements.has('unscroll-youtube-style'));
  await h.update({ feed: true, shorts: false });
  assert.ok(h.overlay());
  assert.equal(h.elements.has('unscroll-youtube-style'), false);
  await h.update({ all: true });
  assert.equal(h.overlay(), undefined);
  assert.equal(h.elements.has('unscroll-youtube-scroll-lock'), false);
  assert.match(h.redirects.at(-1), /blocked.html\?host=youtube$/);
  await h.update({ all: false });
  assert.ok(h.overlay(), 'whole-site flag preserves the feed choice');
});

test('Shorts redirects remain independent of the home feed limit', async () => {
  const h = await harness({ route: '/shorts/123' });
  assert.equal(h.redirects.length, 0);
  await h.update({ shorts: true });
  assert.equal(h.redirects.at(-1), 'https://www.youtube.com/watch?v=123');
  await h.update({ feed: false });
  assert.ok(h.elements.has('unscroll-youtube-style'));
  assert.equal(h.overlay(), undefined);
});

test('resize recalculates the threshold and never releases an existing block', async () => {
  const h = await harness({ scrollY: 3000 });
  assert.equal(h.overlay(), undefined);
  h.window.innerHeight = 700;
  h.window.emit('resize');
  assert.ok(h.overlay());
  h.window.innerHeight = 1000;
  h.window.emit('resize');
  assert.ok(h.overlay());
});

test('YouTube defaults, missing flags and legacy modes never opt into feed blocking', async () => {
  const h = await harness();
  const ns = h.context.Unscroll;
  assert.deepEqual(plain(ns.SITE_FEATURES.youtube), ['shorts', 'hideHomeFeed', 'feed', 'autoplayOff', 'hideRelated', 'all']);
  for (const value of [undefined, 'off', 'shorts', 'feed', 'all', true, false, { shorts: false, all: true }]) {
    assert.equal(ns.normalizeSiteSettings('youtube', value).feed, false);
    assert.equal(ns.normalizeSiteSettings('youtube', value).hideHomeFeed, false);
  }
  for (const shorts of [false, true]) for (const feed of [false, true]) for (const all of [false, true]) for (const hideHomeFeed of [false, true]) {
    const flags = { shorts, feed, all, hideHomeFeed };
    assert.deepEqual(plain(ns.normalizeSiteSettings('youtube', flags)), { ...flags, autoplayOff: false, hideRelated: false });
  }
});

for (const host of ['www.youtube.com', 'm.youtube.com']) {
  for (const event of ['yt-navigate-finish', 'popstate', 'pageshow', 'timer']) {
    test(`${host}/${event}: hidden home redirects to subscriptions and hides Home on every route`, async () => {
      const h = await harness({ host, hideHomeFeed: true, route: '/?app=desktop', scrollY: 4000 });
      const style = () => h.elements.get('unscroll-youtube-home-style');
      const check = () => event === 'timer' ? h.tick() : h.window.emit(event);
      assert.ok(style());
      assert.equal(h.overlay(), undefined);
      for (const route of ['/results?search_query=test', '/feed/subscriptions', '/feed/library', '/@creator', '/watch?v=123']) {
        h.navigate(route); check();
        assert.ok(style(), route);
        assert.doesNotMatch(style().textContent, /ytm-browse ytm-rich-grid-renderer/, 'subscriptions grid remains visible');
        assert.equal(h.overlay(), undefined, route);
        h.navigate('/?persist_gl=1'); check();
        assert.ok(style());
      }
      assert.ok(h.redirects.length > 0);
      assert.ok(h.redirects.every(url => url === `https://${host}/feed/subscriptions`));
      const count = h.redirects.length;
      h.tick(); h.tick();
      assert.equal(h.redirects.length, count, 'slow home navigation is not restarted');
      await h.update({ hideHomeFeed: false });
      assert.equal(style(), undefined);
      assert.ok(h.overlay(), 'saved scroll limit resumes');
      await h.update({ hideHomeFeed: true });
      assert.ok(style());
      assert.equal(h.overlay(), undefined);
      assert.equal(h.elements.has('unscroll-youtube-scroll-lock'), false);
      await h.update({ shorts: true });
      assert.ok(style());
      assert.ok(h.elements.has('unscroll-youtube-style'));
      await h.update({ all: true });
      assert.equal(style(), undefined);
      assert.match(h.redirects.at(-1), /blocked.html\?host=youtube$/);
      await h.update({ all: false, feed: false, shorts: false });
      assert.ok(style(), 'whole-site setting preserves home choice');
      await h.update({ hideHomeFeed: false });
      assert.equal(style(), undefined);
      assert.equal(h.overlay(), undefined);
    });
  }
}

test('home redirect never overrides whole-site blocking or the disabled setting', async () => {
  for (const hideHomeFeed of [false, true]) {
    const h = await harness({ hideHomeFeed, all: true });
    assert.deepEqual(h.redirects, ['safari-web-extension://test/blocked.html?host=youtube']);
  }
  const h = await harness({ hideHomeFeed: false });
  assert.deepEqual(h.redirects, []);
  await h.update({ hideHomeFeed: true });
  assert.deepEqual(h.redirects, ['https://www.youtube.com/feed/subscriptions']);
});
