# AGENTS.md

Guidance for coding agents working in this repository.

## Project Overview

Nudge (working title for "Circle") is a macOS app that helps users maintain relationships by tracking communication history and suggesting when to reach out. Early-stage project — currently a scaffolded Xcode template with SwiftUI + SwiftData.

## Build & Test Commands

This is an Xcode project. All build/test commands use `xcodebuild` from the `nudge/` subdirectory (where the `.xcodeproj` lives):

```bash
# Build
xcodebuild -project nudge/nudge.xcodeproj -scheme nudge -configuration Debug build

# Run unit tests
xcodebuild -project nudge/nudge.xcodeproj -scheme nudge -configuration Debug test

# Run a single test
xcodebuild -project nudge/nudge.xcodeproj -scheme nudge -configuration Debug test -only-testing:nudgeTests/nudgeTests/testExample
```

Note: This environment is Linux (Raspberry Pi), so `xcodebuild` is not available here. The project must be built on macOS with Xcode 16.4+.

## Architecture

- **Language:** Swift 5, SwiftUI, SwiftData
- **Deployment target:** macOS 14.0+
- **Xcode project:** `nudge/nudge.xcodeproj`
- **Bundle ID:** `com.alexjmiller5.nudge`

### Key directories

- `nudge/nudge/` — App source (SwiftUI views, SwiftData models, entitlements)
- `nudge/nudgeTests/` — Unit tests (Swift Testing framework via `import Testing`)
- `nudge/nudgeUITests/` — UI tests (XCTest framework)

### Data layer

- **SwiftData** is the persistence framework. Models use `@Model` macro. The `ModelContainer` is configured in `nudgeApp.swift` and injected via `.modelContainer()`.
- The app has iCloud/CloudKit entitlements for future sync support.
- Call history data comes from the macOS SQLite database at `~/Library/Application Support/CallHistoryDB/CallHistory.storedata`. CSV exports of this data exist at the repo root (`test*.csv`) for development/analysis.

### Testing

- Unit tests use Swift Testing (`@Test`, `#expect`) — not XCTest.
- UI tests use XCTest (`XCUIApplication`).

## External Documentation

Feature ideas and project planning live in Notion (linked in README.md).

## Designs

Browser mockups and their screenshots live in `designs/` (`preview/explorer.html` is the approved three-layout explorer). The folder is git-ignored because it also holds raw Notion task snapshots.
