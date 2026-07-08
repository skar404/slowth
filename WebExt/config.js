(function () {
  const ns = (globalThis.Unscroll = globalThis.Unscroll || {});

  ns.CONFIG_URL =
    "https://gist.githubusercontent.com/skar404/485fdd43d2d94b068a6869fa0670fce9/raw/unscroll_v0.json";

  ns.SITES = ["youtube", "instagram", "tiktok", "facebook", "x"];

  // ⚠️ KEEP MODES IN SYNC with the Swift host-app settings UI (a separate, parallel
  // implementation of the same per-site modes):
  //   Shared/SharedStore.swift  — `SiteMode` enum (raw values must match these strings)
  //                               + `defaultState` (mirrors DEFAULT_TOGGLES below).
  //   Shared/ContentView_iOS.swift / ContentView_macOS.swift — `sites` arrays (mirror
  //                               SITE_AVAILABLE_MODES) + `modeLabel()` (mirrors app.js).
  // Adding a mode here without updating Swift = popup and host app disagree.
  ns.MODES = { OFF: "off", SHORTS: "shorts", FEED: "feed", ALL: "all" };

  ns.SITE_AVAILABLE_MODES = {
    youtube:   ["off", "shorts", "all"],
    instagram: ["off", "shorts", "feed", "all"],
    tiktok:    ["off", "all"],
    facebook:  ["off", "shorts", "feed", "all"],
    x:         ["off", "shorts", "all"]
  };

  ns.DEFAULT_TOGGLES = {
    youtube:   "shorts",
    instagram: "feed",
    tiktok:    "all",
    facebook:  "feed",
    x:         "shorts"
  };

  ns.SITE_LABELS = {
    youtube:   "YouTube Shorts",
    instagram: "Instagram Reels",
    tiktok:    "TikTok",
    facebook:  "Facebook Reels",
    x:         "X (Twitter)"
  };

  ns.DEFAULT_RULES = {
    version: 8,
    youtube: {
      redirects: [
        { from: "^/shorts/([\\w-]+)", to: "/watch?v=$1" }
      ],
      hideSelectors: [
        "ytm-pivot-bar-item-renderer:has(.pivot-shorts)",
        "ytm-pivot-bar-item-renderer[data-unscroll-hidden]",
        ".pivot-bar-item-tab.pivot-shorts",
        ".pivot-bar-item-title.pivot-shorts",
        "ytm-reel-shelf-renderer",
        "ytd-mini-guide-entry[aria-label=\"Shorts\"]",
        "ytd-mini-guide-entry-renderer:has(a[title=\"Shorts\"])",
        "ytd-search :is(ytd-video-renderer, ytd-shelf-renderer):has(a[href*=\"/shorts/\"])",
        "ytd-compact-video-renderer:has(a[href*=\"/shorts/\"])",
        "ytd-reel-item-renderer",
        "ytd-mini-guide-entry-renderer:has(a[href=\"/shorts/\"])",
        "ytd-mini-guide-entry[aria-label=\"Shorts\"]",
        "ytm-pivot-bar-item-renderer:has(a[title=\"Shorts\"])",
        "ytd-mini-guide-entry-renderer:has(a[aria-label=\"Shorts\"])",
        "ytm-video-with-context-renderer:has(a[href*=\"/shorts/\"])",
        "ytm-shorts-lockup-view-model",
        "ytd-rich-item-renderer:has(a[href*=\"/shorts/\"])",
        "ytm-pivot-bar-item-renderer:has(a[href=\"/shorts/\"])",
        "ytm-pivot-bar-item-renderer:has(a[aria-label=\"Shorts\"])",
        "ytm-rich-item-renderer:has(a[href*=\"/shorts/\"])",
        "ytd-video-renderer:has(a[href*=\"/shorts/\"])",
        "ytd-guide-entry-renderer:has(a[title=\"Shorts\"])",
        "ytd-rich-shelf-renderer[is-shorts]",
        "ytm-pivot-bar-item-renderer:has(.pivot-bar-item-title.pivot-shorts)",
        "ytd-reel-shelf-renderer",
        "ytm-shorts-lockup-view-model-v2",
        "ytm-video-with-context-renderer:has(a[href*=\"/shorts/\"])",
        "grid-shelf-view-model:has(a[href*=\"/shorts/\"])",
        "grid-shelf-view-model:has(ytm-shorts-lockup-view-model-v2)",
        ".shortsLockupViewModelHost",
        "yt-chip-cloud-chip-renderer[data-unscroll-shorts]",
        "yt-tab-shape[data-unscroll-shorts]",
        "ytd-mini-guide-entry-renderer[data-unscroll-shorts]",
        "ytd-guide-entry-renderer[data-unscroll-shorts]"
      ]
    },
    instagram: {
      redirects: [
        { from: "^/reels/?$", to: "/" },
        { from: "^/reel/[^/]+/?", to: "/" }
      ],
      hideSelectors: [
        "a[href=\"/reels/\"]",
        "a[href^=\"/reels/\"]",
        "[role=\"link\"][href^=\"/reels/\"]",
        "div[role=\"menuitem\"]:has(a[href^=\"/reels/\"])"
      ]
    },
    tiktok: {
      redirects: [],
      hideSelectors: []
    },
    facebook: {
      redirects: [
        { from: "^/reel/[^/]+/?", to: "unscroll:blocked" },
        { from: "^/reels(/|$)", to: "unscroll:blocked" },
        { from: "^/watch(/|$)", to: "unscroll:blocked" },
        { from: "^/video(/|$)", to: "unscroll:blocked" }
      ],
      hideSelectors: [
        "a[href^=\"/reel/\"]",
        "a[href^=\"/reels/\"]",
        "a[href=\"/reels/\"]",
        "a[href=\"/watch/\"]",
        "a[href^=\"/video\"]",
        "a[aria-label=\"Reels\"]",
        "[role=\"navigation\"] a[href*=\"/reels\"]",
        "[role=\"navigation\"] li:has(a[aria-label=\"Reels\"])",
        "div[aria-label=\"Reels\"]",
        "div[aria-label=\"Reels and short videos\"]",
        "div[role=\"main\"] [aria-label=\"Reels and short videos\"]",
        "div[data-pagelet=\"VideoChainingFeedUnit\"]",
        "div[data-pagelet^=\"Reels\"]",
        "div[data-pagelet*=\"Reels\"]",
        "div[role=\"feed\"] > div:has(a[href^=\"/reel/\"])",
        "div[role=\"article\"]:has(a[href^=\"/reel/\"])"
      ]
    },
    x: {
      redirects: [
        { from: "^/i/trends", to: "/home" },
        { from: "^/explore(/|$)", to: "/home" }
      ],
      hideSelectors: [
        "[data-testid=\"sidebarColumn\"] [aria-label=\"Trending\"]",
        "[data-testid=\"trend\"]",
        "a[href=\"/explore\"]",
        "[data-testid=\"primaryColumn\"] [role=\"tablist\"] a[href=\"/home\"][aria-selected=\"false\"]"
      ]
    }
  };

  ns.STORAGE_KEYS = {
    cachedState: "cachedState",
    cachedAt: "cachedAt"
  };

  ns.STATE_CACHE_TTL_MS = 30 * 1000;
  ns.MIN_REFRESH_INTERVAL_MS = 5 * 60 * 1000;
  ns.FETCH_TIMEOUT_MS = 5000;
  ns.ALARM_NAME = "unscroll-refresh-rules";
  ns.ALARM_PERIOD_MINUTES = 360;

  ns.FEEDBACK_MAILTO = "mailto:denis@malina.page?subject=Slowth%20feedback";
})();
