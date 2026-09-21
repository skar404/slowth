const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

function harness(mode, initialPath = "/") {
  const elements = new Map();
  const observers = [];
  const listeners = {};
  const redirects = [];
  let onMessage;
  const attributes = new Map();
  const root = {
    setAttribute(name, value) { attributes.set(name, value); },
    getAttribute(name) { return attributes.get(name) ?? null; },
    appendChild(el) { elements.set(el.id, el); el.parentNode = root; },
    removeChild(el) { elements.delete(el.id); el.parentNode = null; }
  };
  const context = vm.createContext({
    document: {
      documentElement: root,
      body: root,
      getElementById: id => elements.get(id),
      createElement: () => ({})
    },
    location: {
      href: "https://www.facebook.com" + initialPath,
      origin: "https://www.facebook.com",
      pathname: initialPath,
      search: "",
      replace(url) { redirects.push(url); }
    },
    window: { stop() {}, addEventListener(name, callback) { listeners[name] = callback; } },
    setInterval() {},
    MutationObserver: class {
      constructor(callback) { observers.push(callback); }
      observe() {}
    },
    browser: { i18n: { getMessage(key) {
      return JSON.parse(fs.readFileSync(path.join(__dirname, "../_locales/en/messages.json"), "utf8"))[key]?.message || "";
    } }, runtime: {
      getURL: file => "safari-web-extension://test/" + file,
      sendMessage(_msg, callback) {
        callback({ toggles: { facebook: mode }, rules: context.Unscroll.DEFAULT_RULES });
      },
      onMessage: { addListener(callback) { onMessage = callback; } }
    } }
  });
  for (const file of ["config.js", "i18n.js", "content/common.js"]) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, "..", file), "utf8"), context);
  }
  return {
    context, redirects, observers, listeners,
    async start() {
      context.Unscroll.content.siteContentScript("facebook");
      await Promise.resolve();
    },
    async setMode(next) {
      mode = next;
      onMessage({ type: "unscroll-state-updated" });
      await Promise.resolve();
    },
    navigate(next) {
      const url = new URL(next, context.location.origin);
      Object.assign(context.location, { href: url.href, pathname: url.pathname, search: url.search });
    }
  };
}

test("Reels routes block with or without an ID, slash or query", () => {
  const { context } = harness("shorts");
  const re = new RegExp(context.Unscroll.DEFAULT_RULES.facebook.redirects[0].from);
  for (const route of ["/reel", "/reel/", "/reel/?s=tab", "/reel/123", "/reels", "/reels?foo=bar", "/reels/123"]) {
    assert.ok(re.test(route), route);
  }
  for (const route of ["/", "/friends/", "/groups/123", "/reelworld", "/reelsomething"]) {
    assert.ok(!re.test(route), route);
  }
});

test("mobile Reels interaction CSS follows the blocking mode", async () => {
  const h = harness("shorts");
  h.context.document.readyState = "loading";
  h.context.document.addEventListener = () => {};
  h.context.setInterval = () => {};
  vm.runInContext(fs.readFileSync(path.join(__dirname, "..", "content/facebook.js"), "utf8"), h.context);
  await Promise.resolve();
  const style = () => h.context.document.getElementById("unscroll-facebook-style");
  assert.doesNotMatch(style().textContent, /visibility: hidden/);
  assert.match(style().textContent, /pointer-events: none !important/);
  await h.setMode("off");
  assert.equal(style(), undefined);
  await h.setMode("feed");
  assert.match(style().textContent, /pointer-events: none !important/);
});

