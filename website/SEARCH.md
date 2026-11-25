# Search visibility — audit 26 November 2026

The redesigned English site was published on 17 November 2026. This update adds static translations for all 64 app locale variants. Search Console/Bing submission and indexing remain unverified.

## What changed

- The landing now leads with Reels/Shorts blocking **inside apps** on iPhone and iPad. Safari is a separate secondary feature.
- Instagram, YouTube, Facebook and X (Twitter) are named in visible content. The maintainer confirmed broader short-video recognition across social apps; `InAppBlockingCopy.supportedContent` independently names the four services. Screen-based recognition can make mistakes as layouts change.
- Snapchat/TikTok and arbitrary app selection are explained without promising perfect recognition or removal of native app tabs. No selection-count marketing claim.
- Specific title/description and matching Open Graph text; a canonical URL; crawlable static HTML and internal links to setup; visible answers to Reels, Shorts, Facebook/X and Snapchat/TikTok questions.
- `SoftwareApplication` JSON-LD identifies the app, platforms, developer, free offer and official download/source URLs. No invented ratings or reviews. This is descriptive markup, not a guarantee of rich results.
- `sitemap.xml` lists 192 canonical public landing/support/privacy URLs. It deliberately omits test-cases, internal review notes, duplicate index.html and historical assets. No artificial last-modified dates.

## Historical live observations (malina.page, 17 November 2026)

After the English publication, GitHub Pages reported the exact deployed commit as built. Live HTML and assets matched the local release after accounting for Cloudflare email protection and injected edge scripts. No noindex response header was observed. Localized pages still require recrawling after their deployment; publication alone does not prove indexing.

The live root robots.txt returned HTTP 200 and Cloudflare-managed rules. Googlebot, Bingbot and OAI-SearchBot fall under the wildcard Allow rule; GPTBot and several training crawlers are blocked. Search access and training consent are distinct. This is a robots-rule inspection, not proof that Cloudflare allows requests from each crawler's actual IP range. No Cloudflare settings or training permissions were changed.

Google says AI search uses normal SEO foundations; no special AI text file or schema is required. OpenAI recommends allowing OAI-SearchBot and its published IP ranges for ChatGPT search. Neither indexing nor citations/ranking can be guaranteed.

Sources:
- https://developers.google.com/search/docs/appearance/ai-features
- https://developers.openai.com/api/docs/bots
- https://malina.page/robots.txt

## Indexing follow-up

1. Verify the deployed HTML, canonical URLs, sitemap and response headers; ensure no noindex or unintended crawler block is introduced by hosting/CDN.
2. Submit `https://slowth.app/sitemap.xml` in Google Search Console and Bing Webmaster Tools. Request recrawling of the landing and Support. The HTML sitemap link is not a substitute for submission or a root robots Sitemap directive.
3. Use URL Inspection and CDN crawler logs to confirm actual crawling. Keep the existing training opt-out independent from search access.
4. Measure impressions/clicks for “block Instagram Reels iPhone”, “block YouTube Shorts in app”, “Facebook Reels blocker”, “X Twitter video blocker”, and “Snapchat app blocker”. Evaluate citations separately; a manual AI query is not a stable ranking metric.
5. The Russian page is `/ru/`; its visible copy and metadata describe “блокировка Reels в приложении”. Equivalent localized pages cover the other app languages. They use self-canonical URLs, reciprocal hreflang and crawlable links, with no automatic language redirect. This is technical eligibility for discovery, not a ranking or AI citation guarantee.

The 64 locale identifiers match the app, including regional variants. Search annotations use the 61 locales with Google-supported codes; `fil`, `pcm` and `yue` are omitted from the head hreflang cluster without substituting a different language. Their pages retain self-canonical URLs, original HTML language codes, navigation links and sitemap coverage. English regional variants intentionally share content; their self-canonical URLs remain until URL Inspection supplies evidence for a different policy.

Localization references:
- https://developers.google.com/search/docs/specialty/international/localized-versions
- https://developers.google.com/search/docs/specialty/international/managing-multi-regional-sites


## Audit and remaining external steps — 26 November 2026

- Local generation and SEO validation passed for all 192 pages. The production sitemap matched all 192 canonical URLs. Root, Russian, Spanish, German and Australian English landing pages had the expected canonical/alternate metadata and SoftwareApplication. HTTP redirects to HTTPS with 301.
- GitHub About already links to `https://slowth.app` and includes `ios`, `macos`, `safari-extension`, `digital-wellbeing`, `youtube-shorts`. No repository metadata change is needed.
- SoftwareApplication already declares iOS, iPadOS, macOS, UtilitiesApplication, a free USD offer and the official App Store download. Checks now validate these values, duplicate hreflang and case/comma variants of robots noindex. No ratings or reviews are fabricated to satisfy rich-result eligibility.
- FAQPage describes all nine visible questions and answers on each of the 64 landing pages. It is generated from the rendered localized FAQ, with matching text checked in CI and the production audit. This is descriptive markup: Google stopped displaying FAQ rich results on 7 May 2026, so it is not a promise of expanded Google results. See https://developers.google.com/search/updates#may-2026.
- The owner confirms the GSC property is verified. Authenticated inspection, sitemap submission and the homepage indexing request still need to be completed; no indexing claim is made from an HTTP check.
- App Store Connect read-only inspection found `https://malina.page/slowth/` in all 50 localizations of version 2026.11.2 on both iOS and macOS. The separate App Store project now provides a marketing-URL-only operation for the next editable release. No new version, build or App Review submission is part of this SEO change.

After deployment run `python3 scripts/check_slowth_live.py`. In GSC compare the declared and Google-selected canonicals for `/` and `/en-AU/`, run the live homepage test, submit `https://slowth.app/sitemap.xml`, and request homepage indexing. Record submission acceptance separately from later crawl/index status. Crawler policy is not modified by this SEO change.
