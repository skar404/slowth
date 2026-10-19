(function () {
  const ns = globalThis.Unscroll;
  const { t, locale } = globalThis.Unscroll.i18n;
  const api = (typeof browser !== "undefined" ? browser : chrome);
  const MOBILE_REELS_TAB = '[role="tab"]:is([aria-label="reels" i], [aria-label^="reels," i])';
  globalThis.Unscroll.content.siteContentScript("facebook", {
    // Keep the tab's painted background; hiding it exposes a gray gap on mobile.
    css: `${MOBILE_REELS_TAB}, ${MOBILE_REELS_TAB} * { pointer-events: none !important; }`
  });

  const inertTabs = new Map();

  function updateMobileReelsTabs() {
    const tabs = new Set(globalThis.Unscroll.content.featureEnabled("facebook", "shorts")
      ? document.querySelectorAll(MOBILE_REELS_TAB) : []);
    for (const [tab, wasInert] of inertTabs) {
      if (!tabs.has(tab)) {
        tab.inert = wasInert;
        inertTabs.delete(tab);
      }
    }
    for (const tab of tabs) {
      if (!inertTabs.has(tab)) inertTabs.set(tab, tab.inert);
      // Inert prevents focus and activation without changing layout or paint.
      if (!tab.inert) tab.inert = true;
    }
  }

  const OVERLAY_ID = "unscroll-block-overlay";
  const STYLE_ID = "unscroll-block-overlay-style";

  // Same threshold Instagram uses for its home feed — let the user glance at a
  // few screens before the nudge fires.
  const SCROLL_TRIGGER_VH_HOME = 4;

  let scrollListener = null;
  let scrollThresholdPx = 0;
  let currentContext = null;
  let reelsPlayerBlocked = false;

  function findReelsPlayer() {
    // Mobile Facebook also opens Reels at /<profile>/videos/<title>/<id>.
    // Read the player's own metadata, not the URL or translated UI labels.
    for (const player of document.querySelectorAll('[data-type="video"][data-is-reels="true"]')) {
      let extra;
      try { extra = JSON.parse(player.getAttribute("data-extra") || "null"); }
      catch (_) { continue; }
      if (!extra || extra.player_format !== "full_screen") continue;
      // Facebook keeps inactive screens and preloaded players in the DOM.
      if (player.checkVisibility && !player.checkVisibility({
        opacityProperty: true, visibilityProperty: true
      })) continue;
      const rect = player.getBoundingClientRect();
      if (rect.width > 0 && rect.height > 0 && rect.bottom > 0 && rect.right > 0 &&
          rect.top < window.innerHeight && rect.left < window.innerWidth) return player;
    }
    return null;
  }

  function blockReelsPlayer() {
    if (!globalThis.Unscroll.content.featureEnabled("facebook", "shorts")) {
      reelsPlayerBlocked = false;
      return false;
    }
    if (reelsPlayerBlocked) return true;
    const player = findReelsPlayer();
    if (!player) return false;
    reelsPlayerBlocked = true;
    for (const video of player.querySelectorAll("video")) video.pause();
    globalThis.Unscroll.content.blockEntireSite("facebook");
    return true;
  }

  // The profile tab bar removes href when a tab overflows. A persistent marker
  // keeps our CSS stable while Facebook measures and updates the tab layout.
  function markReelsTabs() {
    const attr = "data-unscroll-facebook-reels-tab";
    for (const tab of document.querySelectorAll('a[role="tab"]')) {
      const href = tab.getAttribute("href");
      let reelsURL = false;
      if (href) {
        try {
          const url = new URL(href, location.href);
          reelsURL = (url.hostname === "facebook.com" || url.hostname.endsWith(".facebook.com")) &&
            (/^\/[^/]+\/(reels(_tab)?|owner_reels)(\/|$)/.test(url.pathname) ||
             /^reels(_tab)?$/.test(url.searchParams.get("sk") || ""));
        } catch (_) {}
      }
      const reelsLabel = /(^|\s)reels$/i.test(tab.textContent.trim());
      if (reelsURL || reelsLabel) {
        if (!tab.hasAttribute(attr)) tab.setAttribute(attr, "");
      } else if (href && tab.hasAttribute(attr)) {
        // Facebook may reuse a DOM node for another profile section.
        tab.removeAttribute(attr);
      }
    }
  }

  function isFeedModeActive() {
    return globalThis.Unscroll.content.featureEnabled("facebook", "feed");
  }

  function isHomeFeed() {
    const p = location.pathname;
    return p === "/" || p === "" || p === "/home.php";
  }

  function ensureStyle() {
    if (document.getElementById(STYLE_ID)) return;
    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = ns.content.overlayCSS(OVERLAY_ID);
    document.documentElement.appendChild(style);
  }

  function showOverlay() {
    if (document.getElementById(OVERLAY_ID)) return;
    ensureStyle();
    const root = document.documentElement;
    const wrap = document.createElement("div");
    wrap.id = OVERLAY_ID;
    wrap.setAttribute("role", "dialog");
    wrap.setAttribute("aria-modal", "true");
    const iconUrl = api.runtime.getURL("images/icon-128.png");
    // Home feed is a hard block — only "Back to home" gets you out, no dismiss.
    wrap.innerHTML =
      '<main class="uo-main">' +
        '<div class="uo-icon"><img alt="Slowth"></div>' +
        '<h1 class="host"></h1>' +
        '<p class="uo-lede"></p>' +
        '<button class="uo-btn" type="button"></button>' +
        '<div class="uo-signature">Slowth · slow down, breathe, build</div>' +
      '</main>';
    ns.i18n.setLocale(wrap);
    wrap.querySelector("h1").textContent = t("feedTitle");
    wrap.querySelector(".uo-btn").textContent = t("backHome");
    wrap.querySelector(".uo-signature").textContent = t("signature");
    wrap.querySelector("img").src = iconUrl;
    wrap.querySelector(".uo-lede").textContent =
      t("feedSubtitle");
    root.appendChild(wrap);
    if (document.body) document.body.style.overflow = "hidden";
    root.style.overflow = "hidden";
    wrap.querySelector(".uo-btn").addEventListener("click", () => {
      location.href = "/";
    });
  }

  function removeOverlay() {
    const div = document.getElementById(OVERLAY_ID);
    if (div) div.remove();
    if (document.body) document.body.style.overflow = "";
    document.documentElement.style.overflow = "";
  }

  function detachScrollListener() {
    if (!scrollListener) return;
    window.removeEventListener("scroll", scrollListener);
    scrollListener = null;
  }

  function attachScrollListener(thresholdPx) {
    scrollThresholdPx = thresholdPx;
    if (scrollListener) return;
    scrollListener = () => {
      if (window.scrollY >= scrollThresholdPx) {
        detachScrollListener();
        showOverlay();
      }
    };
    window.addEventListener("scroll", scrollListener, { passive: true });
  }

  function getContext() {
    if (!isFeedModeActive()) return null;
    if (isHomeFeed()) return "home";
    return null;
  }

  function check() {
    if (blockReelsPlayer()) return;
    updateMobileReelsTabs();
    markReelsTabs();
    const ctx = getContext();
    if (ctx !== currentContext) {
      // Context switched — drop any in-flight overlay/trigger from the previous one.
      detachScrollListener();
      removeOverlay();
      currentContext = ctx;
    }
    if (ctx === "home") {
      attachScrollListener(window.innerHeight * SCROLL_TRIGGER_VH_HOME);
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", check, { once: true });
  } else {
    check();
  }

  // A blocked player can return from Safari's back/forward cache with this
  // content-script instance intact. Recheck it instead of retaining the latch.
  window.addEventListener("pageshow", () => {
    reelsPlayerBlocked = false;
    check();
  });

  // Facebook is an SPA — URL changes without a reload. Re-evaluate on a timer so
  // leaving the home feed tears down the trigger and any open overlay.
  setInterval(check, 400);
})();
