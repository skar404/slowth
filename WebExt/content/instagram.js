(function () {
  const { t, locale } = globalThis.Unscroll.i18n;
  const ns = globalThis.Unscroll;
  const api = (typeof browser !== "undefined" ? browser : chrome);
  ns.content.siteContentScript("instagram");

  const OVERLAY_ID = "unscroll-block-overlay";
  const STYLE_ID = "unscroll-block-overlay-style";

  // Per-context input thresholds — number of swipe/wheel/key events to allow
  // before firing the overlay. Stories are short auto-advancing clips, so we
  // let the user see a few before nudging.
  const SCROLL_TRIGGER_VH_CHAIN = 0.85;
  const SCROLL_TRIGGER_VH_HOME = 4;
  const INPUT_THRESHOLD_DM = 1;
  const INPUT_THRESHOLD_STORIES = 3;
  const VERT_VIDEO_RATIO = 1.4;
  const VERT_VIDEO_VH = 0.4;

  let scrollListener = null;
  let scrollThresholdPx = 0;
  let inputListeners = null;
  let inputCounter = 0;
  let inputThreshold = 1;
  // Time spent in the current stories session — reset only on URL leave.
  let storiesStartedAt = 0;

  function isFeedModeActive() {
    return globalThis.Unscroll.content.featureEnabled("instagram", "feed");
  }

  function isInfiniteFeedUrl() {
    return /[?&]chaining=true(?:&|$)/.test(location.search);
  }

  function isStoriesViewer() {
    return location.pathname.startsWith("/stories/");
  }

  function isHomeFeed() {
    const p = location.pathname;
    return p === "/" || p === "";
  }

  function isExploreFeed() {
    return location.pathname.startsWith("/explore");
  }

  function isReelViewerOpen() {
    if (!location.pathname.startsWith("/direct/")) return false;
    const vh = window.innerHeight;
    for (const v of document.querySelectorAll("video")) {
      if (v.offsetParent === null) continue;
      const r = v.getBoundingClientRect();
      if (r.height >= vh * VERT_VIDEO_VH && r.height > r.width * VERT_VIDEO_RATIO) {
        return true;
      }
    }
    return false;
  }


  function buildLede() {
    if (isStoriesViewer() && storiesStartedAt) {
      return t("storiesTime", globalThis.Unscroll.i18n.duration(Date.now() - storiesStartedAt));
    }
    return t("feedSubtitle");
  }

  function ensureStyle() {
    if (document.getElementById(STYLE_ID)) return;
    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = ns.content.overlayCSS(OVERLAY_ID, true);
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
    const lede = buildLede();
    // Stories is a soft "you've been here a while" nudge — let the user dismiss
    // and keep watching. Other contexts (chained reels, DM reel viewer, home
    // feed) are hard blocks: only "Back to home" gets you out.
    const dismissable = currentContext === "stories";
    wrap.innerHTML =
      (dismissable ? '<button class="uo-close" type="button" aria-label="Dismiss">\u00d7</button>' : '') +
      '<main class="uo-main">' +
        '<div class="uo-icon"><img alt="Slowth"></div>' +
        '<h1 class="host"></h1>' +
        '<p class="uo-lede"></p>' +
        '<button class="uo-btn" type="button"></button>' +
        '<div class="uo-signature">Slowth \u00b7 slow down, breathe, build</div>' +
      '</main>';
    ns.i18n.setLocale(wrap);
    wrap.querySelector("h1").textContent = t("feedTitle");
    wrap.querySelector(".uo-btn").textContent = t("backHome");
    wrap.querySelector(".uo-signature").textContent = t("signature");
    const close = wrap.querySelector(".uo-close");
    if (close) close.setAttribute("aria-label", t("dismiss"));
    wrap.querySelector("img").src = iconUrl;
    wrap.querySelector(".uo-lede").textContent = lede;
    root.appendChild(wrap);
    if (document.body) document.body.style.overflow = "hidden";
    root.style.overflow = "hidden";
    wrap.querySelector(".uo-btn").addEventListener("click", () => {
      location.href = "/";
    });
    if (dismissable) {
      wrap.querySelector(".uo-close").addEventListener("click", dismissOverlay);
    }
  }

  function removeOverlay() {
    const div = document.getElementById(OVERLAY_ID);
    if (div) div.remove();
    if (document.body) document.body.style.overflow = "";
    document.documentElement.style.overflow = "";
  }

  // Close button — keep the user on the page but re-arm the trigger so the
  // nudge can fire again the next time they cross the threshold.
  function dismissOverlay() {
    removeOverlay();
    inputCounter = 0;
    check();
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
        detachAllTriggers();
        showOverlay();
      }
    };
    window.addEventListener("scroll", scrollListener, { passive: true });
  }

  function detachInputListeners() {
    if (!inputListeners) return;
    window.removeEventListener("wheel", inputListeners.wheel);
    window.removeEventListener("keydown", inputListeners.keydown);
    window.removeEventListener("touchstart", inputListeners.touchstart);
    window.removeEventListener("touchmove", inputListeners.touchmove);
    inputListeners = null;
  }

  function inputTick() {
    if (!inputListeners) return;
    inputCounter++;
    if (inputCounter >= inputThreshold) {
      detachAllTriggers();
      showOverlay();
    }
  }

  function attachInputListeners(threshold) {
    inputThreshold = threshold || 1;
    if (inputListeners) return;
    inputCounter = 0;
    let touchStartY = null;
    let lastWheelTickAt = 0;
    // One physical mouse-wheel gesture fires a burst of events (5-20). Count
    // the burst as a single tick so a 3-event threshold doesn't trip on the
    // very first scroll.
    const WHEEL_BURST_MS = 250;
    const tick = inputTick;
    inputListeners = {
      wheel: (e) => {
        if (e.deltaY <= 5) return;
        const now = Date.now();
        if (now - lastWheelTickAt < WHEEL_BURST_MS) return;
        lastWheelTickAt = now;
        tick();
      },
      keydown: (e) => {
        const k = e.key;
        if (k === "ArrowDown" || k === "ArrowRight" ||
            k === "PageDown" || k === "End" ||
            k === " " || k === "Spacebar") tick();
      },
      touchstart: (e) => { touchStartY = e.touches && e.touches[0] ? e.touches[0].clientY : null; },
      touchmove: (e) => {
        const t = e.touches && e.touches[0];
        if (touchStartY != null && t && touchStartY - t.clientY > 20) {
          tick();
          touchStartY = null;
        }
      }
    };
    window.addEventListener("wheel", inputListeners.wheel, { passive: true });
    window.addEventListener("keydown", inputListeners.keydown, { passive: true });
    window.addEventListener("touchstart", inputListeners.touchstart, { passive: true });
    window.addEventListener("touchmove", inputListeners.touchmove, { passive: true });
  }

  function detachAllTriggers() {
    detachScrollListener();
    detachInputListeners();
  }

  function getContext() {
    if (!isFeedModeActive()) return null;
    if (isStoriesViewer()) return "stories";
    if (isInfiniteFeedUrl()) return "chaining";
    if (isReelViewerOpen()) return "dm-reel";
    if (isHomeFeed()) return "home";
    if (isExploreFeed()) return "explore";
    return null;
  }

  let currentContext = null;

  function check() {
    const ctx = getContext();
    if (ctx !== currentContext) {
      // Context switched — drop any in-flight overlay/trigger from the previous one.
      detachAllTriggers();
      removeOverlay();
      currentContext = ctx;
    }
    if (ctx === "stories") {
      if (!storiesStartedAt) storiesStartedAt = Date.now();
      attachInputListeners(INPUT_THRESHOLD_STORIES);
      detachScrollListener();
    } else if (ctx === "chaining") {
      attachScrollListener(window.innerHeight * SCROLL_TRIGGER_VH_CHAIN);
      detachInputListeners();
    } else if (ctx === "dm-reel") {
      attachInputListeners(INPUT_THRESHOLD_DM);
      detachScrollListener();
    } else if (ctx === "home" || ctx === "explore") {
      attachScrollListener(window.innerHeight * SCROLL_TRIGGER_VH_HOME);
      detachInputListeners();
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", check, { once: true });
  } else {
    check();
  }

  let lastHref = location.href;
  let lastPathWasStories = isStoriesViewer();
  setInterval(() => {
    if (location.href !== lastHref) {
      const nowStories = isStoriesViewer();
      // IG auto-advances stories without firing wheel/key/touch — count every
      // story change (auto-play or click) as one input tick while we're still
      // in the stories context.
      if (lastPathWasStories && nowStories) inputTick();
      lastHref = location.href;
      lastPathWasStories = nowStories;
      if (!nowStories) storiesStartedAt = 0;
    }
    // Re-evaluate every tick — DM reel viewer can mount/unmount without a URL change,
    // and stories advance via SPA pushState without leaving the context.
    check();
  }, 400);
})();
