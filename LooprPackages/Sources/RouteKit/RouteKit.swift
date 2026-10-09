import Foundation

/// Route recording is intentionally fail-closed.  This is the exact DEC-03
/// eligibility list; an activity outside it never starts location services.
public enum RouteActivity: String, CaseIterable, Codable, Sendable {
    case run, cycle, walk
    public var isEligible: Bool { true }
}

public enum RoutePermission: String, Codable, Sendable {
    case notRequested, denied, authorized
}

public enum LocationGateError: Error, Equatable, Sendable {
    case permissionDenied
    case unavailable
    case interrupted
}

/// Events are deliberately semantic.  The Core Location adapter owns all
/// platform details and reports only a fail-closed interruption boundary to
/// RouteKit; RouteKit never invents coordinates or permission state.
public enum LocationGateEvent: Equatable, Sendable {
    case interruptionBegan
    case interruptionEnded
    case permissionRevoked
}

public enum RouteRecorderState: String, Codable, Sendable {
    case idle, recording, suspended, permissionDenied, ineligible
}

public enum RouteError: Error, Equatable, Sendable {
    case noActiveEligibleWorkout
    case permissionDenied
    case locationUnavailable
    case locationInterrupted
    case malformedPoint
    case missingRoute
    case routeAlreadyCompleted
}

public struct RoutePoint: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracy: Double
    public let altitude: Double?
    public let speedMetersPerSecond: Double?

    public init(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        altitude: Double? = nil,
        speedMetersPerSecond: Double? = nil
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.altitude = altitude
        self.speedMetersPerSecond = speedMetersPerSecond
    }

    public var isFinite: Bool {
        latitude.isFinite && longitude.isFinite && horizontalAccuracy.isFinite &&
            latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
    }
}

public struct RouteFilterConfiguration: Sendable, Equatable {
    public var maximumHorizontalAccuracy: Double
    public var maximumJumpMeters: Double
    public var maximumSpeedMetersPerSecond: Double

    public init(
        maximumHorizontalAccuracy: Double = 100,
        maximumJumpMeters: Double = 500,
        maximumSpeedMetersPerSecond: Double = 25
    ) {
        self.maximumHorizontalAccuracy = maximumHorizontalAccuracy
        self.maximumJumpMeters = maximumJumpMeters
        self.maximumSpeedMetersPerSecond = maximumSpeedMetersPerSecond
    }
}

public struct RouteFilter: Sendable {
    public let configuration: RouteFilterConfiguration
    public init(configuration: RouteFilterConfiguration = .init()) { self.configuration = configuration }

    public func accepts(_ point: RoutePoint, after previous: RoutePoint?) -> Bool {
        guard point.isFinite,
              point.horizontalAccuracy >= 0,
              point.horizontalAccuracy <= configuration.maximumHorizontalAccuracy else { return false }
        if let speed = point.speedMetersPerSecond, (!speed.isFinite || speed < 0 || speed > configuration.maximumSpeedMetersPerSecond) { return false }
        guard let previous else { return true }
        guard point.timestamp >= previous.timestamp else { return false }
        // A resumed CLLocation stream can replay its last sample.  Equal
        // timestamp/coordinate pairs are not a new location and must not
        // become duplicate route points.
        if point.timestamp == previous.timestamp,
           point.latitude == previous.latitude,
           point.longitude == previous.longitude { return false }
        let jump = RouteMath.distanceMeters(from: previous, to: point)
        return jump <= configuration.maximumJumpMeters
    }
}

public struct RouteSegment: Codable, Equatable, Sendable {
    public let points: [RoutePoint]
    public let zone: Int?
    public let startsAfterGap: Bool
    public init(points: [RoutePoint], zone: Int? = nil, startsAfterGap: Bool = false) {
        self.points = points; self.zone = zone; self.startsAfterGap = startsAfterGap
    }
}

public struct RouteSplit: Codable, Equatable, Sendable {
    public let index: Int
    public let distanceMeters: Double
    public let duration: TimeInterval
    public let zone: Int?
    public init(index: Int, distanceMeters: Double, duration: TimeInterval, zone: Int? = nil) {
        self.index = index; self.distanceMeters = distanceMeters; self.duration = duration; self.zone = zone
    }
}

