(function () {
  const ns = (globalThis.Unscroll = globalThis.Unscroll || {});
  const api = (typeof browser !== "undefined" ? browser : chrome);

  // Sentinel redirect target: a rule whose `to` is this shows blocked.html
  // instead of navigating same-origin. Kept in sync with background.js.
  const BLOCK_TOKEN = "unscroll:blocked";

  function sendMessage(msg) {
    return new Promise((resolve) => {
      try {
        api.runtime.sendMessage(msg, (resp) => {
          void api.runtime.lastError;
          resolve(resp);
        });
      } catch (_) {
        resolve(null);
      }
    });
  }

  function buildHideCss(selectors) {
    if (!Array.isArray(selectors) || !selectors.length) return "";
    // One rule per selector — if a selector is invalid (e.g. nested :has() not
    // supported by the engine), only that rule is dropped instead of the whole
    // comma-list.
    return selectors.map((s) => s + " { display: none !important; }").join("\n");
  }

  function injectHideStyle(id, css) {
    let style = document.getElementById(id);
    if (!style) {
      style = document.createElement("style");
      style.id = id;
      const root = document.documentElement || document.head || document.body;
      if (root) root.appendChild(style);
    }
    style.textContent = css;
  }

  function removeHideStyle(id) {
    const style = document.getElementById(id);
    if (style && style.parentNode) style.parentNode.removeChild(style);
  }

  function compileRedirects(redirects) {
    const out = [];
    for (const r of redirects || []) {
      try { out.push({ re: new RegExp(r.from), to: r.to }); } catch (_) {}
    }
    return out;
  }

  function maybeRedirect(compiled, site) {
    const target = location.pathname + location.search;
    for (const r of compiled) {
      if (r.re.test(target)) {
        if (r.to === BLOCK_TOKEN) {
          blockEntireSite(site);
          return true;
        }
        const next = target.replace(r.re, r.to);
        if (next !== target) {
          location.replace(location.origin + next);
          return true;
        }
      }
    }
    return false;
  }

  function blockEntireSite(site) {
    try { window.stop(); } catch (_) {}
    const url = api.runtime.getURL("blocked.html") + "?host=" + encodeURIComponent(site);
    location.replace(url);
  }

  function featureEnabled(site, feature) {
    return document.documentElement.getAttribute("data-unscroll-" + site + "-" + feature) === "true";
  }

  function siteContentScript(site, options) {
    const opts = options || {};
    const STYLE_ID = "unscroll-" + site + "-style";
    let shortsEnabled = false;
    let compiledRedirects = [];

    function applyState(state) {
      if (!state) return;
      const settings = ns.normalizeSiteSettings(site, state.toggles?.[site]);
      const rules = state.rules || ns.DEFAULT_RULES;
      shortsEnabled = settings.shorts && !settings.all;
      for (const feature of ns.SITE_FEATURES[site]) {
        document.documentElement.setAttribute("data-unscroll-" + site + "-" + feature,
          String(settings[feature] && (feature === "all" || !settings.all)));
      }
      if (settings.all) {
        removeHideStyle(STYLE_ID);
        compiledRedirects = [];
        blockEntireSite(site);
        return;
      }
      // Feed overlays are independent; only Shorts/Reels/Explore use these rules.
      if (!shortsEnabled) {
        removeHideStyle(STYLE_ID);
        compiledRedirects = [];
        return;
      }

      const r = rules[site] || {};
      injectHideStyle(STYLE_ID, buildHideCss(r.hideSelectors) + "\n" + (opts.css || ""));
      compiledRedirects = compileRedirects(r.redirects);
      maybeRedirect(compiledRedirects, site);
    }

    function watchSpaNav() {
      let lastUrl = location.href;
      const check = () => {
        if (!shortsEnabled) return;
        if (location.href !== lastUrl) {
          lastUrl = location.href;
          maybeRedirect(compiledRedirects, site);
        }
      };
      const obs = new MutationObserver(check);
      const start = () => {
        const root = document.body || document.documentElement;
        if (root) obs.observe(root, { childList: true, subtree: true });
      };
      if (document.body) start();
      else document.addEventListener("DOMContentLoaded", start, { once: true });

      window.addEventListener("popstate", check);
      if (Array.isArray(opts.spaEvents)) {
        for (const ev of opts.spaEvents) window.addEventListener(ev, check);
      }
    }

    api.runtime.onMessage.addListener((message) => {
      if (message && message.type === "unscroll-state-updated") {
        sendMessage({ type: "get-state" }).then(applyState);
      }
    });

    const refresh = () => sendMessage({ type: "get-state" }).then(applyState);
    window.addEventListener("focus", refresh);
    setInterval(() => {
      if (document.visibilityState !== "hidden") refresh();
    }, ns.STATE_CACHE_TTL_MS);

    sendMessage({ type: "get-state" }).then((state) => {
      applyState(state);
      watchSpaNav();
    });
  }

  ns.content = {
    sendMessage,
    buildHideCss,
    injectHideStyle,
    removeHideStyle,
    compileRedirects,
    maybeRedirect,
    blockEntireSite,
    featureEnabled,
    siteContentScript
  };
})();
