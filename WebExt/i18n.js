(function () {
  const ns = globalThis.Unscroll || (globalThis.Unscroll = {});
  const api = globalThis.browser || globalThis.chrome;
  const t = (key, substitutions) => api.i18n.getMessage(key, substitutions);
  // This message reflects the selected translation, including the English
  // fallback, while getUILanguage may name an unsupported browser language.
  const locale = t("locale");
  const direction = /^(ar|he|ur|pa-Arab)(-|$)/.test(locale) ? "rtl" : "ltr";
  // Call only for extension-owned pages or overlay roots. Loading this module
  // in a content script must never change the host site's language/direction.
  function setLocale(element) {
    element.lang = locale;
    element.dir = direction;
  }
  function localize(root = document) {
    for (const el of root.querySelectorAll("[data-i18n]")) {
      el.textContent = t(el.dataset.i18n);
    }
    for (const el of root.querySelectorAll("[data-i18n-aria]")) {
      el.setAttribute("aria-label", t(el.dataset.i18nAria));
    }
  }
  function duration(ms) {
    const seconds = Math.max(0, Math.floor(ms / 1000));
    const parts = seconds < 60 ? [[seconds, "second"]]
      : seconds < 3600 ? [[Math.floor(seconds / 60), "minute"], [seconds % 60, "second"]]
      : [[Math.floor(seconds / 3600), "hour"], [Math.floor(seconds / 60) % 60, "minute"]];
    return parts.filter(([n], i) => n || i === 0).map(([n, unit]) =>
      new Intl.NumberFormat(locale, { style: "unit", unit, unitDisplay: "short" }).format(n)
    ).join(" ");
  }
  ns.i18n = { t, locale, direction, setLocale, localize, duration };
})();
