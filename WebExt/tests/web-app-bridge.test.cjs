const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const read = file => fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
const flush = async () => { for (let i = 0; i < 25; i++) await Promise.resolve(); };

function harness({ embedded = true, ack = true, live = true } = {}) {
  let listener, disconnect, connections = 0, reads = 0;
  const sent = [], checks = [], timers = [];
  const port = {
    onMessage: { addListener(fn) { listener = fn; } },
    onDisconnect: { addListener(fn) { disconnect = fn; } },
    postMessage(message) { sent.push(message); }
  };
  const ns = {
    getStateFresh: async () => {
      reads++;
      ns.webAppHost = embedded;
      return { webAppNativeLive: live, toggles: { youtube: { shorts: false, feed: false, all: false } } };
    },
    setOnboardingDone: async () => {}
  };
  const runtime = {
    lastError: null,
    connectNative(name) { assert.equal(name, 'slowth.web-apps'); connections++; return port; },
    onInstalled: { addListener() {} }, onMessage: { addListener() {} }
  };
  vm.runInNewContext(read('background.js'), {
    URL, Unscroll: ns, setTimeout(fn) { timers.push(fn); return fn; }, clearTimeout() {},
    browser: { runtime, tabs: {
      query(_, cb) { cb([{id: 1, url: 'https://www.youtube.com/'}, {id: 2, url: 'https://accounts.google.com/'}]); },
      sendMessage(id, message, cb) {
        checks.push({id, message});
        cb(ack === null ? undefined : {ok: ack, revision: message.revision});
      }
    } }
  });
  return {
    sent, checks, timers,
    get connections() { return connections; }, get reads() { return reads; },
    async verify(revision) { listener({type: 'verify', revision}); await flush(); },
    disconnect() { disconnect(); }, setLive(value) { live = value; }
  };
}

test('Safari never opens the embedded-host native port', async () => {
  const h = harness({embedded: false}); await flush();
  assert.equal(h.connections, 0);
});
test('fresh settings reach the supported content script and disabled restrictions still acknowledge', async () => {
  const h = harness(); await flush(); await h.verify('revision-1');
  assert.equal(h.connections, 1);
  assert.equal(h.checks.length, 1, 'external login provider is not a protected service');
  assert.equal(h.checks[0].id, 1);
  assert.equal(h.checks[0].message.state.toggles.youtube.shorts, false);
  assert.equal(h.sent.at(-1).ok, true);
  assert.equal(h.sent.at(-1).revision, 'revision-1');
  const previous = h.reads;
  await h.verify('revision-2');
  assert.ok(h.reads > previous, 'settings changes must bypass the cache');
  assert.equal(h.sent.at(-1).revision, 'revision-2');
});
for (const ack of [false, null]) test(`missing or failed content acknowledgement (${ack}) cannot verify protection`, async () => {
  const h = harness({ack}); await flush(); await h.verify('r');
  assert.equal(h.sent.at(-1).ok, false);
});
test('a native read failure must not claim cached settings are current', async () => {
  const h = harness(); await flush(); h.setLive(false); await h.verify('r');
  assert.equal(h.sent.at(-1).ok, false);
  assert.equal(h.checks.length, 0);
});
test('a broken port reconnects for the embedded host', async () => {
  const h = harness(); await flush(); h.disconnect();
  assert.equal(h.connections, 1);
  h.timers.at(-1)();
  assert.equal(h.connections, 2);
});
test('native freshness belongs to one response and is never restored from cached state', async () => {
  const storage = {};
  let response = {ok: true, webAppHost: true, state: {toggles: {}}};
  const context = vm.createContext({browser: {
    runtime: {sendNativeMessage(_, payload, cb) { cb(response); }},
    storage: {local: {
      get(_, cb) { cb(storage); }, set(items, cb) { Object.assign(storage, items); cb(); }
    }}
  }});
  vm.runInContext(read('config.js'), context);
  vm.runInContext(read('rules-loader.js'), context);
  const ns = context.Unscroll;
  const live = await ns.getStateFresh();
  assert.equal(live.webAppNativeLive, true);
  assert.equal(storage[ns.STORAGE_KEYS.cachedState].webAppNativeLive, undefined);
  response = null;
  const failed = await ns.getStateFresh();
  assert.equal(failed.webAppNativeLive, false);
  response = {ok: true, webAppHost: true, state: {toggles: {}}};
  await ns.getStateFresh();
  assert.equal(failed.webAppNativeLive, false, 'a later success must not validate a failed read');
});
