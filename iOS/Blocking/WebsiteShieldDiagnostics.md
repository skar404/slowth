# App shields and Safari websites

The product requirement is to retain native-app blocking with recording stopped,
while leaving websites available to the independent Safari extension rules.
The production blocking policy has not changed. No stale-web-settings cleanup
has been added: the device inspection found no web settings to clear.

## Inspector

`Debug/iOS/ManagedSettingsDiagnostics.swift` is compiled only for iOS Debug.
Open **Inspect Managed Settings** in the Debug section for read-only inspection.
For a baseline before `AppState` activates and reconciles restrictions, launch:

```sh
xcrun devicectl device process launch --device <device> --terminate-existing \
  <app-bundle-id> --diagnose-managed-settings
```

Refresh exports `Documents/ManagedSettingsDiagnostics/latest.json`. It contains
store names, policy kinds, counts, OS/app versions and recording/Strict state.
It excludes tokens, domain names, application identities and browsing data.
It describes this app's configuration, not effective restrictions from all
sources. Reading the report does not change restrictions or the pause ledger.

On iOS 26.5+, `ManagedSettingsStore.stores` enumerates this app's stores; the
inspector also includes the default store. Older systems use the known default,
historical `UnscrollShield`, and `RealtimeShield.*` names. Their reports explicitly
mark enumeration incomplete; absence of web settings there is not exhaustive.

## Controlled one-app probe

The dedicated launch above also enables **One-app probe…** on iOS 26.5+.
The ordinary settings sheet has no probe controls. Stop recording first; the
probe rejects Strict mode, pause leases and unfinished detection rests. It also
requires grouped selection with no other active app/category/web restrictions
in this app's stores. Do not change rules, recording or pauses during the test.

Choose a token using its system-provided label. The probe first copies the
remaining blocked apps into `Slowth.WebsiteProbe.OtherApps`, then narrows
`RealtimeShield.group` to the chosen token. The test operation is simply:

```swift
store.shield.applications = [token] // Block probe app
store.shield.applications = nil     // Release probe app
```

The other apps remain shielded in the temporary store. No web setting is written.
Reload the same website in Safari after each change, since already-loaded content
can remain visible until navigation. Test blocked → released → blocked.

**End probe** restores the saved app-token set before clearing the temporary
store. A local opaque receipt also enables restoration on next host launch.
If the saved selection or recording session changed, obsolete protection is not
restored; quit and launch Slowth normally so its coordinator reconciles current
rules. The receipt is never included in the exported report. Preferences and
pause/rest records are not edited by the probe. Relaunch/crash recovery is
implemented but was not separately fault-injected in the device run below.

Afterward, launch without the diagnostic argument to resume the normal host:

```sh
xcrun devicectl device process launch --device <device> --terminate-existing \
  <app-bundle-id>
```

## Physical result, 2026-11-17

Observed through iPhone Mirroring on iPhone 17 Pro Max, iOS 27.2 (24B119),
Slowth Debug 2026.11.1 (34), Instagram 455.0.0 (1109782713). Recording and Strict
were off. Safari extension preferences were unchanged during the experiment.

All enumerated Slowth stores had `shield.webDomains == nil`,
`shield.webDomainCategories == nil`, `webContent.blockedByFilter == nil`,
`shield.applicationCategories == nil` and `application.blockedApplications == nil`.

| State | Group app tokens | Other-app tokens | Safari instagram.com |
| --- | ---: | ---: | --- |
| Probe blocked | 1 (Instagram) | 9 | System **Restricted** page after reload |
| Probe released | 0 | 9 | Website loaded |
| Probe blocked again | 1 (Instagram) | 9 | System **Restricted** page after reload |
| Probe ended | 10 | 0 | App protection restored; native Instagram showed Slowth **Blocked** |

The initial earlier baseline had nine selected apps; the probe started with ten
and restored that ten-app set. No app identities or token values were exported.
Sanitized snapshots and a Feedback draft are saved locally under
`reports/website-shield-2026-11-17/` (git-ignored).

