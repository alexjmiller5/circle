# Circle

Native SwiftUI iOS and macOS relationship explorer. The explorer supports
Constellation, Pathways and Orbits with search, focus history, group selection,
base/current city distinctions, pan, zoom, node dragging and saved display
preferences. Circle-local tracking and per-person reach-out settings persist
by profile. Reach-out history remains explicitly incomplete until verified
evidence is connected; reminder preferences do not claim active delivery. Normal launch offers native read-only People enrollment; `--preview-graph`
explicitly opens synthetic data. Contact-history integration, current presence,
photos and notification delivery are not implemented. Never imply preview data
is live.

## Build and verification

`project.yml` is the source of truth. XcodeGen produces the ignored
`Circle.xcodeproj`. Requires Xcode and XcodeGen on macOS. No external Swift
packages. Deployment targets: iOS 17 and macOS 14. Development bundle ID:
`com.example.circle`; signing and distribution are separate work.

- `just gen`: regenerate the Xcode project.
- `just check`: locally signed native build; no installation or deployment.
- `just test`: pure Swift graph/state tests and Python call-reader tests.
- `just test-ui`: XCUITest flows on `CIRCLE_DESTINATION` (default macOS).
- `just run --preview-graph`: launch synthetic Mac preview.
- `just run`: launch unconnected Mac app.
- `just calls --help`: existing call-history CLI.

Secure Mac enrollment needs a matching Developer ID identity and Mac profile,
embedded at `Contents/embedded.provisionprofile`, authorizing the app's private
Keychain group. Ad hoc Mac signing is for preview/UI checks. Sign embedded Debug
libraries with the same identity, remove test exceptions from the normal app,
and use a disposable signing keychain. No plaintext credential fallback.

Set `CIRCLE_DESTINATION` to an explicit available iOS Simulator destination
for build/UI tests. `CIRCLE_DERIVED_DATA` overrides the cache location; keep it
outside cloud-synced folders. UI automation permissions are native user state.

## Source map

- `nudge/nudge/Graph/`: graph values, layouts, preferences, native enrollment, bounded HTTP reads,
  secure Keychain storage and private cache.
- `nudge/nudge/`: native views and explicit synthetic development fixture.
- `GraphTests/`: Swift Testing, including large graphs and invalid preferences.
- `nudge/nudgeUITests/`: real native interactions through XCTest.
- `scripts/call_log.py`, `tests/`: read-only call reader, scoped event identity,
  observed coverage and synthetic SQLite/WAL fixtures. `flake.nix` packages
  `circle-calls` without requiring a checkout at runtime. Unknown source flags
  stay unknown; local inventory is not proof of complete history.

Keep canonical identity and recorded direction. Shared circles never imply
friendship. Base city is not current presence. Unknown is explicit. Views
cache layout positions; no all-pairs force layout per animation frame.

All personal records, credentials, transcripts, contact exports and raw task
snapshots stay outside git. Ignored `designs/` may contain private snapshots;
never force-add it. Build/test artifacts are ignored scratch. Synthetic
preview preferences use a separate key from connected profiles.

## People service boundary

Circle is a dedicated read-only Life Data consumer through its supported API.
The service owns the `circle-reader` profile and `circle.reader` table/column
bindings; personal schema and values never ship in this repo. The approved
reader requires exactly the 16 projected columns modeled by
`CirclePeopleBindings`. No broad token, schema pull, replica sync, writes,
photos or streams follow from that grant. Each device enrolls its own credential
and keeps it in native Keychain storage. Service rotation/revision changes
require explicit reenrollment, never a wider fallback.

Use canonical Life Core policy via the pinned bundled JavaScript resource;
`scripts/bundle_life_core.py` rebuilds it. Never duplicate its validation policy
in Swift. Publish only complete validated reads. Failed refreshes preserve the
last graph and show an error; independent table pages are not a snapshot.
Cache lives under Application Support with private permissions and never
revives current presence. Disconnect clears it after confirmed revocation;
401 alone is not proof an unapproved candidate cannot be approved later.

Use `just gen`, which resolves XcodeGen's real binary so its bundled settings
presets are found. Direct invocation through the Nix profile symlink omits them.
