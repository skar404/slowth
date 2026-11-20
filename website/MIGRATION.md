# slowth.app migration

The public website lives in `website/` in `skar404/slowth`. The `Website` GitHub Actions workflow validates all 64 locales and publishes only public files to GitHub Pages. Translation sources and review notes stay in Git but are excluded from the deployed artifact. No app build or version bump is involved.

Production origin: `https://slowth.app/`. Canonical URLs, hreflang, Open Graph images, JSON-LD and sitemap use this origin. `robots.txt` advertises the sitemap.

Cloudflare DNS: apex and www point to `skar404.github.io` (DNS-only CNAME; apex flattening). GitHub Pages custom domain is `slowth.app`; enable enforced HTTPS when its certificate is issued.

The old marketing routes under `https://malina.page/slowth/` redirect to the corresponding path on the new domain. Keep the test-case upload application and its API on their existing origins: its cookies and CORS are origin-sensitive. `/test-cases/` on the new site forwards there, preserving query and fragment.

Old links inside shipped apps remain functional through the redirects. App Store metadata and search-engine property verification are separate from publishing the website. Submit the new sitemap in verified search consoles when available; deployment does not establish indexing.

Local checks:

```sh
python3 scripts/render_slowth.py --check
python3 scripts/check_slowth.py --app-locales Localization/locales.json
python3 -m http.server 8794 --directory website
```
