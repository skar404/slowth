# Local redesign review — 17 November 2026

Status: implementation reviewed; user approved publication on 17 November 2026. Deployment verification is recorded in the delivery conversation.

## Scope

- English product landing: iPhone/iPad app protection first, setup, Safari, privacy, FAQ, maintainer and proposed funding.
- Support rewritten from current Release code and the available App Store description.
- Cream/green/peach styling shared with the seven existing policy pages. Policy HTML and JSON are byte-identical to the starting checkout. `test-cases/` is unchanged.
- Responsive WebP/JPEG screenshots, real iPhone frames without advertising backgrounds/headlines, a text-only Mac support section, link-preview image and metadata.
- Existing asset URLs are retained. No app, API, version, hosting or routing changes.

## Source and static checks

Passed: one H1 per page, local file references and fragments, screenshot srcset candidates, explicit image dimensions, alt attributes, no external fonts/scripts/analytics, and unchanged privacy generation (`python3 scripts/render_privacy.py --check`). All chosen text/focus foregrounds on the five page backgrounds exceed 4.5:1 contrast. The landing uses native `details`/`summary`, visible focus and a skip link.

App Store, source-repository and public-budget links returned HTTP 200. The budget link passed on retry after a transient 503. All local links are validated separately from remote service availability.

## Image payload comparison

Decimal kB; local file sizes, before HTTP compression. Comparison at 2× display density.

| Measurement | Bytes | Interpretation |
| --- | ---: | --- |
| Previous seven gallery JPEGs | 1,158,391 | Original assets loaded by the old gallery |
| Current three screenshots + shared iPhone frame/mask | 128,905 | 640 px iPhone WebP candidates; 88.9% less than the original gallery. Mac is text-only. |
| Same seven old images at 440 CSS px height, 2×, WebP | 216,810 | Equal-content, equal-display-size encoding control: 81.3% below original payload |
| Same control at 360 CSS px height, 2× | 170,132 | Mobile gallery display-size control |
| Entire new page with 2× WebP candidates | 231,180 | Conservative sum including HTML, CSS, all three screenshots, frame/mask, logo, badge and favicon |
| Entire new page with 2× JPEG/PNG fallbacks | 413,047 | Conservative fallback sum |

The first viewport uses a subset of the whole-page assets above and fits the 500 kB target at the measured 2× density. These are reproducible payload totals, not an observed cold-network waterfall. The image-content change and encoding improvement are reported separately. Legacy files retained for URL compatibility do not load on the new page.

The selected phone UI is larger than it was inside the full App Store poster. WebP quality 86 / JPEG quality 88 are used for the UI; the same original source screen and physical aspect ratio are retained.

## Browser observations and remaining checks

HTTP preview opened in native Safari. The revised 375 × 900 CSS-pixel page rendered with a document width of 375 and no overflow; the 1440 × 900 check reported a document width of 1440 and no overflow. The revised mobile hero and frame were visually inspected. The initial mobile overflow in the decorative version was corrected by removing the rotated poster presentation.

The available Safari reports LCP but does not support the `layout-shift` PerformanceObserver entry type. Cached local LCP readings (about 26–36 ms) are not a cold before/after benchmark. Resource Timing contained zero-size cache entries, so those transfer numbers were not used for the table above.

The browser access host was unavailable, and native control attempts were repeatedly rejected with “The user changed [Safari]”. Therefore these items remain unverified:

- Full visual sweep at 768 px and full-page desktop screenshots.
- End-to-end keyboard/focus interaction and native FAQ toggling.
- Visual rendering of every privacy locale, including Arabic RTL.
- Comparable cold-navigation request counts, LCP and CLS. Do not interpret the unsupported CLS metric as zero.

A separate no-store local QA server/harness was prepared for these checks; QA tooling is outside the published site. Finish these checks before publication. Commit and publication require the user's post-preview confirmation as specified in the approved plan.

