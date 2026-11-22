const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const code = fs.readFileSync(path.join(__dirname, '../../website/shortcuts/shortcuts.js'), 'utf8');
function run({standalone = false, search = '', language = 'en', service = 'instagram', displayMode = false} = {}) {
  const elements = new Map();
  const document = {body: {dataset: {service, name: 'Instagram'}}, documentElement: {}, getElementById(id) {
    if (!elements.has(id)) elements.set(id, {hidden: id === 'launcher' || id === 'open'});
    return elements.get(id);
  }};
  const location = {search, href: 'https://slowth.app/shortcuts/instagram/'};
  vm.runInNewContext(code, {document, navigator: {standalone, language}, matchMedia: () => ({matches: displayMode}), location, URLSearchParams});
  return {document, location, elements};
}
test('installation page does not redirect before Add to Home Screen', () => {
  const r = run();
  assert.equal(r.location.href, 'https://slowth.app/shortcuts/instagram/');
  assert.equal(r.elements.get('open').href, undefined);
  assert.equal(r.elements.get('open').hidden, true);
});
test('standalone launch selects service and leaves manual fallback visible', () => {
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
      const context = vm.createContext({
        navigator: {standalone, language: 'en'},
        matchMedia: () => ({matches: false}), URLSearchParams,
        location: {search, set href(value) { launches.push(value); }}
      });
      // No document/body and no fetched assets exist when this script executes.
      vm.runInContext(inline[1], context);
      const expected = standalone && search !== '?setup=1' ? [`slowth://web/${service}`] : [];
      assert.deepEqual(launches, expected);
      const elements = new Map();
      context.document = {
        body: {dataset: {service, name: service}}, documentElement: {},
        getElementById(id) {
          if (!elements.has(id)) elements.set(id, {});
          return elements.get(id);
        }
      };
      vm.runInContext(code, context);
      assert.deepEqual(launches, expected, 'deferred UI must not repeat the automatic launch');
    }
  }
});
