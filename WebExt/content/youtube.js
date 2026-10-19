(function () {
  const ns = globalThis.Unscroll;
  ns.content.siteContentScript("youtube", {
    spaEvents: ["yt-navigate-finish"],
    onStateApplied: checkFeed
  });

  // Marks DOM nodes whose visible label is plain text "Shorts" (no aria/data
  // attribute hook) so the CSS rule list can hide them. Covered surfaces:
  //   * search results filter chip — yt-chip-cloud-chip-renderer
  //   * channel page tab — yt-tab-shape
  // Bounded polling instead of a body-subtree MutationObserver to avoid
  // pathological mutation cascades on YouTube's reactive UI.
  const HIDE_ATTR = "data-unscroll-shorts";
  const TARGET_SEL =
    "ytd-search-header-renderer yt-chip-cloud-chip-renderer," +
    "ytd-feed-filter-chip-bar-renderer yt-chip-cloud-chip-renderer," +
    "yt-tab-group-shape yt-tab-shape";
  const POLL_INTERVAL_MS = 200;
  const POLL_MAX_TRIES = 25;

  function isShortsModeActive() {
    const styleEl = document.getElementById("unscroll-youtube-style");
    return !!(styleEl && styleEl.textContent && styleEl.textContent.length > 0);
  }

  function markShortsByText() {
    let marked = 0;
    for (const el of document.querySelectorAll(TARGET_SEL)) {
      if (el.hasAttribute(HIDE_ATTR)) continue;
      if ((el.textContent || "").trim() === "Shorts") {
        el.setAttribute(HIDE_ATTR, "1");
        marked++;
      }
    }
    // Sidebar entries: identify by inner anchor href so we don't depend on
    // localized labels or :has() availability.
    for (const a of document.querySelectorAll(
      "ytd-mini-guide-entry-renderer a[href='/shorts/']," +
      "ytd-guide-entry-renderer a[href='/shorts/']"
    )) {
      const renderer = a.closest("ytd-mini-guide-entry-renderer, ytd-guide-entry-renderer");
      if (renderer && !renderer.hasAttribute(HIDE_ATTR)) {
        renderer.setAttribute(HIDE_ATTR, "1");
        marked++;
      }
    }
    return marked;
  }

  let pollTimer = null;
  function startPoll() {
    if (pollTimer) return;
    if (!isShortsModeActive()) return;
    let tries = 0;
    pollTimer = setInterval(() => {
      tries++;
      markShortsByText();
      if (tries >= POLL_MAX_TRIES) {
        clearInterval(pollTimer);
        pollTimer = null;
      }
    }, POLL_INTERVAL_MS);
  }

  function onSpaNav() {
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
    startPoll();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", startPoll, { once: true });
  } else {
    startPoll();
  }
  window.addEventListener("yt-navigate-finish", onSpaNav);

  // Only the home route is limited; search, subscriptions and videos stay usable.
  const OVERLAY_ID = "unscroll-block-overlay";
  const STYLE_ID = "unscroll-block-overlay-style";
  const LOCK_ID = "unscroll-youtube-scroll-lock";
  const SCROLL_TRIGGER_VH_HOME = 4;
  const { t } = ns.i18n;
  const api = (typeof browser !== "undefined" ? browser : chrome);
  let feedBlocked = false;

  function ensureStyle() {
    if (document.getElementById(STYLE_ID)) return;
    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = ns.content.overlayCSS(OVERLAY_ID);
    document.documentElement.appendChild(style);
  }

  function removeFeedOverlay() {
    document.getElementById(OVERLAY_ID)?.remove();
    document.getElementById(LOCK_ID)?.remove();
    feedBlocked = false;
  }

  function showFeedOverlay() {
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
      removeFeedOverlay();
      // Reset before a full navigation, including when already at exactly /.
      // This also keeps Safari from restoring this visit at the old offset.
      window.scrollTo({ top: 0, left: 0, behavior: "instant" });
      location.href = "/";
    });
    // A removable stylesheet preserves the site's existing inline overflow
    // values and priorities, even if YouTube changes them while blocked.
    const lock = document.createElement("style");
    lock.id = LOCK_ID;
    lock.textContent = "html,body{overflow:hidden!important;overscroll-behavior:none!important;}";
    document.documentElement.appendChild(lock);
    document.documentElement.appendChild(wrap);
    home.focus({ preventScroll: true });
  }

  function checkFeed() {
    if (!ns.content.featureEnabled("youtube", "feed") || location.pathname !== "/") {
      removeFeedOverlay();
      return;
    }
    if (window.innerHeight > 0 && window.scrollY >= window.innerHeight * SCROLL_TRIGGER_VH_HOME) {
      feedBlocked = true;
    }
    // Keep the block latched if layout changes move the scroll position.
    if (feedBlocked) showFeedOverlay();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", checkFeed, { once: true });
  } else {
    checkFeed();
  }
  window.addEventListener("scroll", checkFeed, { passive: true });
  for (const event of ["yt-navigate-finish", "popstate", "pageshow", "resize"]) {
    window.addEventListener(event, checkFeed);
  }
  // Mobile YouTube does not emit every desktop SPA event. Also catch delayed
  // scroll restoration and URL changes that do not dispatch popstate.
  setInterval(checkFeed, 400);
})();
