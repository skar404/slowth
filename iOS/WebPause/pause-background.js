(function () {
  const ns = globalThis.Unscroll;
  const api = typeof browser !== 'undefined' ? browser : chrome;
  const prefix = 'slowth.pause.';
  const original = ns.getStateFresh;
  const inFlight = new Map();
  function native(payload) {
    return new Promise(resolve => {
      const timeout = setTimeout(() => resolve(null), 4000);
      try {
        api.runtime.sendNativeMessage('application.id', payload, result => {
          const error = api.runtime.lastError;
          clearTimeout(timeout);
          resolve(error ? null : result);
        });
      } catch (_) { clearTimeout(timeout); resolve(null); }
    });
  }
  function alarmGet(name) {
    return new Promise(resolve => {
      const timeout = setTimeout(() => resolve(null), 4000);
      try { api.alarms.get(name, value => { void api.runtime.lastError; clearTimeout(timeout); resolve(value); }); }
      catch (_) { clearTimeout(timeout); resolve(null); }
    });
  }
  async function fetchState(site) {
    const base = await original();
    const result = await native({action: 'getState'});
    let lease = result?.ok ? result.state?.pause : null;
    if (lease?.phase === 'preparing' && lease.target === site) {
      const id = lease.id;
      try {
        const name = prefix + id;
        await Promise.resolve(api.alarms.create(name, {when: lease.expiresAt * 1000}));
        const alarm = await alarmGet(name);
        if (!alarm || Math.abs(alarm.scheduledTime - lease.expiresAt * 1000) > 1000) throw new Error('alarm unavailable');
        const acknowledged = await native({action: 'activatePause', id});
        if (!acknowledged?.ok) throw new Error('activation unconfirmed');
        lease = acknowledged.state?.pause;
      } catch (_) {
        const cancelled = await native({action: 'cancelPausePreparation', id});
        // Lost ack may have committed: do not cancel its return alarm.
        if (cancelled?.ok && cancelled.state?.pause?.id !== id) api.alarms.clear(prefix + id);
        lease = null;
      }
    }
    // Only base preferences are cached by rules-loader. The lease stays separate.
    return {...base, pause: lease || null};
  }
  function fresh(site) {
    if (!inFlight.has(site)) inFlight.set(site, fetchState(site).finally(() => { inFlight.delete(site); }));
    return inFlight.get(site);
  }
  ns.getStateFresh = fresh;
  ns.getStateCached = fresh;
  api.alarms.onAlarm.addListener(async alarm => {
    if (!alarm.name.startsWith(prefix)) return;
    await fresh();
    api.tabs.query({}, tabs => {
      void api.runtime.lastError;
      for (const tab of tabs || []) {
        if (tab.id) api.tabs.sendMessage(tab.id, {type: 'unscroll-state-updated'}, () => { void api.runtime.lastError; });
      }
    });
  });
})();
