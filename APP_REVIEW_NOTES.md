# App Review notes

Hi App Review team,

Slowth is a free iOS app that includes:

- A Safari Web Extension for blocking distracting website surfaces.
- An optional Real-time Blocking beta for YouTube Shorts, Instagram Reels,
  and Instagram Stories inside the native iOS apps.

Safari blocking supports YouTube, Instagram, Facebook, X, and TikTok.
Real-time Blocking uses Screen Time and ReplayKit, with all screen analysis
performed locally by the bundled Core ML model.

Slowth has no accounts, advertisements, analytics, tracking, or
developer-operated backend.

## How to test — Safari Extension

1. Install and open Slowth.

2. Open Settings → Apps → Safari → Extensions → Slowth and turn the extension
   on. Allow access on the supported websites so the extension can apply its
   blocking rules.

3. Return to Slowth. The Sites section contains a mode picker for every
   supported website. Blocking modes are enabled by default:

   - YouTube — Block Shorts
   - Instagram — Block Reels + feeds
   - Facebook — Block Reels + feed
   - X — Block Explore & trends
   - TikTok — Block site

4. Open Safari and test the supported websites:

   - youtube.com — Shorts tabs, shelves, and entries are hidden. Shorts URLs
     are redirected to the standard video player.
   - instagram.com — Reels navigation and URLs are blocked. The default feed
     mode also limits the home feed, Explore, Stories, and additional Reels
     surfaces.
   - facebook.com — Reels, Watch, and video surfaces are blocked. The default
     feed mode also limits the home feed after several screens.
   - x.com — Explore and trending surfaces are hidden or redirected to Home.
   - tiktok.com — the entire website is replaced with Slowth’s local blocked
     page.

5. Return to Slowth, set Instagram to Off, then refresh instagram.com.
   Instagram should load normally again.

Please do not enable Strict mode during testing unless you specifically want
to test it. Strict mode prevents settings from being reduced or disabled for
24 hours.

## How to test — Real-time Blocking Beta

This feature requires a physical iOS device.

1. Open Slowth and enable “Real-time app blocking.”
2. Tap “Allow Screen Time access” and approve the system authorization
   request.
3. Tap “Choose YouTube app” or “Choose Instagram app” and select exactly one
   corresponding app icon. Do not select a category or “All Apps.”
4. Enable one or more content options:

   - Block YouTube Shorts
   - Block Instagram Reels
   - Block Instagram Stories

5. Before screen recording starts, the selected app is intentionally
   protected by the system Screen Time shield.
6. Tap the screen-recording card in Slowth and start the “Slowth Realtime
   Shield” broadcast.
7. While recording is active, regular YouTube or Instagram screens remain
   available. When the on-device model detects an enabled blocked surface,
   Slowth applies the system shield.
8. iOS displays its standard red recording indicator while monitoring is
   active.
9. Stop recording from the same card or through the system recording controls.
   The selected apps return to their protected state.

Optional Soft YouTube blocking is off by default. When enabled, it provides a
short unlock path intended for audio playback, although Picture in Picture may
still be blocked after screen recording stops.

## Business model

Slowth is free. It has no subscriptions, advertisements, analytics, tracking,
or third-party SDKs.

The codebase contains optional consumable tip products, but the tips feature
is disabled in the current production configuration pending approval. Tips
never unlock features or change app functionality.

## Privacy

Slowth does not collect or transmit browsing history, page content, screen
frames, or personal information.

The app stores only its settings and cached blocking rules locally in its App
Group container.

The Safari extension periodically downloads a public JSON rules file from
GitHub Gist. This request contains no browsing history or page content. There
is no developer-operated server.

Real-time Blocking analyzes ReplayKit screen frames entirely on the device.
Frames are not uploaded or saved during normal use. A hidden developer debug
mode can save confirmed detection frames to Photos only after debug capture
and Photos access are explicitly enabled.

The bundled Core ML model, trained weights, and runtime metadata are licensed
under GNU GPL v3.0.

## Permissions explanation

Website access:

The Safari extension inspects supported website URLs and DOM elements locally
to hide or redirect the configured surfaces. Website content is not collected,
stored, or transmitted.

Screen Time / Family Controls:

Used only when the user enables Real-time Blocking and chooses the YouTube or
Instagram app to protect.

Screen recording:

Used only while Real-time Blocking monitoring is active. ReplayKit provides
frames to the local Core ML classifier. No screen frames leave the device.

Photos:

Not used during normal operation. Access is requested only if the hidden
developer debug-capture option is explicitly enabled.

## Demo account

Not applicable. Slowth has no authentication or user accounts.

Thank you for reviewing Slowth. If anything is unclear, please contact
denis@malina.page.

— Denis M.
