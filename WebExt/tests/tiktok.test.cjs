const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const read = file => fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
const plain = value => JSON.parse(JSON.stringify(value));

async function harness({ feed = true, all = false, route = '/',
  host = 'www.tiktok.com', scrollY = 0, loading = false } = {}) {
  let flags = { feed, all }, messageListener;
  const elements = new Map(), timers = new Map(), redirects = [];
  function eventTarget() {
    const listeners = new Map();
    return {
      addEventListener(name, fn) {
        if (!listeners.has(name)) listeners.set(name, new Set());
        listeners.get(name).add(fn);
      },
      removeEventListener(name, fn) { listeners.get(name)?.delete(fn); },
      emit(name, event = {}) { for (const fn of listeners.get(name) || []) fn(event); }
    };
  }
  function element() {
    const attrs = new Map(), children = new Map();
    return { ...eventTarget(), style: {}, textContent: '', scrollTop: 0, clientHeight: 800, clientWidth: 400, scrollHeight: 8000,
      removeAttribute(key) { attrs.delete(key); },
      getClientRects: () => [{}],
      contains(el) { return el === this || [...children.values()].includes(el); },
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
  const root = element(), body = element(), videos = [];
  body.parentElement = root; root.scrollTop = scrollY;
  root.style.overflow = 'clip';
  body.style.overflow = 'auto';
  const location = { replace(url) { redirects.push(url); } };
  function navigate(route) {
    const url = new URL(route, `https://${host}`);
    Object.assign(location, { href: url.href, origin: url.origin, pathname: url.pathname, search: url.search });
  }
  navigate(route);
  const window = { ...eventTarget(), innerHeight: 800, scrollY, stop() {},
    innerWidth: 400, scrollTo(options) { this.scrollY = options.top; root.scrollTop = options.top; } };
  const document = { ...eventTarget(), documentElement: root, scrollingElement: root, body,
    readyState: loading ? 'loading' : 'complete', visibilityState: 'visible',
    getElementById: id => elements.get(id), createElement: element, querySelectorAll: selector => selector === 'video' ? videos : [] };
  const context = vm.createContext({ window, document, location,
    getComputedStyle: node => ({ overflowY: node.style.overflowY || 'auto' }),
    setInterval(fn, delay) { const token = {}; timers.set(token, { fn, delay }); return token; },
    clearInterval(token) { timers.delete(token); },
    MutationObserver: class { observe() {} },
    browser: { runtime: {
      getURL: file => `safari-web-extension://test/${file}`,
      sendMessage(_, cb) { cb({ toggles: { tiktok: flags } }); },
      onMessage: { addListener(fn) { messageListener = fn; } }
    } }
  });
  vm.runInContext(read('config.js'), context);
  context.Unscroll.i18n = { t: key => `localized:${key}`, setLocale(el) { el.lang = 'ru'; } };
  for (const file of ['content/common.js', 'content/tiktok.js']) vm.runInContext(read(file), context);
  await Promise.resolve();
  return { context, window, document, root, body, elements, redirects, navigate,
    scroll(node, top) { node.scrollTop = top; document.emit('scroll', { target: node }); },
    addFeed({ height = 800, width = 400, visible = true } = {}) {
      const scroller = element();
      scroller.clientHeight = height; scroller.clientWidth = width;
      scroller.style.overflowY = 'scroll'; scroller.parentElement = body;
      const video = element(); video.tagName = 'VIDEO'; video.parentElement = scroller;
      video.getClientRects = () => visible ? [{}] : [];
      video.paused = false; video.pause = () => { video.paused = true; };
      videos.push(video);
      return { scroller, video };
    },
    overlay: () => elements.get('unscroll-block-overlay'),
    tick() { for (const timer of timers.values()) if (timer.delay === 400) timer.fn(); },
    async update(next) {
      flags = { ...flags, ...next };
      messageListener({ type: 'unscroll-state-updated' });
      await Promise.resolve();
    }
  };
}

for (const route of ['/', '/foryou', '/following/', '/friends?lang=en']) {
  test(`${route}: blocks after four screens and offers the existing localized home action`, async () => {
    const h = await harness({ route });
    h.scroll(h.root, 3199);
    assert.equal(h.overlay(), undefined);
    h.scroll(h.root, 3200);
    const overlay = h.overlay();
    assert.ok(overlay);
    assert.equal(overlay.lang, 'ru');
    assert.equal(overlay.querySelector('h1').textContent, 'localized:feedTitle');
    assert.equal(overlay.querySelector('.uo-btn').textContent, 'localized:backHome');
    assert.equal(overlay.querySelector('.uo-btn').focused, true);
    h.scroll(h.root, 0);
    assert.equal(h.overlay(), overlay, 'layout shifts cannot release a reached limit');
    overlay.querySelector('.uo-btn').emit('click');
    assert.equal(h.context.location.href, '/');
    assert.equal(h.overlay(), undefined);
    assert.equal(h.root.scrollTop, 0);
    assert.equal(h.root.style.overflow, 'clip');
    assert.equal(h.body.style.overflow, 'auto');
    h.tick();
    assert.equal(h.overlay(), undefined);
  });
}

test('captures nested feed scrolls while the document stays at zero; stops autoplay', async () => {
  const h = await harness();
  const { scroller, video } = h.addFeed({ height: 600 });
  h.scroll(scroller, 2399);
  assert.equal(h.overlay(), undefined);
  h.scroll(scroller, 2400);
  assert.ok(h.overlay());
  assert.equal(h.root.scrollTop, 0);
  assert.equal(video.paused, true);
  assert.equal(scroller.getAttribute('data-unscroll-tiktok-scroll-lock'), '');
  video.paused = false;
  h.document.emit('play', { target: video });
  assert.equal(video.paused, true);
  await h.update({ feed: false });
  assert.equal(h.overlay(), undefined);
  assert.equal(scroller.getAttribute('data-unscroll-tiktok-scroll-lock'), undefined);
  assert.equal(scroller.style.overflowY, 'scroll');
  assert.equal(h.elements.has('unscroll-tiktok-scroll-lock'), false);
  video.paused = false;
  h.document.emit('play', { target: video });
  assert.equal(video.paused, false, 'disabling feed stops intercepting playback');
});

test('virtualized feeds cannot reset the budget by recycling their scroll offset', async () => {
  const h = await harness();
  const { scroller } = h.addFeed();
  for (let i = 0; i < 3; i++) {
    h.scroll(scroller, 800);
    assert.equal(h.overlay(), undefined);
    h.scroll(scroller, 0);
  }
  h.scroll(scroller, 800);
  assert.ok(h.overlay());
});

test('comments, menus, hidden videos and small sidebars do not count as feed scrolling', async () => {
  const h = await harness();
  h.document.emit('scroll', { target: { scrollTop: 99999 } });
  for (const options of [{ height: 200 }, { width: 100 }, { visible: false }]) {
    const { scroller } = h.addFeed(options);
    h.scroll(scroller, 99999);
  }
  h.tick();
  assert.equal(h.overlay(), undefined);
});

for (const route of ['/search?q=test', '/@creator', '/@creator/video/123', '/messages', '/login', '/settings']) {
  test(`does not limit ${route}`, async () => {
    const h = await harness({ route, scrollY: 10000 });
    const { scroller } = h.addFeed();
    h.scroll(scroller, 10000);
    h.tick();
    assert.equal(h.overlay(), undefined);
    assert.deepEqual(h.redirects, []);
  });
}

test('SPA navigation releases the limit and checks restored scroll positions on return', async () => {
  const h = await harness({ scrollY: 3200 });
  assert.ok(h.overlay());
  h.navigate('/@creator/video/123');
  h.tick();
  assert.equal(h.overlay(), undefined);
  h.navigate('/following');
  h.root.scrollTop = 0;
  h.window.emit('popstate');
  assert.equal(h.overlay(), undefined);
  h.scroll(h.root, 3200);
  assert.ok(h.overlay());
});

test('live feed changes preserve the whole-site block and react to restored offsets', async () => {
  const h = await harness({ feed: false, scrollY: 3200 });
  assert.equal(h.overlay(), undefined);
  await h.update({ feed: true });
  assert.ok(h.overlay());
  await h.update({ all: true });
  assert.equal(h.overlay(), undefined);
  assert.match(h.redirects.at(-1), /blocked.html\?host=tiktok$/);
  await h.update({ all: false });
  assert.ok(h.overlay());
  await h.update({ feed: false });
  assert.equal(h.overlay(), undefined);
});

test('blocked gestures cannot scroll the feed; the overlay remains interactive', async () => {
  const h = await harness({ scrollY: 3200 });
  for (const [name, key] of [['wheel'], ['touchmove'], ['keydown', 'ArrowDown'], ['keydown', ' ']]) {
    let prevented = false;
    const event = { target: h.root, key, preventDefault() { prevented = true; } };
    h.document.emit(name, event);
    assert.equal(prevented, true);
    prevented = false;
    h.document.emit(name, { ...event, target: h.overlay() });
    assert.equal(prevented, false);
  }
});

test('defaults and legacy migration retain TikTok choices without enabling the new limit', async () => {
  const h = await harness();
  const ns = h.context.Unscroll;
  assert.deepEqual(plain(ns.SITE_FEATURES.tiktok), ['feed', 'following', 'hideUpsells', 'all']);
  for (const old of [undefined, 'off', 'shorts', 'feed', 'all', true, false, { all: false }]) {
    assert.equal(ns.normalizeSiteSettings('tiktok', old).feed, false);
  }
  assert.equal(ns.DEFAULT_TOGGLES.tiktok.all, true);
  for (const feed of [true, false]) for (const all of [true, false]) {
    assert.deepEqual(plain(ns.normalizeSiteSettings('tiktok', { feed, all })), { shorts: false, feed, all, following: false, hideUpsells: false });
  }
});
