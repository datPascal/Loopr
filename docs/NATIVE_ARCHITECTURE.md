# Native iOS Architecture

## Goals

Loopr should be a native iOS 26+ application with a small, explicit set of ownership boundaries:

- one CoreBluetooth owner;
- one serialized database writer;
- one history-drain coordinator;
- structured and cancellable analytics work;
- feature-scoped SwiftUI state;
- local-first storage and integrations.

The generated `Item` SwiftData model and list screen are placeholders and should not shape the production architecture.

## Product Layout Rule

Loopr must preserve OpenStrap Edge's layout structure while replacing its Flutter presentation with a modern native iOS 26 experience. Structural parity is a product requirement, not a suggestion.

Preserve:

- the persistent five-destination shell in this order: Today, Sleep, Heart, Body, and Workouts;
- the navigation hierarchy, destination ownership, primary content grouping, and major section order within each destination;
- Today as the summary and launch surface for journal, profile/settings, recap, records, journey, stress, and canonical metric details;
- the shared metric-screen pattern for Sleep, Heart, and Body: current-day content, selectable time range/trend, then day-specific detail;
- Workouts as the training log and workout entry surface, including range selection, manual and detected sessions, live workout flow, and a persistent active-workout mini-player above the tab bar;
- pushed detail screens and native modal sheets rather than duplicating the same feature in multiple tabs;
- onboarding and pairing as gates before the main shell.

Modernize:

- visual styling, typography, spacing, materials, motion, charts, controls, and transitions using iOS 26 design conventions;
- platform behavior with native tab bars, navigation bars, sheets, menus, context actions, search, accessibility, and system feedback;
- responsive behavior for Dynamic Type, compact heights, supported orientations, and different iPhone sizes.

Structural parity does not require pixel-for-pixel reproduction of Flutter widgets or retention of OpenStrap's custom visual chrome. A destination, major section, or primary route may be removed, renamed, reordered, or relocated only through an explicit product decision recorded in the roadmap. During migration, the OpenStrap implementation is the reference when documentation and the running layout disagree.

## Proposed Layers

```text
SwiftUI features
    -> domain repositories and observable feature models
    -> Bluetooth / storage / analytics / HealthKit services
    -> CoreBluetooth, SQLite, HealthKit, BackgroundTasks
```

Suggested Swift package boundaries:

```text
DomainKit
ProtocolKit
StorageKit
BluetoothKit
AnalyticsKit
HealthKitBridge
WorkoutKit
SharedSurfaceKit
TestSupport
```

Application folders can then be organized by feature:

```text
App/
Features/Onboarding/
Features/Pairing/
Features/Today/
Features/Sleep/
Features/Heart/
Features/Body/
Features/LooprAge/
Features/Workouts/
Features/Settings/
Extensions/
```

The feature folders may improve internal ownership, but they must not silently change the user-facing OpenStrap layout hierarchy defined above.

## Dependency Rules

- `ProtocolKit` is pure Swift and has no Bluetooth, database, or UI dependency.
- `BluetoothKit` may depend on `ProtocolKit` and storage protocols, but not SwiftUI.
- `StorageKit` does not import CoreBluetooth or SwiftUI.
- `AnalyticsKit` receives immutable input snapshots and returns typed results.
- Features never issue SQL or construct protocol frames.
- Widgets and watch surfaces consume a small versioned snapshot, not the primary database.

## Core Types

The protocol layer should use typed byte readers and preserve unknown data:

```swift
struct Gen4Frame: Sendable {
    let paddedInner: Data
    let lengthCRCIsValid: Bool
    let payloadCRCIsValid: Bool
}

struct HistoryToken: Hashable, Sendable {
    let bytes: Data // exactly eight bytes
}

enum HistoricalRecord: Sendable {
    case r24(R24Record)
    case v25(V25Record)
    case unsupported(version: UInt8, raw: Data)
}
```

Metric absence and confidence must remain explicit:

```swift
struct Metric<Value: Codable & Sendable>: Codable, Sendable {
    let value: Value?
    let confidence: Double
    let tier: ConfidenceTier
    let inputsUsed: [String]
    let note: String?
}
```

Use `nil` for absence in domain and persistence payloads. Convert it to an em dash only in presentation.

## Bluetooth Ownership

Use a single `CBCentralManager` configured with a restoration identifier. It should be created on a dedicated serial queue and bridged into a `BluetoothSession` actor.

```text
CBCentralManagerDelegate / CBPeripheralDelegate
    -> immutable Sendable events
    -> BluetoothSession actor
    -> AsyncStream connection and measurement summaries
```

The actor owns:

- connection generation and intent;
- peripheral and characteristic readiness;
- one reassembler per inbound characteristic;
- command sequence allocation;
- one write-with-response at a time;
- history burst state and exact tokens;
- reconnect, clock, and backfill policy;
- high-rate stream consumers;
- timers scoped to the current session.

UI receives throttled summaries. It must not observe every IMU or RR packet directly.

## Storage Recommendation

Use SQLite as the primary store, preferably through GRDB.

SwiftData is not recommended for the sensor ledger because the system requires:

- high-volume one-second rows and RR beats;
- explicit conflict and replacement behavior;
- a transaction that acts as an on-wire ACK barrier;
- WAL, migrations, paging, import/export, and integrity checks;
- versioned daily result rows and SQL aggregation;
- stable backup compatibility.

Use a `DatabasePool` and expose one serialized write facade. The critical API should look conceptually like:

```swift
protocol HistoryBatchStore: Sendable {
    func commit(
        records: [StoredRecord],
        archived: [ArchivedRecord],
        boundary: HistoryCommitBoundary
    ) async throws -> DurableHistoryCommit
}
```

