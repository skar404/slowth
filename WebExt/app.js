(function () {
  const ns = globalThis.Unscroll || (globalThis.Unscroll = {});

  const isExtensionPopup = (typeof chrome !== "undefined" && chrome.runtime && chrome.runtime.id);
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
    return new Promise((resolve) => {
      try {
        chrome.runtime.sendMessage({ type: "rpc", action, payload: payload || {} }, (resp) => {
          void chrome.runtime.lastError;
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
  const feedbackLink = document.getElementById("feedback-link");
  const onboarding = document.getElementById("onboarding");
  const openSettingsBtn = document.getElementById("open-settings-btn");
  const dismissOnboardingBtn = document.getElementById("dismiss-onboarding-btn");
  const howToUseBtn = document.getElementById("how-to-use-btn");
  const showIntroBtn = document.getElementById("show-intro-btn");
  const guideCardsEl = document.getElementById("guide-cards");

  feedbackLink.href = ns.FEEDBACK_MAILTO;

  for (const site of ns.SITES) {
    const row = document.createElement("label");
    row.className = "row";
    const span = document.createElement("span");
    span.textContent = ns.SITE_LABELS[site];
    const select = document.createElement("select");
    select.dataset.site = site;
    for (const mode of ns.SITE_AVAILABLE_MODES[site]) {
      const opt = document.createElement("option");
      opt.value = mode;
      // ⚠️ Mode labels — keep in sync with modeLabel() in Shared/ContentView_iOS.swift
      // and Shared/ContentView_macOS.swift (the host-app version of this settings UI).
      opt.textContent = ({ off: "Off", shorts: "Block shorts", feed: "Block shorts + feed", all: "Block site" })[mode];
      select.appendChild(opt);
    }
    row.appendChild(span);
    row.appendChild(select);
    sitesEl.appendChild(row);
  }

  function formatRelative(ts) {
    if (!ts) return "Rules: never fetched";
    const diff = Date.now() - ts;
    if (diff < 0) return "Rules: just now";
    const sec = Math.round(diff / 1000);
    if (sec < 60) return "Rules: just now";
    const min = Math.round(sec / 60);
    if (min < 60) return `Rules: ${min} min ago`;
    const hr = Math.round(min / 60);
    if (hr < 48) return `Rules: ${hr} h ago`;
    const day = Math.round(hr / 24);
    return `Rules: ${day} d ago`;
  }

  function formatStrictUntil(ts) {
    if (!ts) return "";
    const d = new Date(ts * 1000);
    return d.toLocaleString(undefined, { hour: "2-digit", minute: "2-digit", month: "short", day: "numeric" });
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
      strictBannerText.textContent = "Strict mode active until " + formatStrictUntil(state.strictModeUntil);
    } else {
      strictBanner.classList.add("hidden");
    }

    for (const sel of sitesEl.querySelectorAll("select")) {
      const site = sel.dataset.site;
      sel.value = (state?.toggles && state.toggles[site]) || "off";
      sel.disabled = strictActive;
    }
    refreshBtn.disabled = strictActive;

    const showOnboarding = (env !== "popup") && state && !state.onboardingDone;
    onboarding.classList.toggle("hidden", !showOnboarding);

    if (env === "native") {
      openSettingsBtn.textContent = state?.platform === "macos" ? "Open Safari Settings" : "Open Settings";
    }

    showIntroBtn.classList.toggle("hidden", env !== "native" || !state?.onboardingDone);
  }

  async function refreshState() {
    const resp = await api.call("getState");
    if (resp && resp.state) applyState(resp.state);
    else if (resp) applyState(resp);
  }

  async function reloadActiveTabIfPopup() {
    if (env !== "popup") return;
    return new Promise((resolve) => {
      try {
        chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
          const tab = tabs && tabs[0];
          if (tab && tab.id) try { chrome.tabs.reload(tab.id); } catch (_) {}
          resolve();
        });
      } catch (_) { resolve(); }
    });
  }

  sitesEl.addEventListener("change", async (e) => {
    const sel = e.target;
    if (!(sel instanceof HTMLSelectElement)) return;
    const site = sel.dataset.site;
    const value = sel.value;
    const resp = await api.call("setToggle", { site, value });
    if (resp && resp.state) applyState(resp.state);
    if (resp && resp.ok) await reloadActiveTabIfPopup();
  });

  strictToggle.addEventListener("change", async () => {
    const resp = await api.call("setStrictMode", { enabled: strictToggle.checked });
    if (resp && resp.state) applyState(resp.state);
  });

  refreshBtn.addEventListener("click", async () => {
    refreshBtn.disabled = true;
    statusEl.textContent = "Updating…";
    const res = await api.call("forceRefresh");
    if (res && res.ok) {
      statusEl.textContent = res.status === 304 ? "Rules: up to date" : "Rules: just now";
    } else {
      statusEl.textContent = `Rules: failed (${(res && res.reason) || "unknown"})`;
    }
    if (res && res.state) applyState(res.state);
    setTimeout(() => { refreshBtn.disabled = false; }, 800);
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
