const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const code = fs.readFileSync(path.join(__dirname, '../../website/shortcuts/shortcuts.js'), 'utf8');
const translations = fs.readFileSync(path.join(__dirname, '../../website/shortcuts/translations.js'), 'utf8');
function run({standalone = false, search = '', language = 'en', languages, service = 'instagram', displayMode = false} = {}) {
  const elements = new Map();
  const document = {body: {dataset: {service, name: 'Instagram'}, classList: {add() {}}}, documentElement: {}, getElementById(id) {
    if (!elements.has(id)) elements.set(id, {hidden: id === 'launcher' || id === 'open'});
    return elements.get(id);
  }};
  const location = {search, href: 'https://slowth.app/shortcuts/instagram/'};
  vm.runInNewContext(translations + code, {document, navigator: {standalone, language, languages}, matchMedia: () => ({matches: displayMode}), location, URLSearchParams});
  return {document, location, elements};
}
test('installation page does not redirect before Add to Home Screen', () => {
  const r = run();
  assert.equal(r.location.href, 'https://slowth.app/shortcuts/instagram/');
  assert.equal(r.elements.get('open').href, undefined);
  assert.equal(r.elements.get('open').hidden, true);
});
test('standalone launch selects service and shows the launch status', () => {
  const r = run({standalone: true, service: 'youtube'});
  assert.equal(r.location.href, 'slowth://web/youtube');
  assert.equal(r.elements.get('instructions').hidden, true);
  assert.equal(r.elements.get('launcher').hidden, false);
  assert.equal(r.elements.get('open').hidden, false);
});
test('browser launch URL stays on installation instructions without an app link', () => {
  const r = run({search: '?launch=1'});
  assert.equal(r.elements.has('launcher'), false);
  assert.equal(r.elements.get('open').hidden, true);
  assert.equal(r.elements.get('open').href, undefined);
  assert.match(r.location.href, /^https:/);
});
test('standalone display mode launches each service without requiring a query flag', () => {
  for (const service of ['instagram', 'youtube', 'tiktok', 'facebook', 'x']) {
    const r = run({displayMode: true, service});
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
  assert.equal(r.elements.has('launcher'), false);
  assert.equal(r.elements.get('open').hidden, true);
  assert.equal(r.elements.get('open').href, undefined);
});


test('installed shortcuts launch before external assets and do not launch twice', () => {
  for (const service of ['instagram', 'youtube', 'tiktok', 'facebook', 'x']) {
    const html = fs.readFileSync(path.join(__dirname, `../../website/shortcuts/${service}/index.html`), 'utf8');
    const inline = html.match(/<script>([\s\S]*?)<\/script>/);
    assert.ok(inline, service);
    assert.ok(html.indexOf(inline[0]) < html.indexOf('<link'), 'launch precedes styles/icons/manifest');
    assert.ok(html.indexOf(inline[0]) < html.indexOf('<script src='), 'launch precedes external JS');
    for (const standalone of [false, true]) for (const search of ['', '?launch=1', '?setup=1']) {
      const launches = [];
      const documentEvents = new Map();
      const windowEvents = new Map();
      const context = vm.createContext({
        document: {visibilityState: 'visible', addEventListener(type, listener) { documentEvents.set(type, listener); }},
        window: {addEventListener(type, listener) { windowEvents.set(type, listener); }},
        navigator: {standalone, language: 'en'},
        matchMedia: () => ({matches: false}), URLSearchParams,
        location: {search, set href(value) { launches.push(value); }}
      });
      // The document exists, but its body and external assets do not exist yet.
      vm.runInContext(inline[1], context);
      const expected = standalone && search !== '?setup=1' ? [`slowth://web/${service}`] : [];
      assert.deepEqual(launches, expected);
      const elements = new Map();
      Object.assign(context.document, {
        body: {dataset: {service, name: service}, classList: {add() {}}}, documentElement: {},
        getElementById(id) {
          if (!elements.has(id)) elements.set(id, {});
          return elements.get(id);
        }
      });
      vm.runInContext(translations + code, context);
      assert.deepEqual(launches, expected, 'deferred UI must not repeat the automatic launch');
      const emit = (events, type) => events.get(type)?.();
      emit(windowEvents, 'pageshow');
      emit(documentEvents, 'visibilitychange');
      assert.deepEqual(launches, expected, 'initial lifecycle events must not duplicate the launch');
      for (let visit = 2; visit <= 4; visit++) {
        context.document.visibilityState = 'hidden';
        emit(documentEvents, 'visibilitychange');
        emit(windowEvents, 'pagehide');
        emit(windowEvents, 'pageshow');
        assert.equal(launches.length, expected.length * (visit - 1), 'never launch in the background');
        context.document.visibilityState = 'visible';
        emit(documentEvents, 'visibilitychange');
        emit(windowEvents, 'pageshow');
        assert.deepEqual(launches, Array(visit).fill(expected).flat(), 'each foreground visit launches exactly once');
      }
      // Back-forward cache can restore a document through page events alone.
      emit(windowEvents, 'pagehide');
      emit(windowEvents, 'pageshow');
      assert.deepEqual(launches, Array(5).fill(expected).flat());
      // A suspended standalone window may only emit visibility changes.
      context.document.visibilityState = 'hidden';
      emit(documentEvents, 'visibilitychange');
      context.document.visibilityState = 'visible';
      emit(documentEvents, 'visibilitychange');
      emit(documentEvents, 'visibilitychange');
      assert.deepEqual(launches, Array(6).fill(expected).flat());
    }
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
