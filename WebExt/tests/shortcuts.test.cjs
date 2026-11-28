const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const code = fs.readFileSync(path.join(__dirname, '../../website/shortcuts/shortcuts.js'), 'utf8');
const translations = fs.readFileSync(path.join(__dirname, '../../website/shortcuts/translations.js'), 'utf8');
const shortcutDir = path.join(__dirname, '../../website/shortcuts');
const launchCode = fs.readFileSync(path.join(shortcutDir, 'launch.js'), 'utf8');
const services = ['instagram', 'youtube', 'tiktok', 'facebook', 'x', 'threads', 'reddit', 'linkedin'];

function run({standalone = false, search = '', language = 'en', languages, service = 'instagram',
              displayMode = false, visibility = 'visible'} = {}) {
  const page = services.includes(service) ? service : 'instagram';
  const html = fs.readFileSync(path.join(shortcutDir, page, 'index.html'), 'utf8');
  const inline = html.match(/<script>([\s\S]*?)<\/script>/)[1];
  const elements = new Map();
  const classes = new Set();
  const document = Object.assign(new EventTarget(), {
    visibilityState: visibility,
    body: {dataset: {service, name: 'Instagram'}},
    documentElement: {classList: {add: name => classes.add(name), contains: name => classes.has(name)}},
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, {hidden: id === 'open'});
      return elements.get(id);
    }
  });
  const window = new EventTarget();
  const frames = new Map();
  const timers = new Map();
  const launches = [];
  let nextId = 0;
  const location = {
    search,
    get href() { return launches.at(-1) ?? 'https://slowth.app/shortcuts/instagram/'; },
    set href(url) { launches.push(url); }
  };
  const context = vm.createContext({
    document, window, navigator: {standalone, language, languages}, location, URLSearchParams,
    matchMedia: () => ({matches: displayMode}),
    requestAnimationFrame(fn) { frames.set(++nextId, fn); return nextId; },
    cancelAnimationFrame(id) { frames.delete(id); },
    setTimeout(fn, delay) { assert.equal(delay, 2000); timers.set(++nextId, fn); return nextId; },
    clearTimeout(id) { timers.delete(id); }
  });
  vm.runInContext(inline, context);
  vm.runInContext(launchCode, context);
  vm.runInContext(translations + code, context);
  function tick(queue) {
    for (const [id, fn] of [...queue]) {
      if (queue.delete(id)) fn();
    }
  }
  return {document, window, classes, location, elements, launches, frames, timers,
    frame: () => tick(frames), retry: () => tick(timers),
    visibility(state) {
      document.visibilityState = state;
      document.dispatchEvent(new Event('visibilitychange'));
    }
  };
}
test('installation page does not redirect before Add to Home Screen', () => {
  const r = run();
  assert.equal(r.location.href, 'https://slowth.app/shortcuts/instagram/');
  assert.equal(r.document.getElementById('open').href, undefined);
  assert.equal(r.document.getElementById('open').hidden, true);
});
test('standalone launch selects service and shows the launch status', () => {
  const r = run({standalone: true, service: 'youtube'});
  assert.ok(r.classes.has('launching'));
  assert.equal(r.launches.length, 0);
  r.frame();
  assert.equal(r.launches.length, 0);
  r.frame();
  assert.equal(r.location.href, 'slowth://web/youtube');
  assert.equal(r.elements.get('open').hidden, false);
});
test('browser launch URL stays on installation instructions without an app link', () => {
  const r = run({search: '?launch=1'});
  assert.equal(r.classes.has('launching'), false);
  assert.equal(r.frames.size, 0);
  assert.equal(r.document.getElementById('open').hidden, true);
  assert.equal(r.document.getElementById('open').href, undefined);
  assert.match(r.location.href, /^https:/);
});
test('standalone display mode launches each service without requiring a query flag', () => {
  for (const service of services) {
    const r = run({displayMode: true, service});
    r.frame();
    r.frame();
    assert.equal(r.location.href, `slowth://web/${service}`);
    assert.equal(r.elements.get('open').hidden, false);
  }
});
test('Russian instructions and unsupported service', () => {
  assert.equal(run({language: 'ru-RU'}).document.documentElement.lang, 'ru');
  const r = run({standalone: true, service: '../../bad'});
  assert.equal(r.elements.size, 0);
  assert.match(r.location.href, /^https:/);
});