public struct RouteRecord: Codable, Equatable, Sendable {
    public let workoutID: String
    public let activity: RouteActivity
    public var points: [RoutePoint]
    public var segments: [RouteSegment]
    public var bufferedWrites: Int
    public var completed: Bool
    /// Point indices at which a resumed GPS stream begins.  Distance and
    /// split calculations never bridge these breaks.
    public var gapStartIndices: [Int]

    public init(workoutID: String, activity: RouteActivity, points: [RoutePoint] = [], segments: [RouteSegment] = [], bufferedWrites: Int = 0, completed: Bool = false, gapStartIndices: [Int] = []) {
        self.workoutID = workoutID; self.activity = activity; self.points = points; self.segments = segments; self.bufferedWrites = bufferedWrites; self.completed = completed; self.gapStartIndices = gapStartIndices
    }
}

public struct RouteExportRequest: Codable, Equatable, Sendable {
    public let includeLocation: Bool
    public init(includeLocation: Bool = false) { self.includeLocation = includeLocation }
}

public struct RouteExportPayload: Codable, Equatable, Sendable {
    public let workoutID: String
    public let activity: RouteActivity
    public let distanceMeters: Double?
    public let duration: TimeInterval?
    public let includesLocation: Bool
    public let points: [RoutePoint]

    public init(
        workoutID: String,
        activity: RouteActivity,
        distanceMeters: Double?,
        duration: TimeInterval?,
        includesLocation: Bool,
        points: [RoutePoint]
    ) {
        self.workoutID = workoutID
        self.activity = activity
        self.distanceMeters = distanceMeters
        self.duration = duration
        self.includesLocation = includesLocation
        self.points = points
    }
}

public protocol RouteExporter: Sendable {
    func export(route: RouteRecord, request: RouteExportRequest) async throws -> RouteExportPayload
}

/// Pure local exporter used by package-owned previews and deterministic tests.
/// It never sends data and includes coordinates only after an explicit opt-in.
public struct LocalRouteExporter: RouteExporter {
    public init() {}

    public func export(route: RouteRecord, request: RouteExportRequest) async throws -> RouteExportPayload {
        RouteExportPayload(
            workoutID: route.workoutID,
            activity: route.activity,
            distanceMeters: route.points.count > 1 ? RouteMath.distanceMeters(route: route) : nil,
            duration: RouteMath.duration(route: route),
            includesLocation: request.includeLocation,
            points: request.includeLocation ? route.points : []
        )
    }
}

public protocol RouteStore: Sendable {
    func route(workoutID: String) async throws -> RouteRecord?
    func all() async throws -> [RouteRecord]
    func save(_ route: RouteRecord) async throws
    func delete(workoutID: String) async throws
    func count() async throws -> Int
    func deleteAll() async throws
}

public actor InMemoryRouteStore: RouteStore {
    private var rows: [String: RouteRecord] = [:]
    public init() {}
    public func route(workoutID: String) -> RouteRecord? { rows[workoutID] }
    public func all() -> [RouteRecord] { rows.values.sorted { $0.workoutID < $1.workoutID } }
    public func save(_ route: RouteRecord) { rows[route.workoutID] = route }
    public func delete(workoutID: String) { rows.removeValue(forKey: workoutID) }
    public func count() -> Int { rows.count }
    public func deleteAll() { rows.removeAll(keepingCapacity: true) }
}

public protocol LocationStartGate: Sendable {
    func start() async throws
    func stop() async
    func events() -> AsyncStream<LocationGateEvent>
}

public extension LocationStartGate {
    func events() -> AsyncStream<LocationGateEvent> { AsyncStream { $0.finish() } }
}

public struct NoopLocationStartGate: LocationStartGate {
    public init() {}
    /// The default is intentionally unavailable.  A production app must inject
    /// its permission-aware Core Location adapter rather than silently claiming
    /// that a route is being recorded.
    public func start() async throws { throw LocationGateError.unavailable }
    public func stop() async {}
}

public typealias RouteParentFinalizer = @Sendable (String) async -> Void

