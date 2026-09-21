const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const root = path.join(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const languages = fs.readdirSync(path.join(root, '_locales')).filter(l => fs.existsSync(path.join(root, '_locales', l, 'messages.json'))).sort();
const locales = Object.fromEntries(languages.map(l => [l, JSON.parse(read(`_locales/${l}/messages.json`))]));
// Apple catalogs and Intl use BCP 47; WebExtensions use underscore-based
// region names, including zh_CN for Simplified Chinese.
const nativeLocale = language => ({ pt_BR: 'pt-BR', pt_PT: 'pt-PT', zh_CN: 'zh-Hans', zh_TW: 'zh-Hant', ar_EG: 'ar-EG', pa_Arab: 'pa-Arab' }[language] || language);
const nativeLanguages = languages.map(nativeLocale).sort();
const unsupportedLanguage = 'zz';
const expectedLanguages = 'ar ar_EG be bn cs da de en es fil fr ha he hi hu hy id it ja ka kk ko ky lt mr ne nl pa_Arab pcm pl pt_BR pt_PT ro ru sv sw ta te th tr uk ur vi yue zh_CN zh_TW'.split(' ').sort();
const rtlLanguages = new Set(['ar', 'ar_EG', 'he', 'ur', 'pa_Arab']);
const direction = language => rtlLanguages.has(language) ? 'rtl' : 'ltr';
const placeholders = value => (value.replaceAll('$$', '').match(/\$\d+/g) || []).sort();

test('every localized manifest description meets the Safari upload limit', () => {
  const manifest = JSON.parse(read('manifest.json'));
  const match = /^__MSG_(.+)__$/.exec(manifest.description);
  assert.ok(match, 'Manifest description must reference a localized message');
  for (const [language, messages] of Object.entries(locales)) {
    const description = messages[match[1]]?.message;
    assert.equal(typeof description, 'string', `${language}: missing description string`);
    assert.ok(description.trim(), `${language}: empty description`);
    assert.ok(description.length <= 112, `${language}: description has ${description.length} characters; Safari allows 112`);
  }
});

test('all WebExtension translations have matching keys and substitutions', () => {
  assert.deepEqual(languages, expectedLanguages);
  assert.ok(!locales[unsupportedLanguage], 'Fallback fixture must remain unsupported');
  for (const [lang, messages] of Object.entries(locales)) {
    assert.deepEqual(Object.keys(messages).sort(), Object.keys(locales.en).sort());
    for (const [key, { message }] of Object.entries(messages)) {
      assert.ok(message.trim(), `${lang}: ${key}`);
      assert.deepEqual(placeholders(message), placeholders(locales.en[key].message), `${lang}: ${key}`);
    }
  }
  for (const file of ['app.html', 'blocked.html']) {
    for (const match of read(file).matchAll(/data-i18n(?:-aria)?="([^"]+)"/g)) {
      assert.ok(locales.en[match[1]], match[1]);
    }
  }
});

test('regional locale names are valid for date, number and duration formatting', () => {
  for (const [language, messages] of Object.entries(locales)) {
    const locale = messages.locale.message;
    assert.equal(locale, nativeLocale(language));
    assert.equal(Intl.getCanonicalLocales(locale)[0], locale);
    assert.equal(Intl.DateTimeFormat.supportedLocalesOf([locale]).length, 1, language);
    assert.ok(new Intl.DateTimeFormat(locale).format(new Date('2026-09-20T12:00:00Z')));
    assert.ok(new Intl.NumberFormat(locale, { style: 'unit', unit: 'minute' }).format(2));
    assert.ok(new Intl.RelativeTimeFormat(locale).format(-2, 'hour'));
  }
});

