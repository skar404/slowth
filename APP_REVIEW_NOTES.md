# App Review notes

Hi App Review team,

Slowth is a free iOS app with a Safari Web Extension and an optional Real-time
Blocking beta for YouTube Shorts and Instagram Reels/Stories in the native
apps. Safari blocking supports YouTube, Instagram, Facebook, X, and TikTok.
Real-time analysis runs locally using Screen Time, ReplayKit, and Core ML.

Slowth has no accounts, ads, analytics, tracking, or developer-operated
backend.

## How to test — Safari

1. Install and open Slowth.
2. Go to Settings → Apps → Safari → Extensions → Slowth, enable it, and allow
   access on the supported websites.
3. Return to Slowth. Default modes are:

   - YouTube — Block Shorts
   - Instagram — Block Reels + feeds
   - Facebook — Block Reels + feed
   - X — Block Explore & trends
   - TikTok — Block site

4. Test in Safari:

   - youtube.com — Shorts tabs and entries are hidden; Shorts URLs open in the
     standard video player.
   - instagram.com — Reels are blocked; feed mode also limits Home, Explore,
     Stories, and additional Reels surfaces.
   - facebook.com — Reels/Watch are blocked; feed mode limits Home after
     several screens.
   - x.com — Explore and trends are hidden or redirected to Home.
   - tiktok.com — the whole site shows Slowth’s local blocked page.

5. Set Instagram to Off and refresh instagram.com; it should load normally.

Do not enable Strict mode during normal testing: it prevents reducing or
disabling settings for 24 hours.

## How to test — Real-time Blocking Beta

This feature requires a physical iOS device.

1. Enable “Real-time app blocking” and approve Screen Time access.
2. Choose exactly one YouTube or Instagram app icon, not a category or “All
   Apps,” then enable the desired Shorts, Reels, or Stories option.
3. Before recording starts, the selected app is intentionally protected by a
   Screen Time shield.
4. Tap Slowth’s recording card and start “Slowth Realtime Shield.” During
   recording, normal app screens remain available; detected blocked content
   triggers the system shield.
5. iOS shows its red recording indicator. Stop recording from the same card or
   system controls; the selected app returns to its protected state.

Soft YouTube blocking is optional and off by default. It supports audio use,
but Picture in Picture may still be blocked after recording stops.

## Business model

Slowth is free, with no subscriptions, ads, analytics, tracking, or third-party
SDKs. Optional consumable tip code exists but is disabled in the current
production configuration pending approval. Tips never unlock functionality.

## Privacy and permissions

Slowth stores settings and cached rules locally. The Safari extension
periodically downloads a public JSON rules file from GitHub Gist; no browsing
history or page content is included in that request.

Website access is used to inspect supported URLs and DOM elements locally and
hide or redirect configured surfaces. Website content is not collected,
stored, or transmitted.

Screen Time access is used only for selected YouTube/Instagram apps. ReplayKit
frames are analyzed locally by Core ML and never leave the device. Frames are
not saved during normal use. Photos access is requested only if hidden
developer debug capture is explicitly enabled.

The bundled Core ML model, weights, and metadata are licensed under GNU GPL
v3.0.

## Demo account

Not applicable. Slowth has no authentication.

Thank you for reviewing. Contact: denis@malina.page.

— Denis M.
