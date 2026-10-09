import Foundation

public enum StorageProducerPackage: String, CaseIterable, Codable, Sendable {
    case app01 = "APP-01", app02 = "APP-02", app02A = "APP-02A", app03A = "APP-03A"
    case app03B = "APP-03B", app04 = "APP-04", app05 = "APP-05", app06 = "APP-06"
    case app07 = "APP-07", app08 = "APP-08", app09 = "APP-09", app10 = "APP-10"
    case app11 = "APP-11", app12 = "APP-12", app13 = "APP-13", app14 = "APP-14"
    case app15 = "APP-15", app16 = "APP-16"
    case hlt01 = "HLT-01", hlt02 = "HLT-02", hlt03 = "HLT-03"
    case ntf01 = "NTF-01", ntf02 = "NTF-02"
    case sfc01 = "SFC-01", sfc02 = "SFC-02", sfc03 = "SFC-03", sfc04 = "SFC-04", sfc05 = "SFC-05"
    case ai01 = "AI-01", ai02 = "AI-02"
}

public enum StorageClosureSurface: String, CaseIterable, Codable, Hashable, Sendable {
    case sqlite, file, appGroup, watchConnectivity, keychain, notification, liveActivity, ledger, healthKitSamples, none
}

public struct StorageInventoryEntry: Equatable, Codable, Sendable {
    public let producer: StorageProducerPackage
    public let surfaces: Set<StorageClosureSurface>
    public let owner: String
    public let dayScoped: Bool
    public init(producer: StorageProducerPackage, surfaces: Set<StorageClosureSurface>,
                owner: String, dayScoped: Bool = false) {
        self.producer = producer; self.surfaces = surfaces; self.owner = owner; self.dayScoped = dayScoped
    }
}

/// Executable counterpart of the STO-05 inventory handoff. The explicit checklist dependency
/// list and its reconciled narrative both contain 30 producers; omissions are a test failure.
public enum StorageClosureInventory {
    public static let checklistNarrativeCount = 30
    public static let entries: [StorageInventoryEntry] = [
        .init(producer: .app01, surfaces: [.sqlite], owner: "OnboardingKit"),
        .init(producer: .app02, surfaces: [.sqlite], owner: "DeviceCenterKit"),
        .init(producer: .app02A, surfaces: [.sqlite], owner: "ProfileKit"),
        .init(producer: .app03A, surfaces: [.sqlite], owner: "TodayKit", dayScoped: true),
        .init(producer: .app03B, surfaces: [.sqlite], owner: "CoachKit", dayScoped: true),
        .init(producer: .app04, surfaces: [.sqlite], owner: "SleepKit", dayScoped: true),
        .init(producer: .app05, surfaces: [.sqlite], owner: "HeartKit", dayScoped: true),
        .init(producer: .app06, surfaces: [.sqlite], owner: "BodyKit", dayScoped: true),
        .init(producer: .app07, surfaces: [.sqlite], owner: "WorkoutKit", dayScoped: true),
        .init(producer: .app08, surfaces: [.sqlite, .file], owner: "RouteKit", dayScoped: true),
        .init(producer: .app09, surfaces: [.sqlite], owner: "JournalKit", dayScoped: true),
        .init(producer: .app10, surfaces: [.sqlite, .notification], owner: "CycleKit", dayScoped: true),
        .init(producer: .app11, surfaces: [.sqlite], owner: "RecordsKit", dayScoped: true),
        .init(producer: .app12, surfaces: [.sqlite], owner: "StressKit", dayScoped: true),
        .init(producer: .app13, surfaces: [.sqlite], owner: "SettingsKit", dayScoped: true),
        .init(producer: .app14, surfaces: [.sqlite], owner: "CoachKit", dayScoped: true),
        .init(producer: .app15, surfaces: [.sqlite], owner: "SettingsKit"),
        .init(producer: .app16, surfaces: [.sqlite, .file], owner: "DataKit", dayScoped: true),
        .init(producer: .hlt01, surfaces: [.sqlite, .ledger, .healthKitSamples], owner: "HealthKitBridge"),
        .init(producer: .hlt02, surfaces: [.ledger, .healthKitSamples], owner: "HealthKitBridge"),
        .init(producer: .hlt03, surfaces: [.ledger, .healthKitSamples], owner: "HealthKitBridge"),
        .init(producer: .ntf01, surfaces: [.notification, .ledger], owner: "NotificationKit"),
        .init(producer: .ntf02, surfaces: [.notification, .ledger], owner: "NotificationKit"),
        .init(producer: .sfc01, surfaces: [.appGroup], owner: "SharedSurfaceKit"),
        .init(producer: .sfc02, surfaces: [.appGroup], owner: "LooprWidgets"),
        .init(producer: .sfc03, surfaces: [.appGroup, .liveActivity], owner: "LooprLiveActivities"),
        .init(producer: .sfc04, surfaces: [.none], owner: "LooprAppIntents"),
        .init(producer: .sfc05, surfaces: [.appGroup, .watchConnectivity], owner: "LooprWatch"),
        .init(producer: .ai01, surfaces: [.keychain], owner: "AIKit"),
        .init(producer: .ai02, surfaces: [.ledger], owner: "AIKit")
    ]
}

public protocol StorageDeletionParticipant: Sendable {
    var identifier: String { get }
    var surfaces: Set<StorageClosureSurface> { get }
    func itemCount() async throws -> Int
    func deleteAll() async throws
}

public struct StorageDeletionReport: Equatable, Sendable {
    public let remainingByParticipant: [String: Int]
    public var isComplete: Bool { remainingByParticipant.values.allSatisfy { $0 == 0 } }
}

public enum StorageClosureError: Error, Equatable, Sendable {
    case incompleteDeletion([String: Int])
    case credentialShapedExport
}

/// Coordinates SQLite plus every registered external owner. HealthKit is intentionally excluded:
/// app-owned HealthKit sample deletion must be invoked through a separate confirmed action.
public actor StorageFullDeletionCoordinator {
    private let database: StorageDatabase
    private let participants: [any StorageDeletionParticipant]
    public init(database: StorageDatabase, participants: [any StorageDeletionParticipant]) {
        self.database = database; self.participants = participants
    }

    public func deleteLocalAccount() async throws -> StorageDeletionReport {
        try database.deleteAllAccountData()
        for participant in participants where !participant.surfaces.contains(.healthKitSamples) {
            try await participant.deleteAll()
        }
        var remaining: [String: Int] = [:]
        for participant in participants where !participant.surfaces.contains(.healthKitSamples) {
            remaining[participant.identifier] = try await participant.itemCount()
        }
        let report = StorageDeletionReport(remainingByParticipant: remaining)
        guard report.isComplete else { throw StorageClosureError.incompleteDeletion(remaining) }
        return report
    }
}

public enum StorageSecretScanner {
    public static func validate(_ values: [Data]) throws {
        let forbidden = ["bearer ", "api_key", "apikey", "access_token", "secret_key", "sk-"]
        for value in values {
            let text = String(decoding: value, as: UTF8.self).lowercased()
            if forbidden.contains(where: text.contains) { throw StorageClosureError.credentialShapedExport }
        }
    }
}

public struct StorageExternalArchive: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let payloads: [String: Data]
    public init(payloads: [String: Data]) throws {
        try StorageSecretScanner.validate(Array(payloads.values))
        self.schemaVersion = Self.currentSchemaVersion
        self.payloads = payloads
    }
}