test('native catalog translations have matching format arguments', () => {
  const catalog = JSON.parse(read('../Localization/Localizable.xcstrings'));
  function args(value) {
    return [...value.matchAll(/%(?:(\d+)\$)?(lld|@)/g)].map((m, i) => `${m[1] || i + 1}:${m[2]}`).sort();
  }
  for (const [key, entry] of Object.entries(catalog.strings)) {
    if (entry.shouldTranslate === false) continue;
    assert.deepEqual(Object.keys(entry.localizations).sort(), nativeLanguages, key);
    for (const lang of languages) {
      const unit = entry.localizations[nativeLocale(lang)].stringUnit;
      assert.equal(unit.state, 'translated', `${lang}: ${key}`);
      assert.ok(unit.value.trim());
      assert.deepEqual(args(unit.value), args(key), `${lang}: ${key}`);
    }
  }
});

function harness(requested) {
  const messages = locales[requested] || locales.en;
  const elements = new Map();
  for (const [, id] of read('blocked.html').matchAll(/id="([^"]+)"/g)) {
    elements.set(id, { textContent: '', dataset: {}, setAttribute() {}, addEventListener() {} });
  }
  const context = vm.createContext({
    Intl, URLSearchParams,
    location: { search: '?host=youtube' },
    document: { documentElement: {}, querySelectorAll: () => [], getElementById: id => elements.get(id) },
    browser: { i18n: { getMessage(key, substitutions = []) {
      assert.ok(messages[key], `missing key ${key}`);
      const values = Array.isArray(substitutions) ? substitutions : [substitutions];
      return messages[key].message.replace(/\$\$|\$(\d+)/g, (m, n) => m === '$$' ? '$' : values[Number(n) - 1] || '');
    } } }
  });
  vm.runInContext(read('i18n.js'), context);
  return { context, elements };
}

for (const language of [...languages, unsupportedLanguage]) {
  const expected = (locales[language] || locales.en).blockedTitle.message.replace('$1', 'YouTube');
  test(`${language}: blocked page renders title, links and localized time`, () => {
    const { context, elements } = harness(language);
    vm.runInContext(read('blocked.js'), context);
    assert.equal(elements.get('blocked-title').textContent, expected);
    assert.equal(context.document.documentElement.lang, locales[language] ? nativeLocale(language) : 'en');
    assert.equal(context.document.documentElement.dir, direction(language));
    assert.equal(elements.get('back-link').href, 'https://www.youtube.com/');
    assert.ok(context.Unscroll.i18n.duration(61000).length);
    assert.ok(!context.Unscroll.i18n.t('storiesTime', context.Unscroll.i18n.duration(1000)).includes('$1'));
    if (language === 'en') assert.ok(context.Unscroll.i18n.t('quoteTeam').includes('$400k'));
  });
}

test('all content scripts load i18n before site-specific code', () => {
  const manifest = JSON.parse(read('manifest.json'));
  assert.equal(manifest.default_locale, 'en');
  assert.equal(manifest.description, '__MSG_extensionDescription__');
  for (const script of manifest.content_scripts) {
    assert.ok(script.js.indexOf('i18n.js') >= 0);
    assert.ok(script.js.indexOf('i18n.js') < script.js.length - 1);
  }
});

