(function () {
  const ns = globalThis.Unscroll;
  let anchor = null;
  ns.pauseValid = function (state, site) {
    const p = state && state.pause;
    if (!p || !p.id || p.phase !== 'active' || p.target !== site) return false;
    const wall = Date.now() / 1000;
    const mono = performance.now() / 1000;
    if (!anchor || anchor.id !== p.id) anchor = {id: p.id, wall, mono};
    if (Math.abs((wall - anchor.wall) - (mono - anchor.mono)) > 3) return false;
    return Number.isFinite(p.startedAt) && Number.isFinite(p.expiresAt) &&
      [60, 180, 300].includes(p.expiresAt - p.startedAt) && wall >= p.startedAt && wall < p.expiresAt;
  };
  ns.pauseSettings = function (site, state, settings) {
    if (!ns.pauseValid(state, site)) return settings;
    return Object.fromEntries(Object.keys(settings).map(key => [key, false]));
  };
})();
