# Circle

Native SwiftUI iOS and macOS relationship explorer. The explorer is a
full-screen graph (Constellation, Pathways, Orbits) with profile photos on
nodes, a floating search/focus bar, details beside it when wide (760 pt+) or in
a half-height sheet otherwise, and one bottom-right menu per tab (layout,
grouping and display options, then Refresh and Connection). It supports focus
history, group selection, base/current city distinctions, finger-tracking pan
with momentum, zoom, pointer-only node dragging (macOS) and saved display
preferences. Circle-local tracking and per-person reach-out settings persist
by profile. Normal launch offers native read-only People enrollment; `--preview-graph`
explicitly opens synthetic data, including synthetic contact history.
The Reach out tab reads the service's maintained communication summaries and
import coverage (never streams or source apps): per person, best-of across
channels for last sent message, last answered call and last received message.
The default clock resets on a sent direct message, an answered direct call or
a logged hangout (no hangout source exists yet); incoming-only activity is
shown but resets only when enabled per person. Groups: Due now (elapsed past
cadence), Not contacted in 1 month, Not contacted in 3 weeks, History unknown,
Snoozed, In touch, each row with its reason. Missing history or no qualifying
event in coverage is Unknown, never "never contacted"; partial import coverage
and the newest refresh are shown. Message, Call, WhatsApp and FaceTime open
the app's own scheme with fallbacks (macOS `imessage:` then `sms:`, `tel:`
then `facetime-audio:`; WhatsApp `whatsapp://` then `https://wa.me/`); the
number or email is read from this device's Contacts at tap time (confirmed
address-book link first, else a name match with a chooser), never stored.
Opening a compose view never counts as contact. Reminders are local
notifications, off by default and enabled per person, with quiet hours,
lock-screen name hiding, a Snooze action and no push server; a request id
names the person and its due or snooze moment, and a ledger keeps a delivered
reminder from repeating.
City-only visit logic requires two fresh checks at least five minutes apart
for arrival and departure, and emits once per confirmed visit. It persists
per person/profile; unknown or paused readings never prove departure.
`NearbyAlerts.swift` parses one `findmy_ax` collector record, matches it
city-only (same city or this device's district, region/country agreeing when
both show one; no metro or distance inference) and defaults to the measured
freshness (not paused, displayed age <= 600 s, check <= 900 s old). This logic
is not connected to a live feed, this device's location or notification
delivery.
The Map tab pins each person with exactly one current base (city-level,
geocoded on device) with their photo; one pin per city, merged with nearby
cities while they would overlap on screen (Mercator distance at the settled
camera), and a multi-person pin opens a photo chooser. It filters by circle,
lists circles as met-where groups and opens a person sheet: circles, base history, hometown (Unknown: no granted
column carries it), presence (Unknown until the collector feed is connected)
and the newest photo per platform, followed by the person's reach-out
sections. Current presence is not implemented. Never imply preview data is live.

## Build and verification

