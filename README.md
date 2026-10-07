# Circle

A native iOS and macOS app for exploring your people and staying in touch.

The current native explorer has three layouts: **Constellation**, **Pathways**
and **Orbits**. Search for a person, focus a group, follow recorded introductions,
return to a previous selection, pan, pinch or use zoom buttons, and drag nodes.
Display preferences persist locally. Reduced Motion is respected. Track people
locally for the reach-out list, set separate contact and hangout cadences,
priority, qualifying interactions, reminder preferences and snooze. Unknown
history stays explicit. Preview preferences are isolated from connected data.

Normal launch offers a read-only People connection through browser-approved
Life Data enrollment. A complete refresh replaces the graph; failed refreshes
preserve its private offline copy. **Contact-history priorities, current
presence, photos and notification delivery are not connected yet.** The development preview
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
just run                     # normal connection screen
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
Secure enrollment needs a correctly signed build and the device's unlocked
Keychain. Replacement devices enroll independently; credentials are never
exported or recovered from another app. No iCloud sync is bundled.

## Connect People

Enter your Life Data service's HTTPS origin and choose **Connect to People**.
Open the approval link and verify its code and read-only grants. Circle keeps
its generated device credential in the native Keychain. The operator configures
`circle-reader`; customers never enter table names or an operator token.

The service-owned `circle.reader` configuration binds the logical people,
relations and locations fields documented in `CirclePeopleBindings`. Its exact
16 column grants cover identity, display name, circles, directed relationships,
residence claims and tombstones. It grants no writes, file reads, messages,
streams, schema or replica synchronization. Circle checks the canonical Life
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

## Call history utility

The read-only macOS SQLite utility is available via `just calls` and as an
installable `circle-calls` package (`nix build .#circle-calls`).
See [its usage and Full Disk Access requirements](scripts/README.md).
Its output contains private contact metadata and must stay outside git.

## Verification

Pure Swift tests cover contact qualification, calendar cadence, incomplete
history, retractions, preference isolation, relationship direction, overlapping groups, unknown
locations, focus restoration, cyclic/disconnected graphs, 1,500-person layouts,
validated preferences and camera bounds. UI tests cover normal/preview launch,
search, layouts, back navigation, city modes, preference restoration, tracking,
reach-out settings and gestures on macOS and iOS.
