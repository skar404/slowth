(function () {
  const ns = (globalThis.Unscroll = globalThis.Unscroll || {});
  const api = (typeof browser !== "undefined" ? browser : chrome);

  function sendNative(payload) {
    return new Promise((resolve) => {
      try {
        api.runtime.sendNativeMessage("application.id", payload, (resp) => {
          void api.runtime.lastError;
          resolve(resp);
        });
      } catch (_) {
        resolve(null);
      }
    });
  }

  function storageGet(keys) {
    return new Promise((resolve) => {
      try {
        api.storage.local.get(keys, (items) => {
          void api.runtime.lastError;
          resolve(items || {});
        });
      } catch (_) {
        resolve({});
      }
    });
  }

  function storageSet(items) {
    return new Promise((resolve) => {
      try {
        api.storage.local.set(items, () => {
          void api.runtime.lastError;
          resolve();
        });
      } catch (_) {
        resolve();
      }
    });
  }

  function isValidRules(obj) {
    if (!obj || typeof obj !== "object") return false;
    if (typeof obj.version !== "number") return false;
    for (const site of ns.SITES) {
      if (!obj[site] || typeof obj[site] !== "object") return false;
      if (!Array.isArray(obj[site].redirects)) return false;
      if (!Array.isArray(obj[site].hideSelectors)) return false;
    }
    return true;
  }

  function normalizeState(raw) {
    const togglesRaw = (raw && raw.toggles) || {};
    const toggles = { ...ns.DEFAULT_TOGGLES };
    for (const site of ns.SITES) {
      const v = togglesRaw[site];
      if (typeof v === "string" && (ns.SITE_AVAILABLE_MODES[site] || []).includes(v)) {
        toggles[site] = v;
      }
    }

    let strictModeUntil = 0;
    if (raw && typeof raw.strictModeUntil === "number") {
      strictModeUntil = raw.strictModeUntil;
    }

    let rules = ns.DEFAULT_RULES;
    if (raw && typeof raw.rules === "string") {
      try {
        const parsed = JSON.parse(raw.rules);
        if (isValidRules(parsed)) rules = parsed;
      } catch (_) {}
    }

    const rulesFetchedAt = (raw && typeof raw.rulesFetchedAt === "number") ? raw.rulesFetchedAt : 0;
    const rulesEtag = (raw && typeof raw.rulesEtag === "string") ? raw.rulesEtag : "";
    const onboardingDone = !!(raw && raw.onboardingDone);

    return { toggles, strictModeUntil, rules, rulesFetchedAt, rulesEtag, onboardingDone };
  }

  async function getStateFresh() {
    const resp = await sendNative({ action: "getState" });
    const state = normalizeState(resp && resp.state);
    await storageSet({
      [ns.STORAGE_KEYS.cachedState]: state,
      [ns.STORAGE_KEYS.cachedAt]: Date.now()
    });
    return state;
  }

  async function getStateCached() {
    const items = await storageGet([ns.STORAGE_KEYS.cachedState, ns.STORAGE_KEYS.cachedAt]);
    const cached = items[ns.STORAGE_KEYS.cachedState];
    const at = items[ns.STORAGE_KEYS.cachedAt] || 0;
    if (cached && Date.now() - at < ns.STATE_CACHE_TTL_MS) return cached;
    return getStateFresh();
  }

  async function setToggle(site, value) {
    const resp = await sendNative({ action: "setToggle", site, value });
    if (resp && resp.state) {
      const state = normalizeState(resp.state);
      await storageSet({
        [ns.STORAGE_KEYS.cachedState]: state,
        [ns.STORAGE_KEYS.cachedAt]: Date.now()
      });
      return { ok: !!resp.ok, reason: resp.reason, state };
    }
    return { ok: false, reason: (resp && resp.reason) || "no_response" };
  }

  async function setStrictMode(enabled) {
    const resp = await sendNative({ action: "setStrictMode", enabled: !!enabled });
    if (resp && resp.state) {
      const state = normalizeState(resp.state);
      await storageSet({
        [ns.STORAGE_KEYS.cachedState]: state,
        [ns.STORAGE_KEYS.cachedAt]: Date.now()
      });
      return { ok: !!resp.ok, reason: resp.reason, state };
    }
    return { ok: false, reason: (resp && resp.reason) || "no_response" };
  }

  async function setOnboardingDone(value) {
    await sendNative({ action: "setOnboardingDone", value: !!value });
    return getStateFresh();
  }

  async function refreshRules({ force } = {}) {
    const state = await getStateFresh();
    const now = Date.now();
    const items = await storageGet(["rulesLastAttemptAt"]);
    const lastAttempt = items.rulesLastAttemptAt || 0;
    if (!force && now - lastAttempt < ns.MIN_REFRESH_INTERVAL_MS) {
      return { ok: false, reason: "throttled", fetchedAt: state.rulesFetchedAt * 1000 };
    }
    await storageSet({ rulesLastAttemptAt: now });

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), ns.FETCH_TIMEOUT_MS);
    try {
      const headers = { Accept: "application/json" };
      if (state.rulesEtag) headers["If-None-Match"] = state.rulesEtag;

      const resp = await fetch(ns.CONFIG_URL, { cache: "no-cache", signal: controller.signal, headers });
      if (resp.status === 304) {
        await sendNative({ action: "rulesAttempt" });
        return { ok: true, status: 304, fetchedAt: state.rulesFetchedAt * 1000 };
      }
      if (!resp.ok) return { ok: false, reason: "http_" + resp.status, fetchedAt: state.rulesFetchedAt * 1000 };

      const text = await resp.text();
      let parsed;
      try { parsed = JSON.parse(text); }
      catch (_) { return { ok: false, reason: "invalid_json" }; }
      if (!isValidRules(parsed)) return { ok: false, reason: "invalid_shape" };

      const etag = resp.headers.get("ETag") || "";
      const saveResp = await sendNative({ action: "saveRules", rules: text, etag });
      if (saveResp && saveResp.ok) {
        await getStateFresh();
        return { ok: true, status: 200, fetchedAt: Date.now() };
      }
      return { ok: false, reason: (saveResp && saveResp.reason) || "save_failed" };
    } catch (e) {
      const reason = e && e.name === "AbortError" ? "timeout" : "network_error";
      return { ok: false, reason };
    } finally {
      clearTimeout(timer);
    }
  }

  ns.getStateFresh = getStateFresh;
  ns.getStateCached = getStateCached;
  ns.setToggle = setToggle;
  ns.setStrictMode = setStrictMode;
  ns.setOnboardingDone = setOnboardingDone;
  ns.refreshRules = refreshRules;
  ns.isValidRules = isValidRules;
})();
