(function () {
  const ns = globalThis.Unscroll;
  ns.content.siteContentScript("youtube", {
    spaEvents: ["yt-navigate-finish"]
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
})();
