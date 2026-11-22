# Browser entitlement request — submitted, awaiting review

Status: **Beta; do not claim Google or passkey acceptance.**

The owner submitted the request on 2026-11-22. Apple's confirmation page was
verified in Safari: “Thank you for your submission.” Request ID: **4GZJ3YZQL7**.
Apple states that it will review the request and contact the applicant with a
status update. This confirms receipt, not entitlement approval or provisioning.
The App ID's Capability Requests page was checked on 2026-11-22: **Default Web
Browser — Submitted**. The browser capability is not yet shown as assigned.

Request `com.apple.developer.web-browser` for the iOS/iPadOS host
`com.malin.unscroll.ios`. Do not request app-installation or alternative engine
entitlements. Do not add third-party Associated Domains.

The request used Apple's
[default browser request form](https://developer.apple.com/contact/request/default-browser-entitlement/)
and the signed-in developer account's contact details. Before the owner's
submission, the form described the upcoming local Beta separately from the
existing App Store release and disclosed that the catalog is not the initial
launch screen. The final submitted field contents were not independently
retrieved from the receipt page.

Implementation summary (not a transcript of the submitted form):

> Slowth provides a focused catalog of Instagram, YouTube, TikTok, Facebook and X
> using the system WKWebView engine on iPhone and iPad. People choose restrictions
> for short videos, infinite feeds or an entire supported site. The app initially
> opens the app-protection screen; the catalog is in the Web apps section. Users
> do not need to make Slowth their default browser.
>
> Instagram and Facebook share a Meta profile; YouTube, TikTok and X have separate
> persistent profiles. External links and authentication popups stay inside the
> originating profile. We use system file pickers, website camera/microphone
> prompts, and WebKit's WebAuthn implementation. We want to support system passkey
> authorization and full website sign-in in these profiles.
>
> This release is intentionally limited to five services. Incoming HTTP(S) links
> to their domains open at the requested destination, subject to the person's
> selected blocking rules. Incoming links outside the catalog show an unsupported
> destination message. There is no general URL-entry field, search, global history
> or bookmark manager. Please confirm that this focused browsing model is eligible
> under the curated-bookmark / restricted-navigation criteria. Google sign-in and
> passkey acceptance are still pending physical-device validation; we do not claim
> that receiving this entitlement guarantees a provider will allow sign-in.

Apple describes curated launch lists, direct HTTP(S) routing and restrictions on
privacy usage keys in [Preparing your app to be the default web browser](https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser).
WebKit handles WebAuthn challenges; the browser credential manager requests the
person's passkey access, as described in [Passkey use in web browsers](https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers).
Eligibility of the limited catalog is a question for Apple, not an inferred approval.

## Prepared candidate configuration

Ordinary Debug/Release Beta builds keep the existing host entitlements. The
candidate uses Release privacy resources (no Debug full-photo-library permission):

```sh
python3 scripts/prepare_release_resources.py
python3 scripts/prepare_browser_candidate.py
xcodegen generate
```

The script creates `build/browser-candidate/Info.plist` with HTTP/HTTPS registration
and the passkey-access UI flag, plus `Browser.entitlements` with the managed
entitlement. It makes no network request. After approval and provisioning-profile
refresh, build with the **host-only** settings:

```sh
xcodebuild -project Unscroll.xcodeproj -scheme 'Relise - iOS' \
  -configuration Release -destination 'generic/platform=iOS' \
  SLOWTH_IOS_RELEASE_INFO="$PWD/build/browser-candidate/Info.plist" \
  SLOWTH_IOS_HOST_ENTITLEMENTS="$PWD/build/browser-candidate/Browser.entitlements" \
  -derivedDataPath build/browser-approved build
```

Do not pass a global `CODE_SIGN_ENTITLEMENTS` override: extensions need their own
entitlements. Inspect the resulting host signature and provisioning profile for
`com.apple.developer.web-browser = true`; a generated file or unsigned build is
not evidence that Apple granted the entitlement. Version/build remains unchanged
for local builds; apply AGENTS.md immediately before any separately authorized
App Store Connect upload.

## Required owner/device acceptance

On chalk, with the approved signed candidate, record provider outcome and exact
visible error (without account identifiers/tokens) for Google → YouTube, password
AutoFill, passkey registration/use, second factor, cancel, and repeated sign-in.
Repeat on a physical iPad. Use the in-Slowth flow; Safari sign-in is not a pass.
If Apple declines or Google prohibits this flow, retain Beta and record the
blocking decision. Do not spoof a user agent or replace WebAuthn with JavaScript.

## Observed blocker on chalk

On 2026-11-22, the owner confirmed that YouTube/Google fails when requesting a
passkey. The screenshot shows Google's generic “Something went wrong” page, not
an explicit disallowed_useragent refusal. The installed Beta host signature and
embedded provisioning profile both lack `com.apple.developer.web-browser`.

WebKit documents that WKWebView passkeys require an entitled browser or a matching
associated domain in [WebKit issue 250912](https://bugs.webkit.org/show_bug.cgi?id=250912).
Apple also describes the ordinary web-view associated-domain requirement in
[Supporting passkeys](https://developer.apple.com/documentation/authenticationservices/supporting-passkeys/).
Slowth cannot claim Google's domain as its own. The managed browser entitlement
and subsequent system user authorization are the intended route; a new ordinary
build cannot supply that approval. The generic Google error alone is not proof of
the exact underlying WebAuthn error code or of future provider acceptance.