test("mobile Reels tabs restore interaction when disabled or reused", () => {
  let mode = "shorts";
  let tick;
  const tab = { inert: false };
  const alreadyInertTab = { inert: true };
  let tabs = [tab, alreadyInertTab];
  const context = vm.createContext({
    browser: {},
    window: { addEventListener() {} },
    location: { pathname: "/friends/" },
    Unscroll: { i18n: { t: key => key, locale: "en" }, content: { siteContentScript() {}, featureEnabled: (_, feature) => feature === "shorts" ? ["shorts", "feed"].includes(mode) : mode === "feed" } },
    document: {
      readyState: "complete",
      querySelectorAll: selector => selector.startsWith('[role="tab"]') ? tabs : []
    },
    setInterval(callback) { tick = callback; }
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, "..", "content/facebook.js"), "utf8"), context);
  assert.equal(tab.inert, true);
  tabs = [alreadyInertTab]; // Facebook reuses the former Reels node for another tab.
  tick();
  assert.equal(tab.inert, false);
  tabs = [tab, alreadyInertTab];
  tick();
  assert.equal(tab.inert, true);
  mode = "off";
  tick();
  assert.equal(tab.inert, false);
  assert.equal(alreadyInertTab.inert, true);
});

test("profile tab marker survives href removal without repeated DOM writes", () => {
  let writes = 0;
  const attrs = new Map([["href", "https://www.facebook.com/RockDomainClimbingGym/reels_tab"]]);
  const tab = {
    textContent: "Reels",
    getAttribute: key => attrs.get(key) ?? null,
    hasAttribute: key => attrs.has(key),
    setAttribute(key, value) { writes++; attrs.set(key, value); },
    removeAttribute(key) { writes++; attrs.delete(key); }
  };
  let tick;
  const context = vm.createContext({
    URL,
    location: { href: "https://www.facebook.com/RockDomainClimbingGym", pathname: "/RockDomainClimbingGym" },
    browser: {},
    window: { addEventListener() {} },
    Unscroll: { i18n: { t: key => key, locale: "en" }, content: { siteContentScript() {}, featureEnabled: () => true } },
    document: { readyState: "complete", querySelectorAll: selector => selector === 'a[role="tab"]' ? [tab] : [] },
    setInterval(callback) { tick = callback; }
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, "..", "content/facebook.js"), "utf8"), context);
  assert.ok(attrs.has("data-unscroll-facebook-reels-tab"));
  attrs.delete("href");
  for (let i = 0; i < 10; i++) tick();
  assert.ok(attrs.has("data-unscroll-facebook-reels-tab"));
  assert.equal(writes, 1);
  tab.textContent = "Photos";
  attrs.set("href", "/RockDomainClimbingGym/photos/");
  tick();
  assert.ok(!attrs.has("data-unscroll-facebook-reels-tab"));
  tab.textContent = "Видео";
  attrs.set("href", "/RockDomainClimbingGym/owner_reels");
  tick();
  assert.ok(attrs.has("data-unscroll-facebook-reels-tab"));
});

for (const mode of ["shorts", "feed"]) {
  test(`${mode}: blocks profile Reels sections without blocking other profile tabs`, async () => {
    const h = harness(mode);
    await h.start();
    for (const route of ["/RockDomainClimbingGym/", "/RockDomainClimbingGym/photos/", "/RockDomainClimbingGym/followers/", "/profile.php?id=123&sk=about", "/RockDomainClimbingGym/reels_examples"]) {
      h.navigate(route);
      h.observers[0]();
    }
    assert.equal(h.redirects.length, 0);
    const routes = ["/RockDomainClimbingGym/reels/", "/RockDomainClimbingGym/reels_tab", "/RockDomainClimbingGym/reels_tab?ref=page", "/RockDomainClimbingGym/owner_reels", "/profile.php?id=123&sk=reels_tab", "/RockDomainClimbingGym/?sk=reels"];
    for (const route of routes) {
      h.navigate(route);
      h.observers[0]();
    }
    assert.equal(h.redirects.length, routes.length);
  });

  test(`${mode}: blocks direct Reels visits`, async () => {
    const h = harness(mode, "/reel/");
    await h.start();
    assert.deepEqual(h.redirects, ["safari-web-extension://test/blocked.html?host=facebook"]);
  });

  test(`${mode}: blocks SPA and back/forward navigation, respects switching off`, async () => {
    const h = harness(mode);
    await h.start();
    h.navigate("/friends/");
    h.observers[0]();
    assert.equal(h.redirects.length, 0);
    h.navigate("/reel/?s=tab");
    h.observers[0]();
    assert.equal(h.redirects.length, 1);
    h.navigate("/reel/123");
    h.listeners.popstate();
    assert.equal(h.redirects.length, 2);
    await h.setMode("off");
    h.navigate("/reel/456");
    h.observers[0]();
    assert.equal(h.redirects.length, 2);
  });
}

