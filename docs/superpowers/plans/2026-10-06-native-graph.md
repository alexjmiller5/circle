# Native Graph Implementation Plan

> For agentic workers: use superpowers:executing-plans, task by task.

**Goal:** Implement and verify the approved native explorer on Mac and iPhone.
**Architecture:** Pure graph values, deterministic layouts and navigation state shared by SwiftUI views. No service credentials or personal data in this milestone.
**Tech stack:** Swift, Swift Testing, SwiftUI, XcodeGen.
**Spec:** ../specs/2026-10-06-native-graph-design.md

## Global constraints

Three approved layouts, stable canonical identity, accurate relation direction, explicit unknown locations, iOS and macOS. No invented friendships, alert defaults, live-data claims or new credentials.

## Review focus

Disconnected/cyclic graphs; overlapping circles; empty and missing identities; 1,500-person layout cost; narrow screens and gesture/accessibility conflicts.

### Task 1: Graph logic

Files: `nudge/nudge/Graph/Graph.swift`, `GraphTests/GraphTests.swift`, `Package.swift`.
Interfaces: `SocialGraph`, `ExplorerState`, `GraphPositions.make(graph:state:)` produce stable IDs and positions for views.

- [x] Write tests for canonical relation direction, no invented membership edges, unknown cities, focus history, stable layouts, disconnected input and 1,500 nodes.
- [x] Run `swift test`; verify missing graph API failure.
- [x] Implement the graph API and run `swift test` green.
- [x] Mutate introduction direction and navigation restoration; verify failures, restore and rerun.
- [x] Commit graph logic and tests.

### Task 2: Native explorer

Files: `nudge/nudge/ContentView.swift`, `GraphCanvas.swift`, `GraphDetails.swift`, `nudgeApp.swift`, `PreviewGraph.swift`, `project.yml`, `justfile`.
Consumes Task 1 graph/state/positions. Produces native controls and graph canvas with accessible person/group actions.

- [x] Add UI flow tests before views: normal launch has no mock data; explicit preview supports selection, layout change, Back/Back to me, search and location mode.
- [x] Implement native views, explicitly gated synthetic preview and empty launch.
- [x] Generate Circle iOS/macOS project; build and run relevant tests on both destinations.
- [x] Exercise real gestures and controls; capture narrow phone and Mac evidence, including reduced motion.
- [x] Update README/AGENTS with actual supported state and commands, run existing Python tests, review diff, commit and push.

Approval is already supplied for this milestone. Execute inline without reopening design approval. Any unsupported live-service or deployment step remains outside this plan.
