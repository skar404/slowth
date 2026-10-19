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
      if (opts.onStateApplied) opts.onStateApplied();
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
    window.addEventListener("pageshow", refresh);
    setInterval(() => {
      if (document.visibilityState !== "hidden") refresh();
    }, ns.STATE_CACHE_TTL_MS);

    sendMessage({ type: "get-state" }).then((state) => {
      applyState(state);
      watchSpaNav();
    });
  }

  function overlayCSS(OVERLAY_ID, dismissable = false) {
    return [
      "#" + OVERLAY_ID + "{",
      "position:fixed;inset:0;z-index:2147483647;",
      "background:linear-gradient(180deg,rgba(74,60,173,0.95),rgba(35,22,80,0.95)),#1a1340;",
      "color:#f2f2f5;",
      "font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',system-ui,sans-serif;",
      "-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility;",
      "display:flex;align-items:center;justify-content:center;",
      "padding:24px;box-sizing:border-box;overflow:auto;",
      "}",
      "#" + OVERLAY_ID + " *{box-sizing:border-box;}",
      ...(dismissable ? [
      "#" + OVERLAY_ID + " .uo-close{",
      "position:absolute;top:18px;inset-inline-end:18px;width:36px;height:36px;border-radius:50%;",
      "background:rgba(255,255,255,0.08);border:1px solid rgba(255,255,255,0.12);",
      "color:#fff;font-size:22px;line-height:1;cursor:pointer;",
      "appearance:none;display:grid;place-items:center;font-family:inherit;",
      "transition:background 0.15s ease;padding:0;",
      "}",
      "#" + OVERLAY_ID + " .uo-close:hover{background:rgba(255,255,255,0.16);}",
      ] : []),
      "#" + OVERLAY_ID + " .uo-main{",
      "max-width:520px;display:flex;flex-direction:column;align-items:center;gap:24px;text-align:center;",
      "}",
      "#" + OVERLAY_ID + " .uo-icon{",
      "width:96px;height:96px;border-radius:24px;",
      "background:linear-gradient(135deg,rgba(255,255,255,0.18),rgba(255,255,255,0.04));",
      "box-shadow:0 30px 60px -20px rgba(89,81,235,0.55),0 0 0 1px rgba(255,255,255,0.06) inset;",
      "display:grid;place-items:center;",
      "-webkit-backdrop-filter:blur(10px);backdrop-filter:blur(10px);",
      "}",
      "#" + OVERLAY_ID + " .uo-icon img{width:76px;height:76px;border-radius:18px;display:block;}",
      "#" + OVERLAY_ID + " h1{",
      "font-size:clamp(28px,5vw,40px);line-height:1.1;font-weight:700;margin:0;letter-spacing:-0.02em;",
      "}",
      "#" + OVERLAY_ID + " h1 .host{",
      "background:linear-gradient(135deg,#c9b6ff,#ff9fd6 60%,#6db4ff);",
      "-webkit-background-clip:text;background-clip:text;color:transparent;",
      "}",
      "#" + OVERLAY_ID + " .uo-lede{",
      "margin:0;font-size:16px;line-height:1.5;color:rgba(242,242,245,0.65);max-width:420px;",
      "}",
      "#" + OVERLAY_ID + " .uo-btn{",
      "appearance:none;border:0;cursor:pointer;font:inherit;padding:12px 22px;border-radius:999px;",
      "font-size:15px;font-weight:600;color:#0b0b15;",
      "background:linear-gradient(135deg,#ffffff,#d8d8e8);",
      "transition:transform 0.08s ease,background 0.15s ease;margin-top:4px;",
      "}",
      "#" + OVERLAY_ID + " .uo-btn:hover{background:linear-gradient(135deg,#ffffff,#c8c8db);}",
      "#" + OVERLAY_ID + " .uo-btn:active{transform:scale(0.97);}",
      "#" + OVERLAY_ID + " .uo-signature{",
      "margin-top:8px;font-size:12px;letter-spacing:0.08em;text-transform:uppercase;color:rgba(242,242,245,0.4);",
      "}",
      "@media (max-width:480px){",
      "#" + OVERLAY_ID + " .uo-icon{width:84px;height:84px;border-radius:22px;}",
      "#" + OVERLAY_ID + " .uo-icon img{width:66px;height:66px;border-radius:16px;}",
      "}"
    ].join("");
  }

  ns.content = {
    overlayCSS,
    blockEntireSite,
    featureEnabled,
    siteContentScript
  };
})();
