(function () {
  const ns = globalThis.Unscroll;
  const api = (typeof browser !== "undefined" ? browser : chrome);
  const { t } = ns.i18n;
  const OVERLAY_ID = "unscroll-block-overlay";
  const STYLE_ID = "unscroll-block-overlay-style";
  const LOCK_ID = "unscroll-tiktok-scroll-lock";
  const LOCK_ATTR = "data-unscroll-tiktok-scroll-lock";
  const SCROLL_LIMIT = 4;
  let feedBlocked = false;
  let visitRoute = null;
  let screensScrolled = 0;
  let positions = new WeakMap();
  const lockedScrollers = new Set();

  function feedRoute() {
    // Profile, search, inbox and directly opened videos remain usable.
    const path = location.pathname.replace(/\/$/, "");
    return ["", "/foryou", "/following", "/friends"].includes(path) ? path || "/" : null;
  }

  function feedScrollers() {
    const scrollers = new Set();
    if (document.scrollingElement) scrollers.add(document.scrollingElement);
    // Video feeds may scroll a nested snap container while window.scrollY
    // stays at zero. Only inspect video ancestors, never comments or menus.
    for (const video of document.querySelectorAll("video")) {
      if (!video.getClientRects().length) continue;
      for (let node = video.parentElement; node && node !== document.documentElement; node = node.parentElement) {
        if (node === document.body || node.clientHeight < window.innerHeight / 2 ||
            node.clientWidth < window.innerWidth / 2 || node.scrollHeight <= node.clientHeight) continue;
        if (/^(auto|scroll)$/.test(getComputedStyle(node).overflowY) || lockedScrollers.has(node)) scrollers.add(node);
      }
    }
    return scrollers;
  }

  function resetVisit() {
    removeOverlay();
    screensScrolled = 0;
    positions = new WeakMap();
  }

  function ensureStyle() {
    if (document.getElementById(STYLE_ID)) return;
    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = ns.content.overlayCSS(OVERLAY_ID);
    document.documentElement.appendChild(style);
  }

  function removeOverlay() {
    document.getElementById(OVERLAY_ID)?.remove();
    document.getElementById(LOCK_ID)?.remove();
    feedBlocked = false;
    for (const scroller of lockedScrollers) scroller.removeAttribute(LOCK_ATTR);
    lockedScrollers.clear();
  }

  function showOverlay() {
    if (document.getElementById(OVERLAY_ID)) return;
    ensureStyle();
    const wrap = document.createElement("div");
    wrap.id = OVERLAY_ID;
    wrap.setAttribute("role", "dialog");
    wrap.setAttribute("aria-modal", "true");
    wrap.setAttribute("aria-labelledby", "unscroll-feed-title");
    wrap.innerHTML =
      '<main class="uo-main">' +
        '<div class="uo-icon"><img alt="Slowth"></div>' +
        '<h1 id="unscroll-feed-title" class="host"></h1>' +
        '<p class="uo-lede"></p>' +
        '<button class="uo-btn" type="button"></button>' +
        '<div class="uo-signature"></div>' +
      '</main>';
    ns.i18n.setLocale(wrap);
    wrap.querySelector("h1").textContent = t("feedTitle");
    wrap.querySelector(".uo-lede").textContent = t("feedSubtitle");
    wrap.querySelector(".uo-signature").textContent = t("signature");
    wrap.querySelector("img").src = api.runtime.getURL("images/icon-128.png");
    const home = wrap.querySelector(".uo-btn");
    home.textContent = t("backHome");
    home.addEventListener("click", () => {
      resetVisit();
      for (const scroller of feedScrollers()) scroller.scrollTop = 0;
      // Reset before a full navigation, including when already at exactly /.
      // This also keeps Safari from restoring this visit at the old offset.
      window.scrollTo({ top: 0, left: 0, behavior: "instant" });
      location.href = "/";
    });
    // Keep site-owned inline styles intact when the limit is disabled.
    const lock = document.createElement("style");
    lock.id = LOCK_ID;
    lock.textContent = `html,body,[${LOCK_ATTR}]{overflow:hidden!important;overscroll-behavior:none!important;}`;
    document.documentElement.appendChild(lock);
    document.documentElement.appendChild(wrap);
    home.focus({ preventScroll: true });
  }

  function checkFeed() {
    const route = feedRoute();
    if (!ns.content.featureEnabled("tiktok", "feed") || route === null) {
      resetVisit();
      visitRoute = null;
      return;
    }
    if (route !== visitRoute) {
      resetVisit();
      visitRoute = route;
    }
    const scrollers = feedScrollers();
    for (const scroller of scrollers) {
      const height = scroller === document.scrollingElement ? window.innerHeight : scroller.clientHeight;
      if (!(height > 0)) continue;
      const top = Math.max(0, scroller.scrollTop);
      const previous = positions.get(scroller) ?? 0;
      // Count forward travel even when a virtualized feed recycles its items
      // and moves the scroll offset back before it can reach four screens.
      screensScrolled += Math.max(0, top - previous) / height;
      positions.set(scroller, top);
    }
    if (screensScrolled >= SCROLL_LIMIT) feedBlocked = true;
    if (!feedBlocked) return;
    for (const scroller of scrollers) {
      scroller.setAttribute(LOCK_ATTR, "");
      lockedScrollers.add(scroller);
    }
    showOverlay();
    // Stop autoplay behind the limit, including replacement videos in an SPA.
    for (const video of document.querySelectorAll("video")) {
      if (!video.paused) video.pause();
    }
  }

  ns.content.siteContentScript("tiktok", { onStateApplied: checkFeed });
  document.addEventListener("scroll", checkFeed, { capture: true, passive: true });
  document.addEventListener("play", event => {
    if (feedBlocked && event.target.tagName === "VIDEO") event.target.pause();
  }, true);
  for (const event of ["wheel", "touchmove", "keydown"]) {
    document.addEventListener(event, e => {
      if (!feedBlocked || document.getElementById(OVERLAY_ID)?.contains(e.target)) return;
      if (event !== "keydown" || ["ArrowDown", "ArrowUp", "PageDown", "PageUp", "Home", "End", " "].includes(e.key)) e.preventDefault();
    }, { capture: true, passive: false });
  }
  for (const event of ["popstate", "pageshow", "resize"]) window.addEventListener(event, checkFeed);
  document.addEventListener("DOMContentLoaded", checkFeed, { once: true });
  // Also detect SPA navigation, replaced scrollers and restored offsets.
  setInterval(checkFeed, 400);
})();