This reproduces coupling between the Instagram application shield and its
website on this device/OS. It does not establish behavior on every iOS version,
the internal platform mechanism, or that no supported alternative exists.
Removing the app shield opens both surfaces and does not satisfy the product
requirement. A website-access fix is therefore still unqualified.

The existing blocking tests passed in Debug and Release. Both iOS build
configurations succeeded; the Release executable contains no diagnostic symbols.
Those checks cover build/regression boundaries, not a fix for the Safari result.

## Explicit website shield and button follow-up

The 2026-11-17 follow-up adds a Debug-only website probe. During an active
one-app probe, **Choose website shield…** opens a separate FamilyActivityPicker.
Select websites only, then Apply. This writes only
`Slowth.WebsiteProbe.Web.shield.webDomains`; app/category selections are rejected.
The saved production app selection is not replaced by this picker.

`WebsiteShieldProbe` shares the selected opaque domain tokens with the Shield
configuration/action extensions. A matching website configuration requests the
title **Slowth website test** and a **Release website** button. Its primary action
removes only that domain from the dedicated web store and returns `.none`.
The report's `websiteProbe.lastButton` records the timestamp and before/after
counts without the token. It retains the last event after ending a probe, so
always compare timestamps. Arming a new web probe clears the previous event.
End probe and host relaunch clear the dedicated web store.

Physical observations on the same iPhone/OS:

| Configuration | Safari UI observed in iPhone Mirroring |
| --- | --- |
| Instagram app shield + explicit `www.instagram.com` domain shield | Generic **Restricted**, including after reload |
| Instagram app shield absent + explicit domain shield | Generic **Restricted**, including after reopening Safari |
| Primary button on the displayed system screen | Our action handler executed at 18:22:07 UTC and wrote the domain set from 1 to 0 |

The custom title/button label was not observed. Nevertheless, the action callback
was confirmed by its unique persisted marker. Do not equate a generic-looking
screen with absence of an action callback. Do not equate the write with successful
website access: Safari still displayed Restricted in subsequent observations.
The internal source of that remaining restriction was not established.

Nine other apps remained configured in the temporary app store. A later toggle
was refused because that store's returned token set no longer equaled the saved
set, despite the same count. The probe was ended and restarted instead of
bypassing this guard; this limits claims of an uninterrupted A/B comparison.
The follow-up no-app/no-web snapshot was collected, but a new successful website
load in that state was not visually verified during this run. No configuration
callback trace was collected, and the website UI was not independently checked
on the iPhone display outside Mirroring.

Final export at 18:28:36 UTC confirmed ten app shields in the original group,
no web shields, no temporary-store app shields, and probe inactive. Evidence is
in `reports/website-shield-2026-11-17/web-button/`. Debug/Release builds and blocking
regression tests passed. All seven Release executables were checked for absence
of the diagnostic symbols and strings. The release blocking policy is unchanged.

Result: website-button routing is demonstrated; replacement of the system UI
and an end-to-end website-only unlock remain unqualified.

## Apple references

- [ShieldSettings](https://developer.apple.com/documentation/managedsettings/shieldsettings)
  exposes separate properties for apps, domains and their categories.
- [ManagedSettingsStore.stores](https://developer.apple.com/documentation/managedsettings/managedsettingsstore/stores)
  enumerates the calling app's stores, not other apps' stores.
- [What's new in Screen Time API](https://developer.apple.com/videos/play/wwdc2022/110336/)
  explains named stores and aggregation of restrictions. Clearing one store
  cannot override a restriction contributed elsewhere.

These references do not by themselves promise independent app/associated-domain
enforcement. Ask Apple whether the observed coupling is intended and which
supported API can retain the native shield while allowing the website. Do not
use `clearAllSettings()` as a web-only cleanup: it also removes app restrictions.
