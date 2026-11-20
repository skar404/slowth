# Slowth website

Static HTML/CSS in `website/` in the `skar404/slowth` repository. Production: https://slowth.app/. GitHub Actions publishes only public website files via GitHub Pages.

| Path | Purpose |
| --- | --- |
| `index.html`, `{locale}/index.html` | Product landing page and partner information in 64 app locales |
| `support.html`, `{locale}/support.html` | Localized setup, permissions, pauses, Strict Mode and troubleshooting |
| `privacy.html`, `privacy-*.html`, `{locale}/privacy.html` | Localized policies; all seven historical policy URLs and their text are preserved |
| `sitemap.xml` | Canonical landing, support and privacy URLs for search crawlers |
| `SEARCH.md` | Search metadata, crawler observations and post-publication indexing steps |
| `test-cases/` | Redirect to the contribution form on malina.page, preserving query and fragment |

Run an HTTP preview from the repository root:

```sh
python3 -m http.server 8794 --bind 127.0.0.1
```

Open http://127.0.0.1:8794/website/. No build step, executable frontend JavaScript, external fonts or analytics are required. The landing includes descriptive SoftwareApplication JSON-LD. The redesign was published on 17 November 2026. The new domain is served directly by GitHub Pages; no Cloudflare edge scripts are injected.

## Content sources

Copy was checked on 17 November 2026 against the public US App Store listing (`2026.11.1`) and Release paths in Slowth source at `4cbd53e` (build 34). These are separate observations; matching the marketing version does not identify the uploaded binary.

- Store: https://apps.apple.com/app/id6764140763
- Source: https://github.com/skar404/slowth
- Funding request: https://github.com/skar404/slowth/blob/main/BUDGET.md
- Author/contact: the public `funding.json` manifest.
- App guidance: `Shared/HowItWorksSheet.swift`, `Shared/RealtimeBlockingBetaSheet.swift`, `Shared/SharedStore.swift`, `iOS/Blocking/BlockingRules.swift` and `RealtimeShield/SampleHandler.swift`.

The store description lists YouTube Shorts and Instagram Reels/Stories. Current source explicitly names Facebook Reels/Stories and short videos on X. The maintainer confirmed recognition across social apps; the landing describes this screen-based behavior and its fallibility, separately from whole-app blocking. Capture/export code is DEBUG-only; the public store description contains older debug-capture wording. The site explains Release handling and preserves the policy text unchanged.

Android is research/prototype scope in a proposed grant, not an available product. Build verification is proposed work, not a completed audit.

## Images

`img/optimized/` contains responsive WebP assets with JPEG fallbacks for screenshots and the mascot. All image elements have intrinsic dimensions. The hero is eager/high-priority; lower screenshots are lazy. The iPhone bezel preserves transparency and uses a PNG fallback.

The iPhone screens were freshly captured on 17 November 2026 from the current local iOS build, in English, on the dedicated iPhone 17 Pro Max simulator. They show setup, the updated Apps/monitoring interface, and Safari. The existing screenshot presentation mode supplies sample app rows and monitoring state; these are captures rendered by the app, not evidence of live Screen Time or ReplayKit operation. Full 1320 × 2868 screen images sit inside the existing iPhone bezel without advertising headings or backgrounds.

The Mac section is text-only at the user's request. It explains Safari support without a screenshot or illustrative window. The iPhone screenshot fixture uses the existing bundled service icons so Instagram, YouTube and TikTok are recognizable; this change is limited to the DEBUG simulator presentation branch and does not alter Release behavior. See `img/optimized/provenance.json` for the latest iOS capture hashes and the retained Apple resource license for the frame.

Historical image URLs remain intact, but the page no longer loads the old iPhone gallery or Mac posters.

`img/social-preview.jpg` is a 1200 × 630 link preview using the existing mascot. Canonical/Open Graph URLs use the production domain; the published assets use these URLs.

## Checks

- Verify links and anchors, one H1 per page, image dimensions/alt text and responsive source candidates.
- `python3 scripts/render_slowth.py --check` verifies all generated pages; `python3 scripts/check_slowth.py` checks routes, translations, links, SEO metadata and preservation of the original policy text. The older `render_privacy.py --check` entry point checks all 64 privacy pages.
- Preview at 375, 768 and 1440 CSS pixels; inspect navigation, screenshots, FAQ disclosures, focus and overflow. Check all policy languages, especially Arabic RTL.
- Measure cold navigation consistently; a cached Resource Timing entry with zero bytes is not an empty resource. Safari versions without `layout-shift` observation cannot supply CLS.

See `REVIEW.md` for the current review result and remaining browser checks.

## Localization

The locale registry matches all **64 `appLanguages` entries** in the app’s `Localization/locales.json`, including regional variants. Each has a landing page, Support and Privacy: **192 canonical pages**. The contribution form in `test-cases/` is a separate tool and is unchanged.

English retains `/`, `/support.html` and `/privacy.html`. Other landing pages use `/{locale}/`. Existing Arabic, German, Mexican Spanish, French, Hindi and Japanese privacy URLs remain stable; the switcher and hreflang point to those original paths.

Edit `localization/messages/{locale}.json` for translations. English source strings and their formats are in `localization/source.json`; shared HTML is in `localization/templates/`, with structured data in `localization/schema.json`. `privacy-content.json` remains the source of the seven existing policies and overrides those policy paragraphs during generation. Add new strings consistently to source, templates and every message catalog; generation fails on missing or obsolete keys.

```sh
python3 scripts/render_slowth.py
python3 scripts/render_slowth.py --check
python3 scripts/check_slowth.py
# Optional parity check against an app checkout:
python3 scripts/check_slowth.py --app-locales /path/to/mini-block/Localization/locales.json
```

Translations were prepared with machine assistance, with editorial corrections to Russian, headlines, navigation, operational wording and translation artifacts. Nigerian Pidgin was authored separately. App terminology was reused where available. This is not a claim of professional native-speaker or legal review in 64 locales. English regional variants deliberately share the English copy. Screenshots and the official App Store badge retain their original English artwork; image alternative text is localized.

The language chooser uses native HTML details/links, preserves the current page type and needs no JavaScript, cookies, translation API or automatic redirection. Arabic, Egyptian Arabic, Hebrew, Shahmukhi Punjabi and Urdu use RTL layout. Each page has a self-canonical URL and reciprocal hreflang for all locales, plus English x-default. Search-engine support for individual language codes can vary.