/// Owns the eligible-active-workout gate, filtering, buffering, and recovery.
/// A route is never reconstructed after the workout ended.
public actor RouteRecorder {
    public let store: any RouteStore
    private let filter: RouteFilter
    private let location: any LocationStartGate
    private let parentFinalizer: RouteParentFinalizer
    private var route: RouteRecord?
    private var permission: RoutePermission = .notRequested
    private var state: RouteRecorderState = .idle
    private var pendingGap = false
    private var permissionFinalized = false
    private var interruptionTask: Task<Void, Never>?

    public init(store: any RouteStore = InMemoryRouteStore(), filter: RouteFilter = .init(), location: any LocationStartGate = NoopLocationStartGate(), parentFinalizer: @escaping RouteParentFinalizer = { _ in }) {
        self.store = store; self.filter = filter; self.location = location; self.parentFinalizer = parentFinalizer
    }

    public func currentState() -> RouteRecorderState { state }
    public func currentRoute() -> RouteRecord? { route }
    public func setPermission(_ value: RoutePermission) { permission = value; if value == .denied { state = .permissionDenied } }

    /// Lets an app adapter forward a lifecycle event directly when it does not
    /// expose an `events()` stream.  The same handler is used by the injected
    /// stream monitor, keeping interruption semantics deterministic.
    public func handle(_ event: LocationGateEvent) async {
        switch event {
        case .interruptionBegan:
            guard route != nil else { return }
            pendingGap = true
            state = .suspended
            await location.stop()
        case .interruptionEnded:
            guard route != nil, state == .suspended else { return }
            try? await resume()
        case .permissionRevoked:
            guard route != nil else { return }
            try? await denyPermissionAndFinalizeParent()
        }
    }

    /// Marks a location-stream interruption without manufacturing a point at
    /// the gap boundary.  The next accepted point starts a new polyline.
    public func markGPSUnavailable() async throws {
        guard route != nil else { throw RouteError.noActiveEligibleWorkout }
        pendingGap = true
        state = .suspended
        await location.stop()
    }

    /// Permission denial ends the parent workout through its typed finalizer;
    /// this recorder only persists the route tail and never owns the workout.
    public func denyPermissionAndFinalizeParent() async throws {
        guard let route else { throw RouteError.noActiveEligibleWorkout }
        permission = .denied
        state = .permissionDenied
        pendingGap = true
        await location.stop()
        guard !permissionFinalized else { return }
        permissionFinalized = true
        await parentFinalizer(route.workoutID)
    }

    @discardableResult
    public func start(workoutID: String, activity: RouteActivity?, permission: RoutePermission? = nil) async throws -> RouteRecord {
        if let permission { self.permission = permission }
        guard let activity else { state = .ineligible; throw RouteError.noActiveEligibleWorkout }
        guard !workoutID.isEmpty else { state = .ineligible; throw RouteError.noActiveEligibleWorkout }
        // `.notRequested` means Core Location has not been asked yet. Failing
        // here would kill the first recording before the system prompt could
        // appear, so only a known denial fails fast and the location gate
        // decides the rest.
        guard self.permission != .denied else { state = .permissionDenied; throw RouteError.permissionDenied }
        let existing = try await store.route(workoutID: workoutID)
        if existing?.completed == true { state = .idle; throw RouteError.routeAlreadyCompleted }
        let next = existing ?? RouteRecord(workoutID: workoutID, activity: activity)
        route = next; pendingGap = existing != nil && !next.points.isEmpty; permissionFinalized = false; state = .recording
        do {
            try await location.start()
        } catch let error as LocationGateError {
            switch error {
            case .permissionDenied:
                state = .permissionDenied
                throw RouteError.permissionDenied
            case .interrupted:
                state = .suspended
                pendingGap = true
                throw RouteError.locationInterrupted
            case .unavailable:
                state = .suspended
                pendingGap = true
                throw RouteError.locationUnavailable
            }
        } catch {
            state = .suspended
            pendingGap = true
            throw RouteError.locationUnavailable
        }
        startEventMonitor()
        return next
    }

    public func append(_ point: RoutePoint, zone: Int? = nil) async throws -> Bool {
        guard var route else { throw RouteError.noActiveEligibleWorkout }
        guard state == .recording else { throw RouteError.noActiveEligibleWorkout }
        let previous = route.points.last
        guard filter.accepts(point, after: previous) else { return false }
        let startsAfterGap = pendingGap && !route.points.isEmpty
        if startsAfterGap { route.gapStartIndices.append(route.points.count) }
        route.points.append(point)
        if let zone {
            if !startsAfterGap, route.segments.last?.zone == zone {
                let existing = route.segments.removeLast()
                route.segments.append(RouteSegment(points: existing.points + [point], zone: zone, startsAfterGap: existing.startsAfterGap))
            } else {
                route.segments.append(RouteSegment(points: [point], zone: zone, startsAfterGap: startsAfterGap))
            }
        }
        pendingGap = false
        route.bufferedWrites += 1
        try await store.save(route)
        self.route = route
        return true
    }

    /// Flush is an explicit durability boundary, useful before suspension.
    public func flush() async throws -> RouteRecord {
        guard let route else { throw RouteError.noActiveEligibleWorkout }
        try await store.save(route)
        return route
    }

    public func suspend() async throws {
        guard route != nil, state == .recording else { throw RouteError.noActiveEligibleWorkout }
        pendingGap = true
        _ = try await flush(); state = .suspended; await location.stop()
    }

    public func resume() async throws {
        guard route != nil, state == .suspended else { throw RouteError.noActiveEligibleWorkout }
        guard permission == .authorized else { state = .permissionDenied; throw RouteError.permissionDenied }
        do {
            try await location.start()
            state = .recording
            startEventMonitor()
        } catch let error as LocationGateError {
            switch error {
            case .permissionDenied:
                state = .permissionDenied
                throw RouteError.permissionDenied
            case .interrupted:
                state = .suspended
                throw RouteError.locationInterrupted
            case .unavailable:
                state = .suspended
                throw RouteError.locationUnavailable
            }
        } catch {
            state = .suspended
            throw RouteError.locationUnavailable
        }
    }

    @discardableResult
    public func finish() async throws -> RouteRecord {
        guard var route else { throw RouteError.noActiveEligibleWorkout }
        _ = try await flush(); route.completed = true; try await store.save(route); self.route = route
        state = .idle; stopEventMonitor(); await location.stop(); return route
    }

    public func recover(workoutID: String) async throws -> RouteRecord {
        guard let restored = try await store.route(workoutID: workoutID) else { throw RouteError.missingRoute }
        route = restored; pendingGap = !restored.completed && !restored.points.isEmpty; state = restored.completed ? .idle : .suspended
        return restored
    }

    @discardableResult
    public func delete(workoutID: String) async throws -> RouteDeletionReceipt {
        let existed = try await store.route(workoutID: workoutID) != nil || route?.workoutID == workoutID
        try await store.delete(workoutID: workoutID)
        if route?.workoutID == workoutID { route = nil; pendingGap = false; state = .idle; stopEventMonitor(); await location.stop() }
        return RouteDeletionReceipt(workoutID: workoutID, removed: existed)
    }

    public func export(workoutID: String, request: RouteExportRequest = .init(), exporter: any RouteExporter = LocalRouteExporter()) async throws -> RouteExportPayload {
        guard let route = try await store.route(workoutID: workoutID) else { throw RouteError.missingRoute }
        return try await exporter.export(route: route, request: request)
    }

    private func startEventMonitor() {
        interruptionTask?.cancel()
        let stream = location.events()
        interruptionTask = Task { [self] in
            for await event in stream {
                await handle(event)
            }
        }
    }

    private func stopEventMonitor() {
        interruptionTask?.cancel()
        interruptionTask = nil
    }
}

