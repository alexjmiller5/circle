# Circle

A native iOS and macOS app for exploring your people and staying in touch.

The current native explorer has three layouts: **Constellation**, **Pathways**
and **Orbits**, drawn full screen with profile photos on the people. Search for a
person, focus a group, follow recorded introductions, return to a previous
selection, swipe to pan (a flick keeps gliding), pinch or use zoom buttons, and
drag nodes with a pointer on the Mac. The small menu in the bottom-right corner
holds layout, grouping and display options, plus Refresh and Connection.
Display preferences persist locally. Reduced Motion is respected. Track people
locally for the reach-out list, set separate contact and hangout cadences,
priority, qualifying interactions, reminder preferences and snooze. Unknown
history stays explicit. Preview preferences are isolated from connected data.

Normal launch offers a read-only People connection through browser-approved
Life Data enrollment. A complete refresh replaces the graph; failed refreshes
preserve its private offline copy. The **Map** tab pins people at their single
current base with their photo, groups everyone in one city (and in cities that
would overlap at the current zoom) under one pin that opens a chooser, filters
by circle and groups circles as where you met. A person
sheet shows circles, base history, hometown, presence and the newest profile
photo per platform, then the person's reach-out history and settings. **Current
presence and hometown are not connected yet.** The development preview
contains only explicitly labeled synthetic people, locations and contact history. Shared circle
membership does not imply friendship; residence and current presence are shown
separately, with missing facts marked Unknown.

## Development

Requires macOS, Xcode, XcodeGen, Swift, uv and just. No external Swift packages.
The app targets iOS 17 and macOS 14 or later.

```sh
just test                    # graph logic and call-reader fixtures
just check                   # Mac build
just run --preview-graph     # synthetic Mac explorer
just run                     # normal connection screen
just test-ui                 # Mac UI tests
CIRCLE_DESTINATION='platform=iOS Simulator,name=iPhone 17' just test-ui
```

`project.yml` generates `Circle.xcodeproj`; open the generated project for
interactive development. `CIRCLE_DERIVED_DATA` overrides the build cache,
which defaults to `~/Library/Developer/Xcode/DerivedData/Circle`.
`--reset-explorer-preferences` resets only preview display preferences.
`--reduce-motion` disables preview animation for deterministic interaction tests.

Debug builds use the development bundle ID `com.example.circle`; Release
builds use `com.alexmiller.circle`. These commands build local development
artifacts. XCUITest may request the Mac user's approval to enable UI Automation.
Secure enrollment needs a correctly signed build and the device's unlocked
Keychain. Replacement devices enroll independently; credentials are never
exported or recovered from another app. No iCloud sync is bundled.

## Local Mac signing

Ad hoc Mac builds support the preview and UI checks. Secure People enrollment
also requires a valid Mac provisioning profile and a matching Developer ID
Application identity. An iPhone profile cannot authorize this Mac Keychain.
Embed the Mac profile at `Contents/embedded.provisionprofile`, claim only this
app's identifier, team and private default Keychain group, and keep sandboxing
and outgoing network access enabled. Use a disposable signing keychain.

When signing a Debug artifact, sign its embedded debug libraries with the same
identity before signing the app. Remove UI-test exceptions from the normal app.
Verify the signature, certificate/profile match and exact entitlements before
launching it. This local check does not notarize, release or deploy the app.
Never replace native Keychain storage with a plaintext credential file.

## iPhone install

The iPhone build is an Ad Hoc IPA signed on GitHub Actions for the devices
registered in the Apple Developer account; nothing is published.

```sh
umask 077
age-keygen -o <private-identity>            # per dispatch, kept locally
age-keygen -y <private-identity>            # public recipient
gh workflow run build-ios.yml -f artifact_recipient=<public-recipient>
gh run watch <run-id> --exit-status
gh run download <run-id> --dir <private-dir>
age --decrypt -i <private-identity> -o <private-dir>/Circle.ipa <private-dir>/<artifact>/App.ipa.age
OTA_TTL=3600 just ota <private-dir>/Circle.ipa
```

`just ota` prints an install page on this Mac's tailnet name. Open it in Safari
on the iPhone with Tailscale connected and tap Install. The CI service account
and its GitHub secret come from `op-project-bootstrap .env.tpl --repo <owner>/circle`.

## Connect People

Enter your Life Data service's HTTPS origin and choose **Connect to People**.
Open the approval link and verify its code and read-only grants. Circle keeps
its generated device credential in the native Keychain. The operator configures
`circle-reader`; customers never enter table names or an operator token.

The service-owned `circle.reader` configuration binds the logical people,
relations, locations and optional photos fields documented in
`CirclePeopleBindings`. Its column grants cover identity, display name,
circles, directed relationships, residence claims, photo records and
tombstones; photo bytes come only from the configured file prefixes. It grants
no writes, messages, streams, schema or replica synchronization. Circle checks the canonical Life
Core enrollment policy, exact grants and profile revision before reading.

