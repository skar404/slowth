(function () {
  const params = new URLSearchParams(location.search);
  const host = params.get("host") || "this site";
  document.title = "Blocked: " + host;
  const titleHost = document.getElementById("title-host");
  if (titleHost) titleHost.textContent = host;
  const subtitle = document.getElementById("subtitle");
  if (subtitle) subtitle.textContent =
    "Slowth is keeping you off " + host + ". Take a breath. Do something else.";

  // "Back to <site>" button — maps the host key to its home URL. The blocked
  // paths (reels/watch/etc.) never match "/", so home is safe to return to.
  const HOME_URLS = {
    facebook:  "https://www.facebook.com/",
    instagram: "https://www.instagram.com/",
    youtube:   "https://www.youtube.com/",
    x:         "https://x.com/",
    tiktok:    "https://www.tiktok.com/"
  };
  const HOST_LABELS = {
    facebook: "Facebook", instagram: "Instagram", youtube: "YouTube",
    x: "X", tiktok: "TikTok"
  };
  const footer = document.getElementById("footer");
  const backLink = document.getElementById("back-link");
  if (footer && backLink && HOME_URLS[host]) {
    backLink.href = HOME_URLS[host];
    backLink.textContent = "← Back to " + (HOST_LABELS[host] || host);
    footer.hidden = false;
  }

  // Pick one random quote, hide the rest. The visible one becomes the play trigger.
  const quotes = document.querySelectorAll("[data-quote]");
  let activeQuote = null;
  if (quotes.length) {
    const pick = Math.floor(Math.random() * quotes.length);
    quotes.forEach((q, i) => {
      if (i !== pick) q.hidden = true;
      else activeQuote = q;
    });
  }

  const quotesEl = document.getElementById("quotes");
  const lede = document.getElementById("subtitle");
  const gameSection = document.getElementById("game-section");

  // ---------- Slow Flap ----------
  const canvas = document.getElementById("game");
  if (!canvas || !canvas.getContext) return;
  const ctx = canvas.getContext("2d");

  // Hi-DPI: scale internal buffer to actual rendered size.
  const BASE_W = 320, BASE_H = 460;
  function fitCanvas() {
    const dpr = window.devicePixelRatio || 1;
    const cssW = canvas.clientWidth || BASE_W;
    const cssH = canvas.clientHeight || BASE_H;
    canvas.width = Math.round(cssW * dpr);
    canvas.height = Math.round(cssH * dpr);
    ctx.setTransform(dpr * (cssW / BASE_W), 0, 0, dpr * (cssH / BASE_H), 0, 0);
  }
  window.addEventListener("resize", function () { if (gameOpened) fitCanvas(); });

  const W = BASE_W, H = BASE_H;
  const FLOOR = 40;
  const SLOTH_X = 78;
  const SLOTH_R = 18;
  const GAP = 130;
  const PIPE_W = 52;
  const PIPE_SPACING = 200;
  const SPEED = 1.6;
  const GRAVITY = 0.32;
  const FLAP = -5.6;
  const BEST_KEY = "slowth.flap.best";

  const scoreEl = document.getElementById("score");
  const bestEl = document.getElementById("best");
  const helpEl = document.getElementById("game-help");

  let state = "idle"; // idle | playing | dead
  let y, vy, pipes, score, best;

  function loadBest() {
    try { return parseInt(localStorage.getItem(BEST_KEY) || "0", 10) || 0; }
    catch (_) { return 0; }
  }
  function saveBest(v) {
    try { localStorage.setItem(BEST_KEY, String(v)); } catch (_) {}
  }
  best = loadBest();
  if (bestEl) bestEl.textContent = best;

  function reset() {
    y = H * 0.45;
    vy = 0;
    pipes = [];
    score = 0;
    if (scoreEl) scoreEl.textContent = "0";
  }

  function spawnPipe(x) {
    const margin = 60;
    const minTop = margin;
    const maxTop = H - FLOOR - GAP - margin;
    const top = minTop + Math.random() * (maxTop - minTop);
    pipes.push({ x: x, top: top, scored: false });
  }

  function start() {
    reset();
    for (let i = 0; i < 3; i++) spawnPipe(W + 120 + i * PIPE_SPACING);
    state = "playing";
    if (helpEl) helpEl.textContent = "Don't hit the branches";
  }

  function die() {
    state = "dead";
    if (score > best) {
      best = score;
      saveBest(best);
      if (bestEl) bestEl.textContent = best;
      if (helpEl) helpEl.textContent = "New best! Tap to fly again";
    } else {
      if (helpEl) helpEl.textContent = "Tap to fly again";
    }
  }

  function flap() {
    if (state === "idle" || state === "dead") { start(); vy = FLAP; return; }
    vy = FLAP;
  }

  function step() {
    ctx.clearRect(0, 0, W, H);
    drawBg();

    if (state === "playing") {
      vy += GRAVITY;
      y += vy;
      for (const p of pipes) p.x -= SPEED;

      while (pipes.length && pipes[0].x + PIPE_W < -20) pipes.shift();
      const last = pipes[pipes.length - 1];
      if (!last || last.x < W - PIPE_SPACING) {
        spawnPipe((last ? last.x : W) + PIPE_SPACING);
      }

      if (y + SLOTH_R > H - FLOOR) { y = H - FLOOR - SLOTH_R; die(); }
      if (y - SLOTH_R < 0) { y = SLOTH_R; vy = 0; }
      for (const p of pipes) {
        if (SLOTH_X + SLOTH_R > p.x && SLOTH_X - SLOTH_R < p.x + PIPE_W) {
          if (y - SLOTH_R < p.top || y + SLOTH_R > p.top + GAP) { die(); break; }
        }
        if (!p.scored && p.x + PIPE_W < SLOTH_X - SLOTH_R) {
          p.scored = true;
          score += 1;
          if (scoreEl) scoreEl.textContent = score;
        }
      }
    } else if (state === "idle") {
      y = H * 0.45 + Math.sin(performance.now() / 350) * 6;
    } else if (state === "dead") {
      if (y + SLOTH_R < H - FLOOR) {
        vy += GRAVITY;
        y += vy;
        if (y + SLOTH_R > H - FLOOR) y = H - FLOOR - SLOTH_R;
      }
    }

    drawPipes();
    drawFloor();
    drawSloth();

    if (state === "idle") drawCenter("Tap to start");
    if (state === "dead") drawCenter("Game over");

    requestAnimationFrame(step);
  }

  function drawBg() {
    const now = performance.now() / 1000;
    ctx.fillStyle = "rgba(255,255,255,0.05)";
    for (let i = 0; i < 4; i++) {
      const x = (i * 90 + (now * 12)) % (W + 90) - 45;
      const yy = 60 + i * 70 + Math.sin(now + i) * 8;
      ctx.beginPath();
      ctx.ellipse(x, yy, 8, 4, Math.PI / 4, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  function drawPipes() {
    for (const p of pipes) {
      drawBranch(p.x, 0, PIPE_W, p.top, true);
      drawBranch(p.x, p.top + GAP, PIPE_W, H - FLOOR - (p.top + GAP), false);
    }
  }

  function drawBranch(x, y, w, h, isTop) {
    if (h <= 0) return;
    const grad = ctx.createLinearGradient(x, 0, x + w, 0);
    grad.addColorStop(0, "#3a6a32");
    grad.addColorStop(0.5, "#5fa84d");
    grad.addColorStop(1, "#3a6a32");
    ctx.fillStyle = grad;
    roundRect(x, y, w, h, 8);
    ctx.fill();
    ctx.fillStyle = "#7bc662";
    if (isTop) {
      roundRect(x - 4, y + h - 14, w + 8, 14, 6);
    } else {
      roundRect(x - 4, y, w + 8, 14, 6);
    }
    ctx.fill();
  }

  function drawFloor() {
    ctx.fillStyle = "rgba(13, 8, 36, 0.55)";
    ctx.fillRect(0, H - FLOOR, W, FLOOR);
    ctx.fillStyle = "rgba(255,255,255,0.07)";
    for (let x = 0; x < W; x += 18) {
      ctx.fillRect(x, H - FLOOR, 8, 2);
    }
  }

  function drawSloth() {
    ctx.save();
    ctx.translate(SLOTH_X, y);
    const tilt = Math.max(-0.5, Math.min(0.9, vy / 12));
    ctx.rotate(tilt);
    ctx.font = "32px -apple-system, system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText("🦥", 0, 0);
    ctx.restore();
  }

  function drawCenter(text) {
    ctx.fillStyle = "rgba(0,0,0,0.35)";
    ctx.fillRect(0, H / 2 - 26, W, 52);
    ctx.fillStyle = "#fff";
    ctx.font = "600 18px -apple-system, system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(text, W / 2, H / 2);
  }

  function roundRect(x, y, w, h, r) {
    if (h <= 0 || w <= 0) return;
    const rr = Math.min(r, w / 2, Math.abs(h) / 2);
    ctx.beginPath();
    ctx.moveTo(x + rr, y);
    ctx.arcTo(x + w, y, x + w, y + h, rr);
    ctx.arcTo(x + w, y + h, x, y + h, rr);
    ctx.arcTo(x, y + h, x, y, rr);
    ctx.arcTo(x, y, x + w, y, rr);
    ctx.closePath();
  }

  canvas.addEventListener("pointerdown", function (e) { e.preventDefault(); flap(); });
  canvas.addEventListener("touchstart", function (e) { e.preventDefault(); flap(); }, { passive: false });

  let gameOpened = false;
  function openGame() {
    if (gameOpened) return;
    gameOpened = true;
    if (quotesEl) quotesEl.hidden = true;
    if (lede) lede.hidden = true;
    if (gameSection) gameSection.hidden = false;
    fitCanvas();
    reset();
    state = "idle";
    requestAnimationFrame(step);
  }
  if (activeQuote) {
    activeQuote.classList.add("clickable");
    activeQuote.setAttribute("role", "button");
    activeQuote.setAttribute("tabindex", "0");
    activeQuote.addEventListener("click", openGame);
    activeQuote.addEventListener("keydown", function (e) {
      if (e.code === "Enter" || e.code === "Space") { e.preventDefault(); openGame(); }
    });
  }

  window.addEventListener("keydown", function (e) {
    if (e.code === "Space" || e.code === "ArrowUp") {
      e.preventDefault();
      if (!gameOpened) { openGame(); return; }
      flap();
    }
  });
})();
