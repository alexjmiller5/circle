# Circle

Native SwiftUI iOS and macOS relationship explorer. The explorer supports
Constellation, Pathways and Orbits with search, focus history, group selection,
base/current city distinctions, pan, zoom, node dragging and saved display
preferences. Normal launch is unconnected; `--preview-graph` explicitly opens
synthetic data. Live People enrollment, contact-history integration and alerts
are not implemented. Never imply that preview data is live.

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

Set `CIRCLE_DESTINATION` to an explicit available iOS Simulator destination
for build/UI tests. `CIRCLE_DERIVED_DATA` overrides the cache location; keep it
outside cloud-synced folders. UI automation permissions are native user state.

## Source map

- `nudge/nudge/Graph/`: Foundation-only values, layouts, camera and preferences.
- `nudge/nudge/`: native views and explicit synthetic development fixture.
- `GraphTests/`: Swift Testing, including large graphs and invalid preferences.
- `nudge/nudgeUITests/`: real native interactions through XCTest.
- `scripts/call_log.py`, `tests/`: standalone read-only call-reader and fixtures.

Keep canonical identity and recorded direction. Shared circles never imply
friendship. Base city is not current presence. Unknown is explicit. Views
cache layout positions; no all-pairs force layout per animation frame.

All personal records, credentials, transcripts, contact exports and raw task
snapshots stay outside git. Ignored `designs/` may contain private snapshots;
never force-add it. Build/test artifacts are ignored scratch. Synthetic
preview preferences use a separate key from any future connected profile.
