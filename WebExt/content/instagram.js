(function () {
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
    return globalThis.Unscroll.content.currentMode("instagram") === "feed";
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

  function fmtDuration(ms) {
    const sec = Math.max(0, Math.floor(ms / 1000));
    const m = Math.floor(sec / 60);
    const s = sec % 60;
    if (m === 0) return s + " seconds";
    if (m < 60) return s ? m + " min " + s + " sec" : m + " minutes";
    const h = Math.floor(m / 60);
    return h + "h " + (m % 60) + "m";
  }

  function buildLede() {
    if (isStoriesViewer() && storiesStartedAt) {
      return "You've already burned " + fmtDuration(Date.now() - storiesStartedAt) +
        " on stories. Take a breath.";
    }
    return "Slowth is keeping you off the infinite feed. Take a breath. Do something else.";
  }

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
      "#" + OVERLAY_ID + " .uo-close{",
      "position:absolute;top:18px;right:18px;width:36px;height:36px;border-radius:50%;",
      "background:rgba(255,255,255,0.08);border:1px solid rgba(255,255,255,0.12);",
      "color:#fff;font-size:22px;line-height:1;cursor:pointer;",
      "appearance:none;display:grid;place-items:center;font-family:inherit;",
      "transition:background 0.15s ease;padding:0;",
      "}",
      "#" + OVERLAY_ID + " .uo-close:hover{background:rgba(255,255,255,0.16);}",
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
        '<h1><span class="host">infinite feed</span> is blocked</h1>' +
        '<p class="uo-lede"></p>' +
        '<button class="uo-btn" type="button">Back to home</button>' +
        '<div class="uo-signature">Slowth \u00b7 slow down, breathe, build</div>' +
      '</main>';
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
