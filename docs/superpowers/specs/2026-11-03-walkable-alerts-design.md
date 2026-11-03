# Walking-distance alerts: implementation design

Status: design and synthetic test inputs only. No close-alert implementation,
route adapter, precise producer, enrollment or runtime activation is present.
The city-only alert remains the shipped behavior. Do not infer deployment or
end-to-end acceptance from these documents or fixtures.

## Intent and boundaries

Keep city arrival alerts and add a distinct, actionable physical-proximity
alert: a friend is about a 15-minute walk away, so consider meeting up.
Social closeness, circles, relationship score and graph filters do not decide
eligibility. Preserve the existing alert audience, registration audience,
privacy choices and old city behavior. Reach-out and hangout cadence are
separate; no last-seen definition or new notification preference is introduced.

## Current source inventory

- Graph/NearbyAlerts.swift parses city-grade findmy_ax checks. It has no
  coordinates, horizontal accuracy or sensor fix timestamp.
- Graph/NearbyVisits.swift persists one city visit per person/profile. Entry
  and departure each need two distinct fresh checks at least 300 seconds
  apart. Stale, duplicate, future, unknown and out-of-order evidence cannot
  establish a visit or departure. Missing data is not departure.
- push/Sources/Evaluator.swift pages the city stream and reads a location
  stream tail. Its current self-location adapter reads lat/lon for reverse
  geocoding but does not validate tst or acc. Re-reading only the last friend
  page also means self-only movement needs an explicit cached-friend path.
- push/Main/main.swift evaluates every 120 seconds by default, renders city
  and hangout messages and broadcasts APNs to the existing registered devices.
  A CLI hide-names option controls push privacy. The native local reach-out
  reminder settings are a separate pipeline; do not silently assume that its
  quiet hours or opt-in rules already govern server push.
- PushState holds city-watch state and a cursor; state is written after sends.
  APNs has an injectable transport and synthetic request tests. The run loop
  currently lacks a persisted per-recipient pending-delivery outbox.
- The producer findmy-cli serializes source collection IDs/time and displayed
  age. Its detail geocoder resolves addresses to map points. Neither that
  geocoder nor city centers establish observed precise coordinates.
- There is no MKDirections/walking adapter in this checkout.

## Enabling evidence contract

Do not reinterpret friend_city_checks as precise observations. A separately
versioned precise-source contract must supply, for each endpoint:

1. Canonical person identity, stable producer/fix identity and explicit
   measured-coordinate provenance. Geocodes, residences and map centers fail.
2. Finite latitude/longitude in range and finite positive horizontal accuracy
   with known units and provenance. Accuracy absent or unknown fails closed.
3. Source observation time, or an honest source-age interval at collection,
   plus collection time and availability. Collection must not renew fix age.
   If only an interval exists, use its oldest possible observation for expiry.
4. Explicit paused/unavailable state and ordering identity. A replay keeps
   its identity; invalid newer evidence cannot reset last-notified state.

The user's OwnTracks adapter must validate its actual tst/acc/source shape,
not merely inherit the city-tail shortcut. Historical imported locations,
latest append time and unknown source type cannot become current fixes.
Read both endpoints through supported, scoped consumer interfaces. No new
stream, grant, schema, tracking schedule or credential is provisioned here.
The precise producer is a real outstanding dependency, not a reopening of
completed city collection or city alerts.

## Walking route contract and choices still requiring evidence

A route result names mode=walking, provider/version, request and completion
times, exact origin/destination fix identities and coordinates, and finite
positive travel time. Results for replaced endpoints are discarded. Nil,
throttling, timeout, no pedestrian route, nonwalking mode, invalid duration,
old cache entries and endpoint mismatch all mean unknown, never near/away.

MapKit MKDirections is an existing-platform candidate, not an enabled adapter.
Apple documents walking requests to Apple servers, request throttling, and
expectedTravelTime as an ideal-conditions estimate whose real time can vary.
Do not call it a guaranteed maximum. Sending precise friend endpoints to a
routing service is a privacy decision; review that data flow before activation.
Do not add a provider account, billing, new sharing arrangement or fallback.

