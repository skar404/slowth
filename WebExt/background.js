(function () {
  const ns = globalThis.Unscroll;
  const api = (typeof browser !== "undefined" ? browser : chrome);

  // Sentinel redirect target: when a shorts-mode redirect rule uses this as its
  // `to`, show blocked.html instead of navigating same-origin.
  const BLOCK_TOKEN = "unscroll:blocked";

  function getHostKey(hostname) {
    return ns.siteForURL("https://" + hostname + "/");
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
    const settings = ns.normalizeSiteSettings(site, state.toggles?.[site]);

    if (settings.all) {
      const blockedUrl = api.runtime.getURL("blocked.html") + "?host=" + site;
      if (details.url === blockedUrl) return;
      api.tabs.update(details.tabId, { url: blockedUrl });
      return;
    }

    if (site === "instagram" && settings.stories && /^\/stories(?:\/|$)/.test(url.pathname)) {
      api.tabs.update(details.tabId, { url: url.origin + "/" });
      return;
    }

    if (settings.shorts) {
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
        const r = await ns.setToggle(payload.site, payload.feature, payload.enabled);
        if (r.ok) await broadcastUpdated();
        return r;
      }
      case "setStrictMode": {
        const result = await ns.setStrictMode(!!payload.enabled);
        if (result.ok) await broadcastUpdated();
        return result;
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

    if (message.type === "feed-switched") {
      ns.claimFeedReminder().then(sendResponse, () => sendResponse(false));
      return true;
    }
    if (message.type === "open-feed-settings") {
      const openPage = () => api.tabs.create({ url: api.runtime.getURL("app.html") });
      try { Promise.resolve(api.action.openPopup()).catch(openPage); } catch (_) { openPage(); }
      return false;
    }
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
  // Warm the native bridge on background startup, including WKWebExtension hosts.
  // The in-app browser waits for this round trip before loading a service.
  let nativePort = null;
  let reconnectPending = false;
  let verification = Promise.resolve();
  function scheduleReconnect() {
    if (reconnectPending) return;
    reconnectPending = true;
    setTimeout(() => {
      reconnectPending = false;
      connectHost();
    }, 1000);
  }
  function connectHost() {
    // Safari keeps its existing polling/notification path. Only the embedded host
    // advertises this protocol in a successful native getState reply.
    if (!ns.webAppHost || !api.runtime.connectNative || nativePort || reconnectPending) return;
    try {
      const port = api.runtime.connectNative("slowth.web-apps");
      nativePort = port;
      port.onMessage.addListener(message => {
        if (message?.type !== "verify" || typeof message.revision !== "string") return;
        verification = verification.catch(() => {}).then(async () => {
          const fresh = await ns.getStateFresh();
          if (fresh.webAppNativeLive !== true) throw new Error("native state unavailable");
          const tabs = await new Promise(resolve => api.tabs.query({}, result => resolve(result || [])));
          const checks = await Promise.all(tabs.map(async tab => {
            let site;
            try { site = getHostKey(new URL(tab.url).hostname); } catch (_) { return true; }
            if (!site) return true; // Login providers and internal block pages have no site rules.
            const state = await ns.getStateFresh(site);
            if (state.webAppNativeLive !== true) return false;
            return new Promise(resolve => {
              const timeout = setTimeout(() => resolve(false), 2500);
              try {
                api.tabs.sendMessage(tab.id, { type: "unscroll-verify", revision: message.revision, state }, reply => {
                  const error = api.runtime.lastError;
                  clearTimeout(timeout);
                  resolve(!error && reply?.ok === true && reply.revision === message.revision);
                });
              } catch (_) { clearTimeout(timeout); resolve(false); }
            });
          }));
          port.postMessage({ type: "verified", revision: message.revision, ok: checks.every(Boolean) });
        }).catch(() => {
          try { port.postMessage({ type: "verified", revision: message.revision, ok: false }); } catch (_) {}
        });
      });
      port.onDisconnect.addListener(() => {
        void api.runtime.lastError;
        if (nativePort !== port) return;
        nativePort = null;
        scheduleReconnect();
      });
    } catch (_) {
      nativePort = null;
      scheduleReconnect();
    }
  }
  async function discoverHost(attempt = 0) {
    await ns.getStateFresh();
    connectHost();
    if (api.runtime.connectNative && ns.webAppHost === undefined && attempt < 3) {
      setTimeout(() => { void discoverHost(attempt + 1); }, 1000);
    }
  }
  ns.onWebAppHostReady = connectHost;
  void discoverHost();
})();