## Current iOS captures and Mac presentation

All three iOS screens were freshly captured from the current local simulator build in English. The existing screenshot fixture now uses bundled Instagram, YouTube and TikTok artwork instead of generic green placeholders. The change is inside `#if DEBUG && targetEnvironment(simulator)`; it does not affect Release app behavior. The iOS build passed, and captured images were inspected for visible icons and legible UI. Screenshot demo state is not a live Screen Time/ReplayKit test.

The user ultimately chose to remove the macOS image entirely. The final Mac section is text-only; both the illustrative mockup and real window capture are absent from the page. Historical public Mac poster URLs remain; unpublished derivatives created during this task were removed. No commit, publication or App Store upload occurred.

The final Apps capture uses the existing `--screenshot-recording-off` state. Each icon sits beside the entire title-and-rules column, so descriptions align under app names instead of under icons. This is rendered by the simulator screenshot fixture; no pixels were manually retouched. The targeted Debug build and image inspection passed.

## App-first design and search review

The hero now states “Block Reels & Shorts. Inside your apps.” App blocking and setup come before Safari. The maintainer confirmed Facebook, X (Twitter) and broader short-video recognition across social apps; wording now reflects this and explains screen-based detection errors. Any-app selection is stated without a numerical marketing limit. Support is app-first too.

Reduced the oversized hero heading, balanced its tablet columns, tightened section spacing and corrected a mobile navigation specificity conflict that squeezed the logo. Preserved the real iPhone frames, inactive monitoring screenshot and text-only Mac section.

Native Safari observations after the revision: hero at 375, 768 and 1440 CSS pixels; app section at 768; setup at 375; FAQ at 1440. The harness reports no horizontal overflow at all three widths. A FAQ answer opened on click and Tab visibly focused the next disclosure with a high-contrast outline. A complete keyboard sweep and every privacy locale are still not verified; later native automation timed out during the Support check. Earlier browser limitations above describe the initial pass, not failure of these later observations.

Static checks passed for H1 count, duplicate IDs, local file references and fragments, alt/intrinsic dimensions, JSON-LD syntax, all nine sitemap URLs, and unchanged privacy HTML. The new markup is descriptive, with no invented ratings or reviews. The page stays static and adds no tracking or executable client scripts.

Search implementation, live crawler-rule observations and indexing follow-up are in SEARCH.md. Indexing and AI citations are not guaranteed by deployment.


## Localization review — 17 November 2026

The locale set matches all 64 app language/region variants. Landing, Support and Privacy produce 192 canonical pages. Existing privacy policy paragraphs and historical URLs are preserved. The contribution tool and image assets are unchanged.

Validation covers complete message catalogs, balanced/trusted inline markup, preserved links, missing files/anchors, image dimensions and alternative text, one H1 per page, self-canonical URLs, reciprocal hreflang, JSON-LD parsing and language, sitemap coverage, and unchanged policy paragraphs. Operational values for the 24-hour lock, 5–15-second detection rest and proposed $10,000 grant were checked across locales. A scan caught and removed leftover English passages and translation batch markers. Regional English variants intentionally share copy.

Visual samples include Russian and Arabic at 375 CSS pixels, Japanese at 768 and German at 1440. The language menu was opened and used to switch from Russian to Arabic. Shared mobile footer wrapping was corrected for long translations. CSS content hashes prevent older cached styles from masking layout fixes.

The translations are machine-assisted with editorial corrections; this is not native-speaker or legal review of every locale. English screenshots and the official store badge retain their original artwork. Browser checks cover rendering and navigation, not physical-device app behavior or search-engine indexing.

Final Safari layout audit: all 192 pages at 375, 768 and 1440 CSS pixels (576 cases), with language menus both closed and expanded, completed without document overflow or off-screen menus. This is a browser geometry check plus the visual samples above, not a pixel-by-pixel visual review of every page.