The endpoint-accuracy policy, source/route expiry and uncertainty treatment
must be justified by measured precise-source cadence and routing evidence.
Proposed synthetic policy for the test fixtures ONLY: source age <=120s,
horizontal accuracy <=50m, route age <=60s; a route interval entirely <=900s
qualifies, entirely >900s establishes outside, a crossing interval is unknown.
The interval is not available from MKDirections by itself. Do not manufacture
it by dividing distance by walking speed or adding an arbitrary seconds buffer.
A provider-backed uncertainty model or an explicitly reviewed nominal-ETA
policy is required before real use; until then the close tier is suppressed.
These fixture numbers are builder proposals, not production defaults or an
assertion that the current producer meets them.

## Proposed implementation seam and state transitions

Add portable endpoint/route evidence values and a pure close-watch evaluator
in CircleGraph, with injected clock and route provider in CirclePush. Keep
city parsing and NearbyWatch unchanged. No adapter is enabled until precision
and route-policy prerequisites are satisfied. Reevaluate a pair when either
endpoint changes; retain only the latest usable friend evidence per profile,
bounded by expiry. A replayed friend page is not a new fix.

Reuse the existing proven 300-second two-check entry/departure dwell for the
close tier, with explicit normalized near/away/unknown evidence. Both checks
must remain valid when evaluated. Distinct pairs with fresh source updates
qualify; duplicate fix pairs or repeated routes do not advance dwell. Reject
out-of-order endpoint versions, future timestamps and same-time conflicts.
A gap of unknown evidence clears pending dwell but never proves departure.
Threshold-crossing uncertainty clears pending dwell, preserving confirmed
inside state. Re-entry requires confirmed outside then confirmed inside.
No per-week cooldown or elapsed-since-seen definition is added.

Keep independent confirmed city and close visit state plus a small durable
notification ledger. When both arrivals confirm in the same evaluation,
choose the close alert and mark the city event covered. When city was already
notified and close confirms later, emit one meaningful escalation. Close to
city downgrade alone does not send another city alert. Unknown route data
must never delay or suppress an independently valid city alert. A confirmed
close departure/re-entry can notify again inside the same ongoing city visit.

Resolve same-evaluation precedence before network sends. Persist pending
notification identity and per-device acknowledgment before advancing sent
state; retry only unacknowledged recipients with a stable logical event key.
APNs and crashes cannot guarantee exactly-once banner delivery. Use a stable
collapse identifier for the same pending logical event where supported, and
expire close-alert pending work with its evidence so a delayed retry cannot
announce stale proximity. Existing city state must decode unchanged; optional
new fields default to no close evidence, not an alert replay. This delivery
work stays bounded to this feature rather than changing unrelated reminders.

Render an estimate, for example a title indicating a friend is a short walk
away and a body inviting a meetup with the supported estimated minutes.
Do not promise the friend is available or say they can definitely be reached
within 15 minutes. Hidden-name mode excludes names, coordinates, places and
route details. Do not log raw endpoints, routes or people names.

## Requirements and verification

- The system shall preserve the city tier when precise evidence is absent.
- When both endpoints and a matching pedestrian route satisfy the approved
  freshness/accuracy/uncertainty policy and dwell, the system shall offer one
  close-tier event per confirmed visit, independent of graph/circle filters.
- While routing or source quality is unknown, the system shall suppress the
  close assertion without treating the friend as having left.
- When either endpoint changes, the system shall reject stale asynchronous
  route responses and reevaluate against the current endpoint pair.
- When city and close confirm together, the system shall emit at most one
  logical event; a later close confirmation may escalate a prior city event.
- The system shall preserve privacy rendering and registration audience.

walkable-alert-cases.json is a synthetic behavior test plan, not a passing
suite. Expected outcomes are literal and independently hand-derived. Add
Swift Testing cases against the real seam before product code; observe red,
then green and deliberate mutations. Existing NearbyVisitTests,
NearbyAlertTests and PushTests remain regression controls. Native compilation,
fixture-driven evaluator tests, injected APNs fanout/restart/failure tests,
UI/privacy checks and admitted installed end-to-end acceptance are required.
No Swift, Xcode, simulator, Nix, live tracking or live push has run for this
preparation. A full feature completion claim requires real precise evidence,
a defensible walking route and the end-to-end notification outcome.

## Primary routing references

- https://developer.apple.com/documentation/mapkit/mkdirections
- https://developer.apple.com/documentation/mapkit/mkroute/expectedtraveltime
- https://developer.apple.com/documentation/mapkit/mkdirectionstransporttype/walking