// The mobile player observed in Safari exposes these attributes even when the
// address is a legacy /videos/ permalink rather than /reel/.
function playerFixture({ reels = true, format = "full_screen", visible = true,
  rect = { width: 440, height: 782, top: 0, left: 0, bottom: 782, right: 440 },
  rawExtra } = {}) {
  let pauses = 0;
  return {
    reels,
    extra: rawExtra === undefined ? JSON.stringify({ is_reels: reels, player_format: format }) : rawExtra,
    visible, rect,
    get pauses() { return pauses; },
    getAttribute(name) { return name === "data-extra" ? this.extra : null; },
    checkVisibility() { return this.visible; },
    getBoundingClientRect() { return this.rect; },
    querySelectorAll() { return [{ pause() { pauses++; } }]; }
  };
}

async function playerHarness(mode, players = []) {
  const h = harness(mode, "/creator/videos/title/123/");
  let tick;
  h.context.window.innerHeight = 796;
  h.context.window.innerWidth = 440;
  h.context.document.readyState = "complete";
  h.context.document.querySelectorAll = selector =>
    selector === '[data-type="video"][data-is-reels="true"]'
      ? players.filter(player => player.reels) : [];
  h.context.setInterval = callback => { tick = callback; };
  vm.runInContext(fs.readFileSync(path.join(__dirname, "..", "content/facebook.js"), "utf8"), h.context);
  await Promise.resolve();
  return { ...h, tick: () => tick(), players };
}

for (const mode of ["shorts", "feed"]) {
  test(`${mode}: blocks a visible full-screen Reels player at a legacy video URL`, async () => {
    const player = playerFixture();
    const h = await playerHarness(mode, [player]);
    h.tick();
    assert.deepEqual(h.redirects, ["safari-web-extension://test/blocked.html?host=facebook"]);
    assert.equal(player.pauses, 1);
    h.tick();
    assert.equal(h.redirects.length, 1);
    assert.equal(player.pauses, 1);
  });
}

test("Reels detection follows late player rendering and mode changes without a URL change", async () => {
  const h = await playerHarness("off");
  const player = playerFixture();
  h.players.push(player);
  h.tick();
  assert.equal(h.redirects.length, 0);
  await h.setMode("shorts");
  h.tick();
  assert.equal(h.redirects.length, 1);
  await h.setMode("off");
  h.tick();
  assert.equal(h.redirects.length, 1);
  await h.setMode("feed");
  h.tick();
  assert.equal(h.redirects.length, 2);
});

test("Reels detection notices player metadata populated after initial render", async () => {
  const player = playerFixture({ rawExtra: "" });
  const h = await playerHarness("shorts", [player]);
  h.tick();
  assert.equal(h.redirects.length, 0);
  player.extra = JSON.stringify({ player_format: "full_screen" });
  h.tick();
  assert.equal(h.redirects.length, 1);
});

for (const [name, options] of [
  ["ordinary video", { reels: false }],
  ["inline Reels card in a feed", { format: "inline" }],
  ["hidden cached screen", { visible: false }],
  ["offscreen preloaded player", { rect: { width: 440, height: 782, top: 900, left: 0, bottom: 1682, right: 440 } }],
  ["zero-size player", { rect: { width: 0, height: 0, top: 0, left: 0, bottom: 0, right: 0 } }],
  ["malformed metadata", { rawExtra: "{broken" }],
  ["missing metadata", { rawExtra: null }]
]) {
  test(`does not block the page for: ${name}`, async () => {
    const player = playerFixture(options);
    const h = await playerHarness("shorts", [player]);
    h.tick();
    assert.equal(h.redirects.length, 0);
    assert.equal(player.pauses, 0);
  });
}

test("restoring a Reels page from the back/forward cache blocks it again", async () => {
  const h = await playerHarness("shorts", [playerFixture()]);
  h.tick();
  assert.equal(h.redirects.length, 1);
  h.listeners.pageshow();
  assert.equal(h.redirects.length, 2);
});
