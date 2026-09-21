(function () {
  const ns = globalThis.Unscroll || (globalThis.Unscroll = {});

  const { t, locale, localize } = ns.i18n;
  localize();
  ns.i18n.setLocale(document.documentElement);

  const extensionAPI = globalThis.browser || globalThis.chrome;
  const isExtensionPopup = !!extensionAPI?.runtime?.id;
  const isNativeHost = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.unscroll);

  const env = isNativeHost ? "native" : (isExtensionPopup ? "popup" : "unknown");

  document.body.classList.toggle("landing", env === "native");

  let pendingId = 0;
  const pending = new Map();

  globalThis.__unscrollResolve = function (id, payload) {
    const cb = pending.get(id);
    if (cb) { pending.delete(id); cb(payload); }
  };

  function callNative(action, payload) {
    return new Promise((resolve) => {
      const id = ++pendingId;
      pending.set(id, resolve);
      try {
        window.webkit.messageHandlers.unscroll.postMessage({ id, action, payload: payload || {} });
      } catch (_) {
        pending.delete(id);
        resolve({ ok: false, reason: "bridge_error" });
      }
    });
  }

  function callExtension(action, payload) {
    const message = { type: "rpc", action, payload: payload || {} };
    // Safari exposes the promise-based browser namespace. Keep the callback
    // path for hosts that expose only chrome.
    if (globalThis.browser) {
      return extensionAPI.runtime.sendMessage(message)
        .catch(() => ({ ok: false, reason: "rpc_error" }));
    }
    return new Promise((resolve) => {
      try {
        extensionAPI.runtime.sendMessage(message, (resp) => {
          void extensionAPI.runtime.lastError;
          resolve(resp);
        });
      } catch (_) {
        resolve({ ok: false, reason: "rpc_error" });
      }
    });
  }

  const api = isNativeHost
    ? { call: callNative }
    : { call: callExtension };

  const sitesEl = document.getElementById("sites");
  const statusEl = document.getElementById("rules-status");
  const refreshBtn = document.getElementById("refresh-btn");
  const strictToggle = document.getElementById("strict-toggle");
  const strictBanner = document.getElementById("strict-banner");
  const strictBannerText = document.getElementById("strict-banner-text");
  const strictConfirmation = document.getElementById("strict-confirmation");
  const feedbackLink = document.getElementById("feedback-link");
  const onboarding = document.getElementById("onboarding");
  const openSettingsBtn = document.getElementById("open-settings-btn");
  const dismissOnboardingBtn = document.getElementById("dismiss-onboarding-btn");
  const howToUseBtn = document.getElementById("how-to-use-btn");
  const showIntroBtn = document.getElementById("show-intro-btn");
  const guideCardsEl = document.getElementById("guide-cards");

  feedbackLink.href = ns.FEEDBACK_MAILTO;

  for (const site of ns.SITES) {
    const section = document.createElement("section");
    section.className = "site-settings";
    section.setAttribute("aria-label", ns.SITE_LABELS[site]);
    const features = ["all", ...ns.SITE_FEATURES[site].filter(feature => feature !== "all")];
    for (const feature of features) {
      const row = document.createElement("label");
      row.className = feature === "all" ? "row site-heading" : "row site-content";
      const span = document.createElement("span");
      if (feature === "all") {
        const name = document.createElement("strong");
        name.textContent = ns.SITE_LABELS[site];
        const action = document.createElement("span");
        action.className = "site-action";
        action.textContent = " — " + t("blockSite");
        span.appendChild(name);
        span.appendChild(action);
      } else {
        span.textContent = t(feature === "feed" ? "blockInfiniteFeed"
          : site === "youtube" ? "blockShorts" : site === "x" ? "blockExplore" : "blockReels");
      }
      const input = document.createElement("input");
      input.type = "checkbox";
      input.setAttribute("role", "switch");
      input.dataset.site = site;
      input.dataset.feature = feature;
      input.disabled = true;
      row.appendChild(span);
      row.appendChild(input);
      section.appendChild(row);
    }
    sitesEl.appendChild(section);
  }

  function formatRelative(ts) {
    if (!ts) return t("rulesNever");
    const seconds = Math.max(0, Math.round((Date.now() - ts) / 1000));
    if (seconds < 60) return t("rulesNow");
    const [value, unit] = seconds < 3600 ? [Math.round(seconds / 60), "minute"]
      : seconds < 172800 ? [Math.round(seconds / 3600), "hour"]
      : [Math.round(seconds / 86400), "day"];
    return t("rulesRelative", new Intl.RelativeTimeFormat(locale, { style: "short" }).format(-value, unit));
  }

  function formatStrictUntil(ts) {
    if (!ts) return "";
    const d = new Date(ts * 1000);
    return d.toLocaleString(locale, { hour: "2-digit", minute: "2-digit", month: "short", day: "numeric" });
  }

  let lastState = null;

  function applyState(state) {
    lastState = state || {};
    statusEl.textContent = formatRelative((state?.rulesFetchedAt || 0) * 1000);

    const strictActive = (state?.strictModeUntil || 0) * 1000 > Date.now();
    strictToggle.checked = strictActive;
    strictToggle.disabled = strictActive;

    if (strictActive) {
      strictBanner.classList.remove("hidden");
      strictBannerText.textContent = t("strictUntil", formatStrictUntil(state.strictModeUntil));
    } else {
      strictBanner.classList.add("hidden");
    }

    for (const input of sitesEl.querySelectorAll("input")) {
      const settings = ns.normalizeSiteSettings(input.dataset.site, state?.toggles?.[input.dataset.site]);
      input.checked = settings[input.dataset.feature];
      input.disabled = (strictActive &&
        (input.dataset.feature === "all" || input.checked))
        || (input.dataset.feature !== "all" && settings.all);
    }
    refreshBtn.disabled = strictActive;

    const showOnboarding = (env !== "popup") && state && !state.onboardingDone;
    onboarding.classList.toggle("hidden", !showOnboarding);

    if (env === "native") {
      openSettingsBtn.textContent = state?.platform === "macos" ? t("openSafariSettings") : t("openSettings");
    }

    showIntroBtn.classList.toggle("hidden", env !== "native" || !state?.onboardingDone);
  }

  async function refreshState() {
    const resp = await api.call("getState");
    if (resp && resp.state) applyState(resp.state);
    else if (resp) applyState(resp);
  }

  let saving = false;
  sitesEl.addEventListener("change", async (e) => {
    const input = e.target;
    if (input.tagName.toLowerCase() !== "input" || !input.dataset.feature || saving) return;
    saving = true;
    for (const control of sitesEl.querySelectorAll("input")) control.disabled = true;
    try {
      const resp = await api.call("setToggle", {
        site: input.dataset.site, feature: input.dataset.feature, enabled: input.checked
      });
      applyState(resp?.state || lastState);
      if (!resp?.ok) statusEl.textContent = t("settingsSaveFailed");
    } catch (_) {
      applyState(lastState);
      statusEl.textContent = t("settingsSaveFailed");
    } finally {
      saving = false;
    }
  });

  strictToggle.addEventListener("change", async () => {
    if (strictToggle.checked) {
      strictToggle.checked = false;
      strictConfirmation.showModal();
      return;
    }
    const resp = await api.call("setStrictMode", { enabled: false });
    if (resp && resp.state) applyState(resp.state);
  });

  strictConfirmation.addEventListener("close", async () => {
    if (strictConfirmation.returnValue !== "enable") return;
    const resp = await api.call("setStrictMode", { enabled: true });
    if (resp?.state) applyState(resp.state);
    if (!resp?.ok) applyState(lastState);
  });

  refreshBtn.addEventListener("click", async () => {
    refreshBtn.disabled = true;
    statusEl.textContent = t("updating");
    const res = await api.call("forceRefresh");
    if (res && res.state) applyState(res.state);
    if (res && res.ok) {
      statusEl.textContent = res.status === 304 ? t("rulesCurrent") : t("rulesNow");
    } else {
      statusEl.textContent = t("rulesFailed");
    }
    setTimeout(() => { refreshBtn.disabled = (lastState?.strictModeUntil || 0) * 1000 > Date.now(); }, 800);
  });

  openSettingsBtn.addEventListener("click", async () => {
    await api.call("openExtensionSettings");
  });

  dismissOnboardingBtn.addEventListener("click", async () => {
    const resp = await api.call("setOnboardingDone", { value: true });
    if (resp && resp.state) applyState(resp.state);
  });

  howToUseBtn.addEventListener("click", () => {
    if (guideCardsEl) guideCardsEl.scrollIntoView({ behavior: "smooth", block: "start" });
  });

  showIntroBtn.addEventListener("click", async () => {
    const resp = await api.call("setOnboardingDone", { value: false });
    if (resp && resp.state) applyState(resp.state);
    if (onboarding) onboarding.scrollIntoView({ behavior: "smooth", block: "start" });
  });

  if (env === "popup") {
    api.call("setOnboardingDone");
  }

  globalThis.__unscrollRefresh = refreshState;

  refreshState();
})();
