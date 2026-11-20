# Privacy policy translations

Edit `privacy-content.json`, then run from the repository root:

```sh
python3 scripts/render_privacy.py
python3 scripts/render_privacy.py --check
```

Commit the source, renderer, CSS and generated HTML together. GitHub Pages
serves the committed HTML directly; it does not run the renderer.

The existing `privacy.html` URL remains the English entry point. The language
links lead to static pages for Spanish (Mexico), Hindi, French, Arabic,
Japanese and German. Each page includes the same language links and reciprocal
`hreflang` metadata. No JavaScript, cookies or language detection is needed.
Arabic uses `dir="rtl"`; language names and the email address use bidi isolation.

The 2026-09-20 update adds the on-device ReplayKit/Core ML processing used by
Real-time Blocking on iOS, distinguishes Safari-only behavior on Mac, and
replaces the old exact network-request frequency with periodic rule updates.
It also distinguishes app processing from website hosting and support email.
Debug capture/upload tools are excluded from App Store builds in the current
Slowth source (`#if DEBUG`).

Keep every translation synchronized when data practices change. Localization
alone does not guarantee App Review approval.
