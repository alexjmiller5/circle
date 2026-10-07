# Circle

A native iOS and macOS app for exploring your people and staying in touch.

The current native explorer has three layouts: **Constellation**, **Pathways**
and **Orbits**. Search for a person, focus a group, follow recorded introductions,
return to a previous selection, pan, pinch or use zoom buttons, and drag nodes.
Display preferences persist locally. Reduced Motion is respected.

Normal launch shows an unconnected state. **Live People sync, contact-history
priorities and notifications are not connected yet.** The development preview
contains only explicitly labeled synthetic people and locations. Shared circle
membership does not imply friendship; residence and current presence are shown
separately, with missing facts marked Unknown.

## Development

Requires macOS, Xcode, XcodeGen, Swift, uv and just. No external Swift packages.
The app targets iOS 17 and macOS 14 or later.

```sh
just test                    # graph logic and call-reader fixtures
just check                   # Mac build
just run --preview-graph     # synthetic Mac explorer
just run                     # normal, unconnected launch
just test-ui                 # Mac UI tests
CIRCLE_DESTINATION='platform=iOS Simulator,name=iPhone 17' just test-ui
```

`project.yml` generates `Circle.xcodeproj`; open the generated project for
interactive development. `CIRCLE_DERIVED_DATA` overrides the build cache,
which defaults to `~/Library/Developer/Xcode/DerivedData/Circle`.
`--reset-explorer-preferences` resets only preview display preferences.
`--reduce-motion` disables preview animation for deterministic interaction tests.

The development bundle ID is `com.example.circle`. These commands build local
development artifacts; there is no release, signing enrollment or deployment
workflow. XCUITest may request the Mac user's approval to enable UI Automation.
An installed app will require supported service enrollment on each replacement
device; no service credential or iCloud sync is bundled in this milestone.

## Call history utility

An existing read-only macOS SQLite utility is available via `just calls`.
See [its usage and Full Disk Access requirements](scripts/README.md).
Its output contains private contact metadata and must stay outside git.

## Verification

Pure Swift tests cover relationship direction, overlapping groups, unknown
locations, focus restoration, cyclic/disconnected graphs, 1,500-person layouts,
validated preferences and camera bounds. UI tests cover normal/preview launch,
search, layouts, back navigation, city modes, preference restoration and gestures.
