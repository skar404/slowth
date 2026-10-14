# Release versioning

- Use `year.month.index` for marketing versions (for example, `2026.8.1`); omit leading zeros so the version is valid in the WebExtension manifest too.

- When changing the app's marketing version, also increment the build number. Use one monotonically increasing build counter across all versions and both iOS and macOS; never reset it for a new version.
- Increment the build number for each new build intended for upload to App Store Connect, including replacement builds of the same marketing version. Ordinary local builds do not need an increment.
- Keep `CURRENT_PROJECT_VERSION` identical for the host apps and every extension. Update the base setting and all target overrides in `project.yml`; choose a number greater than every current value and any higher uploaded value known in the conversation.
- Keep `MARKETING_VERSION`, `WebExt/manifest.json`'s `version`, and the version label in `WebExt/app.html` synchronized.
- Regenerate the Xcode project with `xcodegen generate` and verify the resulting version/build settings.