test('installed shortcut can reopen instructions without relaunching the app', () => {
  const r = run({standalone: true, search: '?setup=1'});
  assert.match(r.location.href, /^https:/);
  assert.equal(r.classes.has('launching'), false);
  assert.equal(r.frames.size, 0);
  assert.equal(r.document.getElementById('open').hidden, true);
  assert.equal(r.document.getElementById('open').href, undefined);
});


test('foreground retries stop when hidden and restart after a painted frame on return', () => {
  const r = run({standalone: true, visibility: 'hidden'});
  assert.equal(r.frames.size, 0);
  const show = () => r.window.dispatchEvent(new Event('pageshow'));
  const hide = () => r.window.dispatchEvent(new Event('pagehide'));
  function assertStopped() {
    assert.equal(r.frames.size, 0);
    assert.equal(r.timers.size, 0);
  }
  r.visibility('visible');
  r.frame();
  r.visibility('hidden');
  assertStopped();
  assert.equal(r.launches.length, 0);

  for (let visit = 0; visit < 3; visit++) {
    r.visibility('visible');
    show();
    show();
    assert.equal(r.frames.size, 1);
    r.frame();
    assert.equal(r.launches.length, visit * 5);
    r.frame();
    for (let retry = 1; retry <= 4; retry++) {
      show();
      r.visibility('visible');
      assert.equal(r.frames.size, 0);
      assert.equal(r.timers.size, 1);
      r.retry();
    }
    assert.deepEqual(r.launches, Array((visit + 1) * 5).fill('slowth://web/instagram'));
    if (visit === 0) {
      r.visibility('hidden'); // Suspension with only a visibility event.
    } else {
      hide(); // Back-forward cache, even if visibility still reads visible.
      r.visibility('visible');
    }
    assertStopped();
  }
});

test('language preferences resolve regions, scripts, RTL and unsupported languages', () => {
  for (const [language, expected] of [
    ['ru-RU', 'ru'], ['de-CH', 'de'], ['pt-PT', 'pt-PT'], ['pt-BR', 'pt-BR'],
    ['zh-TW', 'zh-Hant'], ['zh-HK', 'zh-Hant'], ['zh-CN', 'zh-Hans'],
    ['pa-PK', 'pa-Arab'], ['pa-IN', 'pa'], ['ar-EG', 'ar-EG'], ['iw-IL', 'he'],
    ['no-NO', 'nb'], ['tl-PH', 'fil'], ['invalid_tag', 'en']
  ]) {
    const r = run({language});
    assert.equal(r.document.documentElement.lang, expected, language);
    assert.equal(r.document.documentElement.dir, ['pa-Arab', 'ar-EG', 'he'].includes(expected) ? 'rtl' : 'ltr');
  }
  assert.equal(run({languages: ['zz-ZZ', 'uk-UA', 'en']}).document.documentElement.lang, 'uk');
  const ru = run({language: 'en', search: '?lang=ru', standalone: true});
  assert.equal(ru.elements.get('launchTitle').textContent, 'Открываем Instagram…');
  assert.equal(ru.elements.get('launchContext').textContent, 'в Slowth');
  assert.equal(ru.elements.get('setup').href, '?setup=1&lang=ru');
  ru.frame();
  ru.frame();
  assert.equal(ru.location.href, 'slowth://web/instagram');
});

test('every supported locale has complete shortcut copy and intact service placeholders', () => {
  const context = vm.createContext({});
  vm.runInContext(translations, context);
  const catalogs = context.slowthShortcutTranslations;
  const locales = JSON.parse(fs.readFileSync(path.join(__dirname, '../../website/localization/locales.json')));
  assert.deepEqual(Object.keys(catalogs), Object.keys(locales));
  const source = catalogs.en.messages;
  for (const [locale, catalog] of Object.entries(catalogs)) {
    assert.equal(catalog.direction, locales[locale].direction);
    assert.deepEqual(Object.keys(catalog.messages), Object.keys(source));
    for (const [id, value] of Object.entries(catalog.messages)) {
      assert.ok(value.trim(), `${locale}/${id}`);
      assert.equal(value.split('{service}').length, source[id].split('{service}').length, `${locale}/${id}`);
      assert.equal(value.split('Slowth').length, source[id].split('Slowth').length, `${locale}/${id}`);
      assert.doesNotMatch(value, /ZXQ|<\/?script/);
    }
  }
});
