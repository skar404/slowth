(() => {
  if (!document.documentElement.classList.contains('launching')) return;
  const {service} = document.body.dataset;
  if (!['instagram', 'youtube', 'tiktok', 'facebook', 'x', 'threads', 'reddit', 'linkedin'].includes(service)) return;

  let frame = null;
  let retry = null;
  let pageHidden = false;

  function stop() {
    cancelAnimationFrame(frame);
    clearTimeout(retry);
    frame = null;
    retry = null;
  }

  function launch() {
    frame = null;
    retry = null;
    if (pageHidden || document.visibilityState !== 'visible') return;
    retry = setTimeout(launch, 2000);
    location.href = `slowth://web/${service}`;
  }

  function start() {
    if (pageHidden || document.visibilityState !== 'visible' || frame !== null || retry !== null) return;
    // The first callback runs before paint. Leave a frame for the launcher to appear.
    frame = requestAnimationFrame(() => {
      frame = requestAnimationFrame(launch);
    });
  }

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') start();
    else stop();
  });
  window.addEventListener('pagehide', () => {
    pageHidden = true;
    stop();
  });
  window.addEventListener('pageshow', () => {
    pageHidden = false;
    start();
  });
  start();
})();