public struct RouteDeletionReceipt: Equatable, Sendable {
    public let workoutID: String
    public let removed: Bool
    public init(workoutID: String, removed: Bool) { self.workoutID = workoutID; self.removed = removed }
}

public enum RouteMath {
    private static let earthRadius = 6_371_000.0
    public static func distanceMeters(from a: RoutePoint, to b: RoutePoint) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(p1) * cos(p2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    public static func splits(route: RouteRecord, everyMeters: Double = 1000) -> [RouteSplit] {
        guard everyMeters > 0, route.points.count > 1 else { return [] }
        var output: [RouteSplit] = []
        var distance = 0.0, next = everyMeters, segmentStart = route.points[0]
        for (index, pair) in zip(route.points.indices.dropFirst(), zip(route.points, route.points.dropFirst())) {
            if route.gapStartIndices.contains(index) {
                segmentStart = pair.1
                distance = 0
                next = everyMeters
                continue
            }
            distance += distanceMeters(from: pair.0, to: pair.1)
            if distance >= next {
                let duration = pair.1.timestamp.timeIntervalSince(segmentStart.timestamp)
                output.append(RouteSplit(index: index, distanceMeters: next, duration: max(0, duration), zone: zone(at: index, route: route)))
                next += everyMeters; segmentStart = pair.1
            }
        }
        return output
    }

    private static func zone(at index: Int, route: RouteRecord) -> Int? {
        guard route.points.indices.contains(index) else { return nil }
        let point = route.points[index]
        return route.segments.first(where: { $0.points.contains(point) })?.zone
    }

    public static func polylineSegments(route: RouteRecord) -> [[RoutePoint]] {
        guard !route.points.isEmpty else { return [] }
        let breaks = Set(route.gapStartIndices.filter { $0 > 0 && $0 < route.points.count })
        var output: [[RoutePoint]] = [[]]
        for (index, point) in route.points.enumerated() {
            if breaks.contains(index) { output.append([]) }
            output[output.count - 1].append(point)
        }
        return output.filter { !$0.isEmpty }
    }

    public static func distanceMeters(route: RouteRecord) -> Double {
        zip(route.points, route.points.dropFirst()).enumerated().reduce(0) { total, value in
            let (index, pair) = value
            return total + (route.gapStartIndices.contains(index + 1) ? 0 : distanceMeters(from: pair.0, to: pair.1))
        }
    }

    public static func duration(route: RouteRecord) -> TimeInterval? {
        guard route.points.count > 1, let first = route.points.first, let last = route.points.last else {
            return nil
        }
        return last.timestamp.timeIntervalSince(first.timestamp)
    }
}

/// Data contract consumed by the DSN-03 route primitive.  It keeps map
/// polylines, split markers, and zone segments derived from one route record.
public struct RoutePrimitiveData: Equatable, Sendable {
    public let polylines: [[RoutePoint]]
    public let splits: [RouteSplit]
    public let zoneSegments: [RouteSegment]
    public let accessibilitySummary: String