function popupHarness(language, namespace) {
  const { context } = harness(language);
  class Element {
    constructor(tag = 'div') {
      this.tagName = tag;
      this.dataset = {};
      this.children = [];
      this.listeners = {};
      this.classes = new Set();
      this.classList = {
        toggle: (name, enabled) => enabled ? this.classes.add(name) : this.classes.delete(name),
        add: name => this.classes.add(name),
        remove: name => this.classes.delete(name)
      };
    }
    appendChild(el) { this.children.push(el); }
    addEventListener(name, callback) { this.listeners[name] = callback; }
    setAttribute(name, value) { this[name] = value; }
    querySelectorAll(tag) {
      return this.children.flatMap(el => [...(el.tagName === tag ? [el] : []), ...el.querySelectorAll(tag)]);
    }
  }
  const elements = new Map();
  const translated = [];
  for (const match of read('app.html').matchAll(/<([a-z][\w-]*)\b([^>]*)>/g)) {
    const el = new Element(match[1]);
    const id = match[2].match(/\bid="([^"]+)"/);
    const key = match[2].match(/\bdata-i18n="([^"]+)"/);
    if (id) elements.set(id[1], el);
    if (key) { el.dataset.i18n = key[1]; translated.push(el); }
  }
  const state = { strictModeUntil: 0, onboardingDone: false, rulesFetchedAt: Date.now() / 1000 - 120, toggles: { youtube: 'shorts' } };
  const calls = [];
  const api = context.browser;
  api.runtime = {
    id: 'safari-localization-test',
    sendMessage(message, callback) {
      calls.push(message);
      const response = { ok: true, state };
      if (callback) callback(response);
      else return Promise.resolve(response);
    }
  };
  context[namespace] = api;
  if (namespace === 'chrome') delete context.browser;
  context.window = {};
  context.document = {
    body: new Element(), documentElement: {},
    getElementById: id => elements.get(id),
    createElement: tag => new Element(tag),
    querySelectorAll: selector => selector === '[data-i18n]' ? translated : []
  };
  vm.runInContext(read('config.js'), context);
  vm.runInContext(read('i18n.js'), context);
  vm.runInContext(read('app.js'), context);
  return { context, elements, translated, calls, state };
}

for (const namespace of ['browser', 'chrome']) {
  for (const language of [...languages, unsupportedLanguage]) {
    test(`${namespace}/${language}: popup localizes independent switches, status and strict lock`, async () => {
      const { context, elements, translated, calls, state } = popupHarness(language, namespace);
      await context.__unscrollRefresh();
      const messages = locales[language] || locales.en;
      assert.equal(context.document.documentElement.lang, messages.locale.message);
      assert.equal(context.document.documentElement.dir, direction(language));
      assert.ok(calls.some(call => call.action === 'getState'));
      assert.ok(elements.get('onboarding').classes.has('hidden'));
      assert.equal(translated.find(el => el.dataset.i18n === 'strictMode').textContent, messages.strictMode.message);
      const switches = elements.get('sites').querySelectorAll('input');
      assert.equal(switches.length, 11);
      assert.equal(switches[0].dataset.feature, 'all');
      assert.equal(switches[0].checked, false);
      assert.equal(switches[1].checked, true);
      const labels = elements.get('sites').querySelectorAll('span');
      assert.equal(elements.get('sites').querySelectorAll('strong')[0].textContent, 'YouTube');
      assert.ok(labels.some(label => label.textContent === messages.blockShorts.message));
      assert.ok(labels.some(label => label.textContent === messages.blockInfiniteFeed.message));
      assert.ok(elements.get('rules-status').textContent.startsWith(messages.rulesRelative.message.split('$1')[0]));
      state.strictModeUntil = Date.now() / 1000 + 3600;
      await context.__unscrollRefresh();
      assert.ok(switches.every(input => input.disabled));
      assert.ok(elements.get('strict-toggle').disabled);
      assert.ok(elements.get('strict-banner-text').textContent.startsWith(messages.strictUntil.message.split('$1')[0]));
    });
  }
}

for (const language of [...languages, unsupportedLanguage]) {
  test(`${language}: content localization is isolated from the host document`, () => {
    const { context } = harness(language);
    const host = { lang: 'de', dir: 'ltr' };
    context.document.documentElement = host;
    vm.runInContext(read('i18n.js'), context);
    assert.deepEqual(host, { lang: 'de', dir: 'ltr' });
    const overlay = {};
    context.Unscroll.i18n.setLocale(overlay);
    assert.equal(overlay.lang, (locales[language] || locales.en).locale.message);
    assert.equal(overlay.dir, direction(language));
    assert.deepEqual(host, { lang: 'de', dir: 'ltr' });
    for (const ms of [-1000, 0, 59000, 60000, 61000, 3600000, 3660000, 86400000]) {
      const text = context.Unscroll.i18n.duration(ms);
      assert.ok(text.trim());
      assert.doesNotMatch(text, /NaN|undefined|\$\d/);
    }
  });
}

