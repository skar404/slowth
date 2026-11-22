const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const code = fs.readFileSync(path.join(__dirname, '../../website/shortcuts/shortcuts.js'), 'utf8');
function run({standalone = false, search = '', language = 'en', service = 'instagram'} = {}) {
  const elements = new Map();
  const document = {body: {dataset: {service, name: 'Instagram'}}, documentElement: {}, getElementById(id) {
    if (!elements.has(id)) elements.set(id, {hidden: id === 'launcher'});
    return elements.get(id);
  }};
  const location = {search, href: 'https://slowth.app/shortcuts/instagram/'};
  vm.runInNewContext(code, {document, navigator: {standalone, language}, matchMedia: () => ({matches: standalone}), location, URLSearchParams});
  return {document, location, elements};
}
test('installation page does not redirect before Add to Home Screen', () => {
  const r = run();
  assert.equal(r.location.href, 'https://slowth.app/shortcuts/instagram/');
  assert.equal(r.elements.get('open').href, 'slowth://web/instagram');
});
test('standalone launch selects service and leaves manual fallback visible', () => {
  const r = run({standalone: true, service: 'youtube'});
  assert.equal(r.location.href, 'slowth://web/youtube');
  assert.equal(r.elements.get('instructions').hidden, true);
  assert.equal(r.elements.get('launcher').hidden, false);
  assert.equal(r.elements.get('open').hidden, false);
});
test('browser launch URL shows fallback without forcing app navigation', () => {
  const r = run({search: '?launch=1'});
  assert.equal(r.elements.get('launcher').hidden, false);
  assert.match(r.location.href, /^https:/);
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
});
