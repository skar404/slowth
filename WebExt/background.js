(function () {
  const ns = globalThis.Unscroll;
  const api = (typeof browser !== "undefined" ? browser : chrome);

  // Sentinel redirect target: when a shorts-mode redirect rule uses this as its
  // `to`, show blocked.html instead of navigating same-origin.
  const BLOCK_TOKEN = "unscroll:blocked";

  function getHostKey(hostname) {
    if (!hostname) return null;
    const h = hostname.toLowerCase();
    if (h === "tiktok.com"    || h.endsWith(".tiktok.com"))    return "tiktok";
    if (h === "youtube.com"   || h.endsWith(".youtube.com"))   return "youtube";
    if (h === "instagram.com" || h.endsWith(".instagram.com")) return "instagram";
    if (h === "facebook.com"  || h.endsWith(".facebook.com"))  return "facebook";
    if (h === "x.com"         || h.endsWith(".x.com"))         return "x";
    if (h === "twitter.com"   || h.endsWith(".twitter.com"))   return "x";
    return null;
  }

  function applyRedirect(pathname, search, redirects) {
    const target = pathname + (search || "");
    for (const rule of redirects || []) {
      let re;
      try { re = new RegExp(rule.from); } catch (_) { continue; }
      if (re.test(target)) {
        if (rule.to === BLOCK_TOKEN) return BLOCK_TOKEN;
        return target.replace(re, rule.to);
      }
    }
    return null;
  }

  async function broadcastUpdated() {
    try {
      const tabs = await new Promise((resolve) =>
        api.tabs.query({}, (t) => resolve(t || []))
      );
      for (const tab of tabs) {
        if (!tab.id) continue;
        try {
          api.tabs.sendMessage(tab.id, { type: "unscroll-state-updated" }, () => {
            void api.runtime.lastError;
          });
        } catch (_) {}
      }
    } catch (_) {}
  }

  async function handleNavigation(details) {
    if (details.frameId !== 0) return;
    let url;
    try { url = new URL(details.url); } catch (_) { return; }

    const site = getHostKey(url.hostname);
    if (!site) return;

    const state = await ns.getStateCached();
    const mode = (state.toggles && state.toggles[site]) || "off";
    if (mode === "off") return;

    if (mode === "all") {
      const blockedUrl = api.runtime.getURL("blocked.html") + "?host=" + site;
      if (details.url === blockedUrl) return;
      api.tabs.update(details.tabId, { url: blockedUrl });
      return;
    }

    if (mode === "shorts" || mode === "feed") {
      const siteRules = state.rules && state.rules[site];
      if (!siteRules) return;
      const newPath = applyRedirect(url.pathname, url.search, siteRules.redirects);
      if (newPath === BLOCK_TOKEN) {
        const blockedUrl = api.runtime.getURL("blocked.html") + "?host=" + site;
        if (details.url === blockedUrl) return;
        api.tabs.update(details.tabId, { url: blockedUrl });
        return;
      }
      if (newPath && newPath !== url.pathname + url.search) {
        const target = url.origin + newPath;
        if (target === details.url) return;
        api.tabs.update(details.tabId, { url: target });
      }
    }
  }

  api.runtime.onInstalled.addListener(async () => {
    try { api.alarms.create(ns.ALARM_NAME, { periodInMinutes: ns.ALARM_PERIOD_MINUTES }); } catch (_) {}
    await ns.refreshRules({ force: true });
    await broadcastUpdated();
  });

  if (api.runtime.onStartup) {
    api.runtime.onStartup.addListener(async () => {
      try { api.alarms.create(ns.ALARM_NAME, { periodInMinutes: ns.ALARM_PERIOD_MINUTES }); } catch (_) {}
      await ns.refreshRules({ force: false });
    });
  }

  if (api.alarms && api.alarms.onAlarm) {
    api.alarms.onAlarm.addListener(async (alarm) => {
      if (alarm && alarm.name === ns.ALARM_NAME) {
        const res = await ns.refreshRules({ force: false });
        if (res.ok && res.status === 200) await broadcastUpdated();
      }
    });
  }

  if (api.webNavigation && api.webNavigation.onBeforeNavigate) {
    api.webNavigation.onBeforeNavigate.addListener(handleNavigation);
  }
  // SPA route changes (e.g. clicking Facebook's Video/Watch tab) don't trigger
  // onBeforeNavigate — they use history.pushState. Catch those too.
  if (api.webNavigation && api.webNavigation.onHistoryStateUpdated) {
    api.webNavigation.onHistoryStateUpdated.addListener(handleNavigation);
  }

  async function handleRpc(action, payload) {
    payload = payload || {};
    switch (action) {
      case "getState": {
        const state = await ns.getStateFresh();
        return { ok: true, state };
      }
      case "setToggle": {
        const r = await ns.setToggle(payload.site, payload.value);
        if (r.ok) await broadcastUpdated();
        return r;
      }
      case "setStrictMode": {
        return await ns.setStrictMode(!!payload.enabled);
      }
      case "forceRefresh": {
        const res = await ns.refreshRules({ force: true });
        if (res.ok && res.status === 200) await broadcastUpdated();
        const state = await ns.getStateFresh();
        return { ...res, state };
      }
      case "setOnboardingDone": {
        const state = await ns.setOnboardingDone(true);
        return { ok: true, state };
      }
      case "openExtensionSettings":
      case "openAppsPicker":
      case "requestFamilyControlsAuth":
      case "clearBlockedApps":
        return { ok: false, reason: "na_in_popup" };
      default:
        return { ok: false, reason: "unknown_action" };
    }
  }

  api.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (!message || typeof message !== "object") return false;

    if (message.type === "rpc") {
      (async () => sendResponse(await handleRpc(message.action, message.payload)))();
      return true;
    }

    // Content scripts ask for the live state (toggles + rules). Answer with the
    // same cached snapshot background uses for navigation, so both sides enforce
    // the identical rule set instead of the content script falling back to
    // DEFAULT_RULES (which caused shorts-mode block/redirect to disagree).
    if (message.type === "get-state") {
      (async () => sendResponse(await ns.getStateCached()))();
      return true;
    }

    return false;
  });

  (async () => {
    try { await ns.setOnboardingDone(true); } catch (_) {}
  })();
})();