test('RTL translations isolate substitutions and preserve literal dollar amounts', () => {
  const catalog = JSON.parse(read('../Localization/Localizable.xcstrings'));
  const balanced = (text, label) => {
    let depth = 0;
    for (const char of text) {
      if (/[\u2066-\u2068]/.test(char)) depth++;
      if (char === '\u2069') depth--;
      assert.ok(depth >= 0, label);
    }
    assert.equal(depth, 0, label);
  };
  for (const language of rtlLanguages) {
    const { context } = harness(language);
    assert.ok(context.Unscroll.i18n.t('quoteTeam').includes('$400k'), language);
    assert.ok(context.Unscroll.i18n.t('blockedTitle', 'YouTube').includes('\u2068YouTube\u2069'));
    for (const [key, { message }] of Object.entries(locales[language])) balanced(message, `${language}/${key}`);
    for (const [key, entry] of Object.entries(catalog.strings)) {
      if (entry.shouldTranslate === false) continue;
      const value = entry.localizations[nativeLocale(language)].stringUnit.value;
      balanced(value, `${language}/${key}`);
      for (const match of value.matchAll(/%(?:\d+\$)?(?:@|lld)/g)) {
        assert.equal(value[match.index - 1], '\u2068', key);
        assert.equal(value[match.index + match[0].length], '\u2069', key);
      }
    }
  }
});

test('extension CSS and overlays use logical direction without changing host direction', () => {
  for (const file of ['app.css', 'blocked.css']) {
    assert.doesNotMatch(read(file), /(?:text-align\s*:\s*(?:left|right)|(?:margin|padding|border)-(?:left|right)\s*:|^\s*(?:left|right)\s*:)/m, file);
  }
  for (const file of ['content/instagram.js', 'content/facebook.js']) {
    assert.match(read(file), /ns\.i18n\.setLocale\(wrap\)/);
    assert.doesNotMatch(read(file), /(?:document\.documentElement|root)\.(?:dir|lang)\s*=/);
  }
  const project = read('../project.yml');
  assert.equal((project.match(/path: Localization/g) || []).length, 8);
  assert.equal((project.match(/path: WebExt\/_locales/g) || []).length, 2);
});

test('popup sends a feature write and restores the state after a rejected save', async () => {
  const { context, elements, state } = popupHarness('ru', 'browser');
  state.toggles.instagram = { shorts: false, feed: true, all: false };
  await context.__unscrollRefresh();
  const inputs = elements.get('sites').querySelectorAll('input');
  const reels = inputs.find(input => input.dataset.site === 'instagram' && input.dataset.feature === 'shorts');
  const feed = inputs.find(input => input.dataset.site === 'instagram' && input.dataset.feature === 'feed');
  let payload;
  context.browser.runtime.sendMessage = async message => {
    payload = message.payload;
    return { ok: false, reason: 'no_response' };
  };
  reels.checked = true;
  await elements.get('sites').listeners.change({ target: reels });
  assert.deepEqual(JSON.parse(JSON.stringify(payload)), { site: 'instagram', feature: 'shorts', enabled: true });
  assert.equal(reels.checked, false);
  assert.equal(feed.checked, true);
  assert.equal(reels.disabled, false);
  assert.equal(elements.get('rules-status').textContent, locales.ru.settingsSaveFailed.message);
});

test('whole-site blocking disables content controls without changing their checks', async () => {
  const { context, elements, state } = popupHarness('en', 'browser');
  const flags = state.toggles.facebook = { shorts: false, feed: true, all: true };
  await context.__unscrollRefresh();
  const controls = elements.get('sites').querySelectorAll('input').filter(input => input.dataset.site === 'facebook');
  assert.deepEqual(controls.map(input => [input.checked, input.disabled]), [[true, false], [false, true], [true, true]]);
  flags.all = false;
  await context.__unscrollRefresh();
  assert.deepEqual(controls.map(input => [input.checked, input.disabled]), [[false, false], [false, false], [true, false]]);
});
