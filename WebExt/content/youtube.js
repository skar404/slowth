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
    style.textContent = [
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