This method returns only after the full transaction succeeds. `DurableHistoryCommit.ackEligible` carries the exact committed token and is the only result that permits the history coordinator to send an ACK. `DurableHistoryCommit.completionTail` represents a tokenless durable tail and can never authorize an ACK.

SwiftData or `AppStorage` may still be used for small, non-critical presentation preferences, but there should not be two authorities for health data.

## Suggested Native Schema

Preserve the effective semantics rather than blindly copying every legacy Edge table:

- `decoded_second`: canonical second keyed by timestamp with original counter.
- `rr_beat`: beat rows with a real foreign key to the decoded second.
- `raw_archive`: never-pruned unsupported packets and decode reason.
- `sync_cursor`: exact trim token and high-water values.
- `sync_batch`: received, committed, ACKed, failed, and redelivered batch state.
- `sync_failure`: durable failure evidence and retry classification.
- `day_result`: `(day_id, algorithm_version)` result payload and status.
- `metric_series`: current scalar trend values.
- `baseline`: versioned longer-term state.
- `workout`, `route_point`, `sleep_override`, `journal_entry`.
- `health_export_ledger` and notification fire-once claims.

Store the timezone identifier and offset used to derive each day. This makes travel and historical labels auditable.

## Structured Concurrency

### UI

Use small `@MainActor @Observable` models for root routing and individual features. Avoid recreating Edge's monolithic `AppState`.

### Database

All writes pass through the database writer. Cross-process claims, such as notification deduplication, remain database-atomic because actors do not synchronize an app extension or another process.

### Analytics

Use a `DerivationScheduler` actor to coalesce work and prevent duplicate baseline mutations. CPU-heavy staging and spectral work should run off the main actor in bounded tasks and support cancellation.

### Background tasks

Each BG task owns one top-level `Task`. Its expiration handler cancels that task. A one-shot completion gate ensures `setTaskCompleted` is called once.

On expiration, priority is:

1. finish or roll back the current database transaction;
2. preserve synchronization cursor correctness;
3. stop BLE work safely;
4. defer analytics, HealthKit, and surface refreshes.

## Background Model

Use three complementary mechanisms:

- maintain a subscribed Bluetooth connection when iOS allows it;
- CoreBluetooth restoration for accessory-driven relaunch and reconnection;
- BGProcessing/BGAppRefresh as opportunistic maintenance windows.

Do not promise continuous or periodic background sync. The app should show the last successful sync time and a clear stale state.

AccessorySetupKit should be the user-facing provisioning path on iOS 26. Ensure its first-use ordering is tested on physical hardware before the central manager is activated for a new user.

## HealthKit

Create a `HealthImportActor` for anchored reads plus a serial `HealthExportActor`; give both durable cursors/ledgers.

- Request authorization from a user action.
- Read date of birth, `VO2max`, height, weight, body fat, and lean mass only when the user enables Loopr Age, preserving source metadata and explicit absence.
- Export only measurements with an honest HealthKit mapping.
- Write SDNN to HealthKit HRV, not RMSSD.
- Export completed workouts immediately from every finalization path.
- Keep replacement windows local-calendar and DST-safe.
- Attach source metadata explaining measured versus estimated values where possible.
- Do not export readiness, strain, stress, or uncalibrated optical/temperature channels as native quantities.
- Do not export Cardio Age or Loopr Age; HealthKit has no honest native quantity for either estimated age.

## Shared Surfaces

Publish a versioned `SurfaceSnapshot` to an App Group for widgets, App Intents, Live Activities, and a future read-only watch app.

The snapshot should include:

- schema version and generation date;
- source day and last sync date;
- explicit optional values for readiness, strain, sleep, HRV, and RHR;
- battery value and battery observation date;
- stale flags.

Do not store API bearer tokens in shared defaults and do not make widgets fetch private health summaries from a backend.

## SwiftUI Direction

SwiftUI is the primary presentation framework. Use UIKit through narrow `UIViewRepresentable`, `UIViewControllerRepresentable`, or hosting boundaries only when a required interaction, rendering workload, or Apple API is not adequately served by SwiftUI. UIKit must not become a parallel navigation or state architecture.

The visual language should feel native to iOS 26 without becoming a generic card dashboard or a Flutter reskin.

- Implement the OpenStrap-compatible five-area information architecture: Today, Sleep, Heart, Body, and Workouts, in the same order.
- Use a native SwiftUI tab shell and preserve each tab's navigation state. Do not recreate OpenStrap's custom floating navigation pill when the iOS 26 system tab presentation provides the intended hierarchy.
- Keep one canonical destination for each metric or workflow and route Today summaries into it.
- Make freshness and confidence visible near the metric, not hidden in an info screen.
- Treat absent, partial, low-confidence, stale, disconnected, and Bluetooth-off states separately.
- Prefer iOS 26 system materials, typography, controls, transitions, and interaction feedback; data legibility takes priority over decoration.
- Build reusable metric, chart, stage, zone, and status components with Dynamic Type and VoiceOver from the start.
- Use `NavigationStack` with typed routes and feature-local presentation state.
- Use UIKit-backed charts, collection layouts, visual effects, or system controllers only when profiling or API availability establishes a concrete need.
- Support dark mode, Reduce Motion, increased contrast, and large accessibility sizes.

Layout parity should be verified with a screen inventory and side-by-side navigation walkthrough against the pinned OpenStrap baseline. Visual acceptance should assess native iOS 26 quality separately from structural parity so modernization does not accidentally remove or relocate product behavior.

## Security and Privacy

- Keep health data local by default.
- Store secrets in Keychain, not SQLite or App Group defaults.
- Use data protection appropriate for health records.
- Make exports explicit and auditable.
- Keep telemetry off until informed consent.
- Never include health payloads in logs or crash metadata.
- Maintain non-affiliation and non-medical disclaimers.
