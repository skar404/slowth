(function () {
  const ns = globalThis.Unscroll;
  const routeHosts = {
    instagram: ["instagram.com", "www.instagram.com"],
    facebook: ["facebook.com", "www.facebook.com", "m.facebook.com"],
    tiktok: ["tiktok.com", "www.tiktok.com", "m.tiktok.com"],
    threads: ["threads.net", "www.threads.net", "threads.com", "www.threads.com"],
    reddit: ["reddit.com", "www.reddit.com"],
    linkedin: ["linkedin.com", "www.linkedin.com"]
  };

  function feedDestination(site, url, settings) {
    if (settings.all || !routeHosts[site]?.includes(url.hostname)) return null;
    const path = url.pathname;
    if (site === "reddit" && settings.oldReddit) {
      return "https://old.reddit.com" + path + url.search + url.hash;
    }
    if (url.hash) return null;
    // Root URLs with action, login, share or filter parameters are deliberate destinations.
    const homeQuery = [...url.searchParams.keys()].every(key => /^(utm_.*|fbclid|igsh|ref_src)$/.test(key));
    if (site === "facebook" && settings.facebookFeeds && homeQuery && ["/", "/home.php"].includes(path)) {
      return "/?filter=all&sk=h_chr";
    }
    if (site === "linkedin" && settings.networkFeed && /^\/feed\/foryou\/?$/.test(path)) return "/feed/network/";
    if (!settings.following || !homeQuery) return null;
    if (site === "instagram" && path === "/") return "/?variant=following";
    if (site === "threads" && path === "/") return "/following";
    if (site === "tiktok" && /^\/(?:foryou\/?|(?:[a-z]{2}|fil|haw|ceb)(?:-[a-zA-Z0-9]{2,4}){0,2}\/?)?$/.test(path)) return "/following";
    return null;
  }

  // All selectors are scoped to the feature and site. Never hide an entire sidebar
  // containing search, an account menu, live chat, or the playlist queue.
  const selectors = {
    youtube: { hideRelated: ["ytd-watch-next-secondary-results-renderer", "ytm-watch-next-secondary-results-renderer",
      "ytm-item-section-renderer[section-identifier='related-items']", ".ytp-fullscreen-grid", ".ytp-endscreen-content"] },
    instagram: { hideSuggestions: ["main aside:has(a[href^='/explore/people'])",
      "main:has(article) div:not(:has(article)):has(a[href^='/explore/people'])"] },
    x: { hideSuggestions: ["[data-testid='sidebarColumn'] [data-testid='trend']",
      "[data-testid='sidebarColumn'] [data-testid='UserCell']", "[data-testid='sidebarColumn'] aside:has([data-testid='UserCell'])"] },
    tiktok: { hideUpsells: ["#top-right-action-bar a[href*='/coin']", "[data-e2e='get-coins']",
      "#top-right-action-bar [data-e2e='get-app']", "[data-e2e='get-app-cta']", "#top-right-action-bar a[href*='/download']"] },
    reddit: { hidePromoted: ["shreddit-ad-post", "shreddit-sidebar-ad", "shreddit-dynamic-ad-link", "advertise-button"],
      hideRecommendations: ["games-section-badge-controller", "games-section-badge-wrapper"] },
    linkedin: { hideNews: ["main aside:has(a[href*='/news/story'])", "main aside:has(a[href*='/games/'])"] }
  };

  const marker = "slowth.feedSwitch.v1";
  function switchFeed(target) {
    // The same tab can be returned to the start by a signed-out site. Bound retries
    // across reloads. Only store a known feed path, never the referring URL.
    const destination = new URL(target, location.href);
    // Keep only a fixed route marker for cross-origin old Reddit jumps.
    const path = destination.origin === location.origin ? target : destination.origin;
    try {
      const previous = JSON.parse(sessionStorage.getItem(marker));
      if (previous?.path === path && Date.now() - previous.time < 8000) return;
      sessionStorage.setItem(marker, JSON.stringify({ path, time: Date.now() }));
    } catch (_) {}
    location.replace(destination.href);
  }

  function switchedOnArrival() {
    try {
      const saved = JSON.parse(sessionStorage.getItem(marker));
      if (saved && !saved.shown && Date.now() - saved.time < 30000 &&
          saved.path === location.pathname + location.search) {
        sessionStorage.setItem(marker, JSON.stringify({ ...saved, shown: true }));
        return true;
      }
    } catch (_) {}
    return false;
  }

  function remind() {
    const api = globalThis.browser || globalThis.chrome;
    api.runtime.sendMessage({ type: "feed-switched" }, show => {
      if (api.runtime.lastError || !show || !document.body) return;
      const badge = document.createElement("button");
      badge.type = "button";
      badge.textContent = "Slowth · " + ns.i18n.t("feedChanged");
      badge.style.cssText = "position:fixed;bottom:20px;inset-inline-end:16px;z-index:2147483647;background:#292343;color:white;padding:8px 14px;border:0;border-radius:20px;font:14px system-ui;cursor:pointer";
      badge.onclick = () => {
        api.runtime.sendMessage({ type: "open-feed-settings" });
        badge.remove();
      };
      document.body.appendChild(badge);
      setTimeout(() => badge.remove(), 4500);
    });
  }

  function feedTabs(site) {
    if (site === "reddit" && location.pathname === "/") {
      const bar = document.querySelector("shreddit-feed-tabs");
      if (!bar) return null;
      const from = bar.querySelector('[data-feed-token="for-you"]');
      const to = bar.querySelector('[data-feed-token="following"]');
      return { from, to, selected: node => node?.hasAttribute("faceplate-tab-selected") };
    }
    if (site === "x" && ["/", "/home"].includes(location.pathname)) {
      const tabs = [...document.querySelectorAll("main [role='tablist'] [role='tab']")];
      const named = (tab, re) => re.test((tab.getAttribute("aria-label") || tab.textContent).trim());
      return { from: tabs.find(tab => named(tab, /^(for you|для вас|para ti|pour vous|für dich|per te|para você|おすすめ|추천|为你推荐|為你推薦)$/i)),
        to: tabs.find(tab => named(tab, /^(following|подписки|вы читаете|siguiendo|abonnements|folge ich|seguiti|seguindo|フォロー中|팔로잉|正在关注|正在關注)$/i)),
        selected: node => node?.getAttribute("aria-selected") === "true" };
    }
    return null;
  }

  // Shadow trees do not inherit a document stylesheet. Mark the Trending group up
  // to the next section header so Recent and ordinary search results stay usable.
  function updateRedditSearch(enabled, roots) {
    for (const [root, observer] of roots) {
      if (enabled && root.host.isConnected) continue;
      observer.disconnect();
      root.querySelector("style[data-slowth-search]")?.remove();
      root.querySelectorAll("[data-slowth-trending]").forEach(el => el.removeAttribute("data-slowth-trending"));
      roots.delete(root);
    }
    if (!enabled) return;
    for (const host of document.querySelectorAll("reddit-search-large, reddit-search-small")) {
      const root = host.shadowRoot;
      if (!root || roots.has(root)) continue;
      const style = document.createElement("style");
      style.dataset.slowthSearch = "";
      style.textContent = "[data-slowth-trending]{display:none!important}";
      root.appendChild(style);
      const mark = () => {
        const section = new Set();
        for (const heading of root.querySelectorAll('[id$="_trending_query"]')) {
          section.add(heading);
          for (let item = heading.nextElementSibling; item && !item.id.startsWith("section_"); item = item.nextElementSibling) {
            if (item !== style) section.add(item);
          }
        }
        for (const previous of root.querySelectorAll("[data-slowth-trending]")) {
          if (!section.has(previous)) previous.removeAttribute("data-slowth-trending");
        }
        for (const item of section) item.setAttribute("data-slowth-trending", "");
      };
      const observer = new MutationObserver(mark);
      observer.observe(root, {childList: true, subtree: true, attributes: true, attributeFilter: ["id"]});
      roots.set(root, observer);
      mark();
    }
  }

  function linkedInFeed() {
    return document.querySelector("main [data-testid='mainFeed'], main [data-testid='NetworkFeedListCollection']");
  }

  function updateLinkedInPosts(feed, enabled, scanned) {
    for (const post of feed?.children || []) {
      if (enabled && scanned.has(post)) continue;
      if (enabled) scanned.add(post);
      else scanned.delete(post);
      // Match standalone disclosure labels. A normal post may mention an advertiser.
      const promoted = enabled && [...post.querySelectorAll("span,p,a")].some(label =>
        /^(promoted(?:\s*[•·].*)?|recommended for you|grow your business on linkedin|реклама(?:\s*[•·].*)?|продвигается|рекомендуем вам|рекомендовано для вас)$/i.test(label.textContent.trim()));
      post.toggleAttribute("data-slowth-promoted", !!promoted);
    }
  }

  function install(site) {
    let settings = {};
    let sheet;
    let scheduled = false;
    let observer;
    let clickedAt = 0;
    let pendingTab = false;
    let sortMenuAt = 0;
    let awaitingRecent = false;
    let arrivalChecked = false;
    const scanned = new WeakSet();
    const searchRoots = new Map();
    let lastTarget;
    function check() {
      scheduled = false;
      if (!document.body) return;
      const restricted = settings.all;
      const url = new URL(location.href);
      const dest = feedDestination(site, url, settings);
      if (dest && lastTarget !== url.href) {
        lastTarget = url.href;
        switchFeed(dest);
        return;
      }
      if (!dest) lastTarget = null;
      if (!arrivalChecked) {
        arrivalChecked = true;
        if (switchedOnArrival() && !restricted) remind();
      }
      const now = Date.now();
      const tabs = settings.following && !restricted && feedTabs(site);
      if (tabs?.to && tabs.from) {
        if (pendingTab && tabs.selected(tabs.to)) {
          pendingTab = false;
          if (now - clickedAt < 3000) remind();
        }
        if (tabs.selected(tabs.from) && now - clickedAt > 1500) {
          clickedAt = now;
          pendingTab = true;
          tabs.to.click();
          schedule();
        }
      } else pendingTab = false;
      if (site === "youtube" && settings.autoplayOff && !restricted && url.pathname === "/watch") {
        const toggle = document.querySelector(".ytp-autonav-toggle-button[aria-checked='true'],button.ytm-autonav-toggle-button[aria-pressed='true'],ytm-autonav-toggle-button-renderer [aria-pressed='true'],ytm-autonav-toggle-button-renderer [aria-checked='true']");
        if (toggle && now - clickedAt > 1500) {
          clickedAt = now;
          (toggle.closest("button") || toggle).click();
        }
      }
      if (site === "reddit") updateRedditSearch(!restricted && settings.hideRecommendations, searchRoots);
      if (site === "linkedin") {
        const feed = linkedInFeed();
        const isFeed = /^\/feed(?:\/(?:foryou|network))?\/?$/.test(url.pathname);
        if (settings.hidePromoted) updateLinkedInPosts(feed, isFeed && !restricted, scanned);
        if (settings.networkFeed && !restricted && /^\/feed\/?$/.test(url.pathname) && feed) {
          const row = feed.children[2];
          const trigger = row?.querySelector("button,[role=button]");
          if (awaitingRecent && /recent|сначала новые|недавние|последние/i.test(row?.textContent || "")) {
            awaitingRecent = false;
            remind();
          }
          if (sortMenuAt && now - sortMenuAt < 2000) {
            const recent = [...document.querySelectorAll('[role="menuitem"]')].find(item =>
              item.getClientRects().length && /^(recent|сначала новые|недавние|последние)$/i.test(item.textContent.trim()));
            if (recent) {
              sortMenuAt = 0;
              awaitingRecent = true;
              recent.click();
              schedule();
            }
          } else if (trigger && /\btop\b|сначала популярные|по популярности/i.test(row.textContent) && now - clickedAt > 5000) {
            clickedAt = now;
            sortMenuAt = now;
            trigger.click();
          }
        }
      }
    }
    function schedule() {
      if (scheduled) return;
      scheduled = true;
      requestAnimationFrame(check);
    }
    const navEvents = ["pageshow", "popstate", "yt-navigate-finish"];
    if (site === "reddit") navEvents.push("focusin");
    function update(next) {
      if (site === "linkedin" && settings.hidePromoted && (!next.hidePromoted || next.all)) {
        updateLinkedInPosts(linkedInFeed(), false, scanned);
      }
      settings = next;
      const active = !next.all && Object.keys(next).some(key => next[key] &&
        !["all", "shorts", "stories", "feed"].includes(key));
      const css = [];
      for (const [feature, rules] of Object.entries(selectors[site] || {})) {
        if (!next.all && next[feature]) css.push(...rules);
      }
      if (site === "linkedin" && !next.all && next.hidePromoted) css.push('[data-testid="mainFeed"] > [data-slowth-promoted], [data-testid="NetworkFeedListCollection"] > [data-slowth-promoted]');
      const text = css.map(selector => selector + "{display:none!important}").join("\n");
      if (text && !sheet) {
        sheet = document.createElement("style");
        document.documentElement.appendChild(sheet);
      }
      if (sheet && sheet.textContent !== text) sheet.textContent = text;
      if (!active) {
        observer?.disconnect();
        observer = null;
        navEvents.forEach(name => window.removeEventListener(name, schedule));
        window.navigation?.removeEventListener("navigatesuccess", schedule);
        if (sheet) { sheet.remove(); sheet = null; }
        if (site === "reddit") updateRedditSearch(false, searchRoots);
        sortMenuAt = 0;
        awaitingRecent = false;
        lastTarget = null;
        pendingTab = false;
        return;
      }
      if (!observer) {
        observer = new MutationObserver(records => {
          if (site === "linkedin" && settings.hidePromoted) {
            for (const record of records) {
              const element = record.target.nodeType === Node.TEXT_NODE ? record.target.parentElement : record.target;
              const post = element?.closest('[data-testid="mainFeed"] > *, [data-testid="NetworkFeedListCollection"] > *');
              if (post) scanned.delete(post);
            }
          }
          schedule();
        });
        observer.observe(document.documentElement, { subtree: true, childList: true, characterData: site === "linkedin", attributes: true,
          attributeFilter: ["aria-selected", "aria-checked", "aria-pressed", "faceplate-tab-selected"] });
        navEvents.forEach(name => window.addEventListener(name, schedule));
        window.navigation?.addEventListener("navigatesuccess", schedule);
      }
      schedule();
    }
    return update;
  }
  ns.feedFilters = { install, feedDestination, switchFeed };
})();
