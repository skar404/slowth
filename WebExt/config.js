(function () {
  const ns = (globalThis.Unscroll = globalThis.Unscroll || {});

  ns.CONFIG_URL =
    "https://gist.githubusercontent.com/skar404/485fdd43d2d94b068a6869fa0670fce9/raw/unscroll_v0.json";

  ns.SITES = ["youtube", "instagram", "tiktok", "facebook", "x"];

  // Wire keys and migration mirror Shared/SharedStore.swift.
  ns.SITE_FEATURES = {
    youtube: ["shorts", "all"],
    instagram: ["shorts", "feed", "all"],
    tiktok: ["all"],
    facebook: ["shorts", "feed", "all"],
    x: ["shorts", "all"]
  };
  ns.DEFAULT_TOGGLES = Object.fromEntries(ns.SITES.map(site => [site, {
    shorts: site !== "tiktok",
    feed: site === "instagram" || site === "facebook",
    all: site === "tiktok"
  }]));
  ns.SITE_LABELS = { youtube: "YouTube", instagram: "Instagram", tiktok: "TikTok", facebook: "Facebook", x: "X" };

  ns.normalizeSiteSettings = function (site, value) {
    const defaults = { ...ns.DEFAULT_TOGGLES[site] };
    if (value && typeof value === "object" && !Array.isArray(value)) {
      for (const feature of ns.SITE_FEATURES[site] || []) {
        if (typeof value[feature] === "boolean") defaults[feature] = value[feature];
      }
      return defaults;
    }
    // Old cached states can survive an extension update.
    if (typeof value === "boolean") value = value ? (site === "tiktok" ? "all" : "shorts") : "off";
    switch (value) {
      case "off": return { shorts: false, feed: false, all: false };
      case "shorts": return { shorts: site !== "tiktok", feed: false, all: false };
      case "feed": return { shorts: site !== "tiktok", feed: site === "instagram" || site === "facebook", all: false };
      case "all": return { ...defaults, all: true };
      default: return defaults;
    }
  };

  ns.DEFAULT_RULES = {
    // Bump when changing bundled rules. Newer bundled rules override stored rules.
    version: 16,
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
        { from: "^/reels?(/|[?#]|$)", to: "unscroll:blocked" },
        { from: "^/[^/?]+/(reels(_tab)?|owner_reels)(/|[?#]|$)", to: "unscroll:blocked" },
        { from: "^/[^/?]+/?\\?([^#]*&)?sk=reels(_tab)?(&|$)", to: "unscroll:blocked" },
        { from: "^/watch(/|$)", to: "unscroll:blocked" },
        { from: "^/video(/|$)", to: "unscroll:blocked" }
      ],
      hideSelectors: [
        "a[href^=\"/reel/\"]",
        "a[href^=\"/reels/\"]",
        "a[href^=\"https://www.facebook.com/reel/\"]",
        "a[href^=\"https://www.facebook.com/reels/\"]",
        "a[href^=\"https://m.facebook.com/reel/\"]",
        "a[href^=\"https://m.facebook.com/reels/\"]",
        "a[href^=\"https://facebook.com/reel/\"]",
        "a[href^=\"https://facebook.com/reels/\"]",
        // Facebook removes href from overflowed tabs. Hiding tabs by href makes
        // them alternate between visible/hidden every frame; facebook.js marks them.
        "a[data-unscroll-facebook-reels-tab]",
        // Mobile navigation uses a div tab with a label and unread count, no href.
        // Hide content two levels inside while preserving the tab and its wrappers.
        "[role=\"tab\"]:is([aria-label=\"reels\" i], [aria-label^=\"reels,\" i]) > * > *",
        "a:not([role=\"tab\"]):is([href$=\"/reels\"], [href*=\"/reels/\"], [href*=\"/reels?\"])",
        "a:not([role=\"tab\"]):is([href$=\"/reels_tab\"], [href*=\"/reels_tab/\"], [href*=\"/reels_tab?\"])",
        "a:not([role=\"tab\"]):is([href$=\"/owner_reels\"], [href*=\"/owner_reels/\"], [href*=\"/owner_reels?\"])",
        "a:not([role=\"tab\"]):is([href*=\"?sk=reels_tab\"], [href*=\"&sk=reels_tab\"])",
        "a[href=\"/reels/\"]",
        "a[href=\"/watch/\"]",
        "a[href^=\"/video\"]",
        "a[aria-label=\"Reels\"]",
        "[role=\"navigation\"] a[href*=\"/reels\"]",
        "[role=\"navigation\"] li:has(a[aria-label=\"Reels\"])",
        "div[aria-label=\"Reels\"]:not([role=\"tab\"])",
        "div[aria-label=\"Reels and short videos\"]",
        "div[role=\"main\"] [aria-label=\"Reels and short videos\"]",
        "div[data-pagelet=\"VideoChainingFeedUnit\"]",
        "div[data-pagelet^=\"Reels\"]",
        "div[data-pagelet*=\"Reels\"]",
        // Mobile feed cards have no reel link or article role. Remove the whole
        // feed unit containing the labeled Reels button, including its fixed height.
        "[data-type=\"vscroller\"] > [data-dcm-id]:has([role=\"button\"][aria-label*=\"Reels\" i])",
        "div[aria-posinset]:has(a:is([href^=\"/reel/\"], [href^=\"https://www.facebook.com/reel/\"], [href^=\"https://m.facebook.com/reel/\"], [href^=\"https://facebook.com/reel/\"]))",
        "div[role=\"feed\"] > div:has(a:is([href^=\"/reel/\"], [href^=\"https://www.facebook.com/reel/\"], [href^=\"https://m.facebook.com/reel/\"], [href^=\"https://facebook.com/reel/\"]))",
        "div[role=\"article\"]:has(a:is([href^=\"/reel/\"], [href^=\"https://www.facebook.com/reel/\"], [href^=\"https://m.facebook.com/reel/\"], [href^=\"https://facebook.com/reel/\"]))"
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
