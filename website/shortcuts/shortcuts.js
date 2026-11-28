(() => {
  const service = document.body.dataset.service;
  if (!['instagram', 'youtube', 'tiktok', 'facebook', 'x', 'threads', 'reddit', 'linkedin'].includes(service)) return;
  const name = document.body.dataset.name;
  const catalogs = globalThis.slowthShortcutTranslations || {};
  function resolveLocale(value) {
    try {
      const tag = new Intl.Locale(value);
      if (catalogs[tag.baseName]) return tag.baseName;
      const base = tag.language;
      if (base === 'zh') return tag.maximize().script === 'Hant' ? 'zh-Hant' : 'zh-Hans';
      if (base === 'pa' && tag.maximize().script === 'Arab') return 'pa-Arab';
      if (base === 'pt') return tag.region === 'PT' ? 'pt-PT' : 'pt-BR';
      if (base === 'no') return 'nb';
      if (base === 'tl') return 'fil';
      if (catalogs[base]) return base;
    } catch (_) { /* Ignore malformed or unsupported language tags. */ }
    return null;
  }
  const requested = new URLSearchParams(location.search).get('lang');
  const preferences = [requested, ...(navigator.languages || [navigator.language])].filter(Boolean);
  const locale = preferences.map(resolveLocale).find(value => value && catalogs[value]) || 'en';
  const catalog = catalogs[locale];
  if (catalog) {
    document.documentElement.lang = locale;
    document.documentElement.dir = catalog.direction;
    // Keep Latin service names readable inside right-to-left sentences.
    const serviceName = catalog.direction === 'rtl' ? `\u2068${name}\u2069` : name;
    for (const [id, value] of Object.entries(catalog.messages)) {
      const element = document.getElementById(id);
      if (!element) continue;
      const text = value.replaceAll('{service}', serviceName);
      if (id === 'description') element.content = text;
      else element.textContent = text;
    }
    document.getElementById('setup').href = `?setup=1&lang=${encodeURIComponent(locale)}`;
    document.getElementById('install').href = locale === 'en' ? '/' : `/${locale}/`;
  }
  if (document.documentElement.classList.contains('launching')) {
    const openLink = document.getElementById('open');
    openLink.href = `slowth://web/${service}`;
    openLink.hidden = false;
  }
})();
