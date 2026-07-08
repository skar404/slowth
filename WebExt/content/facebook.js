(function () {
  const api = (typeof browser !== "undefined" ? browser : chrome);
  globalThis.Unscroll.content.siteContentScript("facebook");

  const OVERLAY_ID = "unscroll-block-overlay";
  const STYLE_ID = "unscroll-block-overlay-style";

  // Same threshold Instagram uses for its home feed — let the user glance at a
  // few screens before the nudge fires.
  const SCROLL_TRIGGER_VH_HOME = 4;

  let scrollListener = null;
  let scrollThresholdPx = 0;
  let currentContext = null;

  function isFeedModeActive() {
    return globalThis.Unscroll.content.currentMode("facebook") === "feed";
  }

  function isHomeFeed() {
    const p = location.pathname;
    return p === "/" || p === "" || p === "/home.php";
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
    // Home feed is a hard block — only "Back to home" gets you out, no dismiss.
    wrap.innerHTML =
      '<main class="uo-main">' +
        '<div class="uo-icon"><img alt="Slowth"></div>' +
        '<h1><span class="host">infinite feed</span> is blocked</h1>' +
        '<p class="uo-lede"></p>' +
        '<button class="uo-btn" type="button">Back to home</button>' +
        '<div class="uo-signature">Slowth · slow down, breathe, build</div>' +
      '</main>';
    wrap.querySelector("img").src = iconUrl;
    wrap.querySelector(".uo-lede").textContent =
      "Slowth is keeping you off the infinite feed. Take a breath. Do something else.";
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

  // Facebook is an SPA — URL changes without a reload. Re-evaluate on a timer so
  // leaving the home feed tears down the trigger and any open overlay.
  setInterval(check, 400);
})();