Choose **My person record** to anchor your graph without guessing identity.
Tracking, cadence and graph preferences are local to the connected profile.
Residence is separate from presence; conflicting current residence claims stay
unknown. Same-named cities in different countries remain separate.

The private graph cache lives in the app's Application Support directory with
restricted file permissions. Cached presence is never reused. **Refresh** scans
all authorized pages before publishing; independent table reads are not an
atomic snapshot. **Disconnect and remove cached people** revokes the device
credential and clears the offline graph. Unconfirmed revocation retains the
credential for retry and displays the remaining action. A cancelled or expired
unapproved link is not proof of server revocation; check service devices if it
was approved afterward.

The bundled pure policy is pinned by `scripts/bundle_life_core.py`. Rebuild it
from the script's pinned clean Life Data revision with `--source <checkout>`;
networking and secure storage remain native. Synthetic fixtures never contact
or modify the real service.

## Map

Bases are city and country text, geocoded on the device one at a time and
cached privately per connection, so pins are city-level: everyone sharing a
base shares a pin, and nearby cities merge while their pins would overlap. People with no current base, or with
conflicting current bases, stay unpinned and are counted. Circles describe how
and where you met, so the map never plots them as homes. Presence stays
Unknown until a source with a freshness policy is connected. Photos load
through the connection's own credential, verified against their SHA-256 and
cached by it; a photo stored outside the granted folders is labelled rather
than requested. A flat map cannot frame people on opposite sides of the world
at once; pan to see the rest.

## Reach out

The **Reach out** tab reads the service's maintained per-person, per-channel
communication summaries (iMessage, SMS, RCS, phone, FaceTime audio and video,
WhatsApp) and the import runs behind them. For each person it takes the newest
sent message, answered call and received message across channels. By default
a sent direct message, an answered direct call or a logged hangout resets the
clock; received messages are shown and reset it only if you choose. People are
grouped as Due now, Not contacted in 1 month, Not contacted in 3 weeks, History
unknown, Snoozed and In touch, each with the reason: time since the last
qualifying contact, cadence and due date, priority, snooze, and any newer
incoming message. No qualifying event in the known history is shown as
unknown, never as "never contacted", with each import's coverage (complete or
partial, and why) and the last refresh time.

Message, Call, WhatsApp and FaceTime open that app. The phone number or email
comes from this device's Contacts when you tap: the person's linked address
card first, otherwise a name match you choose from. Nothing is stored, and
opening a conversation never counts as contact. When an app is missing, Circle
tries its fallback (WhatsApp's web link, FaceTime audio for calls on the Mac)
and otherwise says so.

Reminders are local notifications, off until you enable them for a person.
Quiet hours delay them, an option hides names on the lock screen, and Snooze
for a week works from the notification. A fresh qualifying contact replaces a
pending reminder; a delivered one is not repeated. Hangouts have no recorded
source yet, so the hangout cadence has no due date.

## City-only arrival confirmation

The prepared visit engine confirms arrival after two fresh source checks at
least five minutes apart and alerts once per visit. Confirmed departure also
requires two fresh checks before a later visit can alert. Missing, stale or
paused readings cannot prove departure. Saved device/profile state prevents a
restart from repeating an alert. Collection time is not a measured location
fix. The alert core reads one collector record, matches it city-only against
this device's geocoded city (or district) with region and country agreeing when
both show one, and applies the measured freshness cutoff (not paused, displayed
age at most 10 minutes, check at most 15 minutes old); the notification shows
the observed place and says distance unknown. Live source enrollment, this
device's location and notification delivery remain unconnected. The prepared stream reader supports
the service's bounded original-body pages with opaque cursor encoding and
exact read-only enrollment checks. It creates no profile or credential and
does not treat a whole-stream append as a latest-per-person position.

## Call history utility

The read-only macOS SQLite utility is available via `just calls` and as an
installable `circle-calls` package (`nix build .#circle-calls`).
See [its usage and Full Disk Access requirements](scripts/README.md).
Its output contains private contact metadata and must stay outside git.

## Verification

Pure Swift tests cover the summary reader (tombstones, identity, coverage),
reset rules, unknown coverage, groups and reasons, calendar cadence, reminder
planning with a fixed clock, quiet hours, deep links, preference isolation, relationship direction, overlapping groups, unknown
locations, focus restoration, cyclic/disconnected graphs, 1,500-person layouts,
validated preferences and camera bounds. UI tests cover normal/preview launch,
search, layouts, back navigation, city modes, preference restoration, tracking,
reach-out groups, reasons and settings, and gestures on macOS and iOS. An
opt-in iOS simulator smoke opens each deep link through a synthetic contact
card and captures a delivered reminder.