    public init(route: RouteRecord) {
        polylines = RouteMath.polylineSegments(route: route)
        splits = RouteMath.splits(route: route)
        zoneSegments = route.segments
        let distance = RouteMath.distanceMeters(route: route)
        let duration = RouteMath.duration(route: route) ?? 0
        accessibilitySummary = "Route, \(Int(distance.rounded())) meters, \(Int(max(0, duration).rounded())) seconds, \(splits.count) splits"
    }
}

public struct RouteShareCard: Equatable, Sendable {
    public let workoutID: String
    public let activity: RouteActivity
    public let distanceMeters: Double?
    public let duration: TimeInterval?
    public let includesRoute: Bool
    public let routePoints: [RoutePoint]

    public init(route: RouteRecord, includeRoute: Bool = false) {
        workoutID = route.workoutID; activity = route.activity
        distanceMeters = route.points.count > 1 ? RouteMath.distanceMeters(route: route) : nil
        duration = RouteMath.duration(route: route)
        includesRoute = includeRoute
        routePoints = includeRoute ? route.points : []
    }
}

public struct RouteScreenSnapshot: Equatable, Sendable {
    public enum State: String, CaseIterable, Sendable { case loading, noRecords, absent, measuredZero, partial, lowConfidence, settling, stale, disconnected, bluetoothOff, permissionDenied, unsupportedHardware, recoverableError, destructiveFailure, migrationFailure, ready }
    public let state: State
    public let summary: String
    public init(state: State, summary: String) { self.state = state; self.summary = summary }
}