`project.yml` is the source of truth. XcodeGen produces the ignored
`Circle.xcodeproj`. Requires Xcode and XcodeGen on macOS. No external Swift
packages. Deployment targets: iOS 17 and macOS 14. Debug bundle ID
`com.example.circle` (local builds and UI tests, so they never share the signed
app's container or Keychain); Release bundle ID `com.alexmiller.circle`, the
shipped identity, never renamed.

- `just gen`: regenerate the Xcode project.
- `just check`: locally signed native build; no installation or deployment.
- `just test`: pure Swift graph/state tests, Python call-reader tests and the
  signing helper/workflow regressions.
- `just test-ui`: XCUITest flows on `CIRCLE_DESTINATION` (default macOS; the
  mini's locked console cannot enable macOS UI automation, so run the iOS
  simulator there).
  `ReachOutSmokeUITests` is an opt-in iOS simulator smoke
  (`TEST_RUNNER_CIRCLE_SMOKE=1`, after `xcrun simctl privacy <udid> grant
  contacts` for `com.example.circle` and its `.uitests.xctrunner`): it creates
  and removes one synthetic contact card, opens each deep link, checks the
  fallbacks and screenshots a delivered reminder. XCUITest cannot query system
  banners; the attached screen captures show them.
- `just run --preview-graph`: launch synthetic Mac preview.
- `just run`: launch unconnected Mac app.
- `just calls --help`: existing call-history CLI.
- `just ota <ipa>`: serve a verified Ad Hoc IPA as a tailnet install page
  (blocks for `OTA_TTL` seconds, default 900).

Secure Mac enrollment needs a matching Developer ID identity and Mac profile,
embedded at `Contents/embedded.provisionprofile`, authorizing the app's private
Keychain group. Ad hoc Mac signing is for preview/UI checks. Sign embedded Debug
libraries with the same identity, remove test exceptions from the normal app,
and use a disposable signing keychain. No plaintext credential fallback.

Set `CIRCLE_DESTINATION` to an explicit available iOS Simulator destination
for build/UI tests. `CIRCLE_DERIVED_DATA` overrides the cache location; keep it
outside cloud-synced folders. UI automation permissions are native user state.

## iPhone Ad Hoc (CI)

`.github/workflows/build-ios.yml` is manual dispatch only, from the ios-app
template. It reads `OP_SERVICE_ACCOUNT_TOKEN` (the `circle-ci` service account:
read on the Circle vault and the approved shared Apple Signing vault). The
`.env.tpl` and workflow `op://` refs are the bootstrap manifests. Signing uses
the shared Apple Distribution certificate and Wildcard Ad Hoc Profile: the iOS
app claims only its application identifier, team and default Keychain group. A
capability a wildcard profile cannot carry (App Groups, push, iCloud) needs an
app-specific profile first. The device is `Circle ENV/IOS_DEVICE_ID`, checked
against the source and exported profiles.

Each dispatch takes a per-dispatch public age recipient and uploads only the
encrypted `App.ipa.age` (one-day retention). Download, decrypt and verify it
locally, keep the IPA out of synced folders, then install through the paired Mac
or `just ota <ipa>`. `scripts/sign-ios.py` and its tests are the template's;
keep them in sync with it. Never print signing values or device identifiers.

## Source map

- `nudge/nudge/Graph/`: graph values, layouts, preferences, native enrollment, bounded HTTP reads,
  secure Keychain storage and private cache. `CommunicationHistory.swift`:
  summary/import/address-book-link reader; `ReachOut.swift`: assessment,
  groups and reasons; `ReachOutReminders.swift`: reminder plan, quiet hours and
  ledger reconciliation; `ContactLinks.swift`: Contacts matching and URLs. `PeopleMap.swift`: map pins and
  clusters, geocode cache, photo choice, thumbnails and the content-addressed photo
  cache. `NearbyAlerts.swift`: collector records, city-only area rule, freshness
  and alert text over `NearbyVisits.swift`.
- `nudge/nudge/`: native views and explicit synthetic development fixture.
  `ReachOutModel.swift` (per-profile settings, notification scheduling and the
  Snooze action), `ReachOutView.swift`, `ContactActions.swift` (Contacts
  access and URL opening), `CircleChrome.swift` (shared avatar thumbnails and
  the bottom-right menu). `PreviewGraph.swift` serves generated portraits to
  the explicit preview only.
- `GraphTests/`: Swift Testing, including large graphs and invalid preferences.
- `nudge/nudgeUITests/`: real native interactions through XCTest.
- `scripts/call_log.py`, `tests/`: read-only call reader, scoped event identity,
  observed coverage and synthetic SQLite/WAL fixtures. `flake.nix` packages
  `circle-calls` without requiring a checkout at runtime. Unknown source flags
  stay unknown; local inventory is not proof of complete history.

Keep canonical identity and recorded direction. Shared circles never imply
friendship. Base city is not current presence. Unknown is explicit. Views
cache layout positions; no all-pairs force layout per animation frame. The
constellation shelf-packs each group as a disk sized by its own members. A
gesture offsets or scales the already rendered graph layer (twice the
viewport) and commits to the camera in steps; graph nodes are tap gestures,
not Buttons, so a swipe never selects.
Circles are met-where labels and are never plotted as residence; they carry
no place flag, so the map does not geocode circle names. Hometown stays
Unknown unless a granted column carries it. There is no preferred-photo flag:
show the newest `fetched_at` per platform and let the user pick.

All personal records, credentials, transcripts, contact exports and raw task
snapshots stay outside git. Ignored `designs/` may contain private snapshots;
never force-add it. Build/test artifacts are ignored scratch. Synthetic
preview preferences use a separate key from connected profiles.

## People service boundary

Circle is a dedicated read-only Life Data consumer through its supported API.
The service owns the `circle-reader` profile and `circle.reader` table/column
bindings; personal schema and values never ship in this repo. The reader
requires exactly the grants `CirclePeopleBindings.scopes` derives: projected
columns for people, relations, locations and the optional photos binding, the
optional history bindings (`summaries` and `imports` together, `contacts` for
address-book links), plus one `files:read:<prefix>` per photo binding `files`
prefix (live: 56 columns, `photos/people/` and `photos/records/`, 58 grants). History reads are
the full summary table, imports by equality on source (newest live run per
source decides its coverage) and links by equality on the address-book
platform; tombstones are dropped. A failed history read keeps the last
history beside a fresh People graph. Photos are requested only for keys under a granted prefix;
other keys show as stored outside Circle's access without a request. No broad
token, schema pull, replica sync, writes or streams follow from that grant. Each device enrolls its own credential
and keeps it in native Keychain storage. Service rotation/revision changes
require explicit reenrollment, never a wider fallback.

The bundled policy supports exact stream enrollment separately from People
access. `CircleStreamReader` reads one bounded original-body page, preserving
opaque cursors and rejecting duplicate IDs; it makes no current-presence or
full-coverage claim. Only stream records accept bounded query parameters. No
stream enrollment UI or live credential is connected.

Use canonical Life Core policy via the pinned bundled JavaScript resource;
`scripts/bundle_life_core.py` rebuilds it. File grants need a pin whose scope
grammar accepts `files:` (the current pin does); an older pin rejects such a
profile at approval and revokes the candidate. Never duplicate its validation policy
in Swift. Publish only complete validated reads. Failed refreshes preserve the
last graph and show an error; independent table pages are not a snapshot.
Cache lives under Application Support with private permissions and never
revives current presence. Per profile: `<key>.json` graph, `<key>.places.json`
geocode results (misses retried after 7 days, failures never cached) and
`<key>.photos/<sha256>` bytes verified on every read. Disconnect clears it after confirmed revocation;
401 alone is not proof an unapproved candidate cannot be approved later.

Use `just gen`, which resolves XcodeGen's real binary so its bundled settings
presets are found. Direct invocation through the Nix profile symlink omits them.
