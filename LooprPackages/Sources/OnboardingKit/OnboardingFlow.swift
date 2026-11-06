import Foundation
import DomainKit
import ProfileKit

/// The persisted onboarding sequence. Raw values are stored in the products
/// database, so existing cases keep their names; new stages were inserted
/// between them in 2026-09 without changing any existing raw value.
/// `whoopHandover` joined on 2026-09-29, between welcome and pairing mode.
public enum OnboardingStage: String, Codable, CaseIterable, Sendable {
    case launching
    case welcomeDisclosures
    case whoopHandover
    case prepareBand
    case pairing
    case profileSetup
    case appleHealth
    case notifications
    case sleepGoal
    case finish
    case mainShell

    /// Since the UX simplification (2026-11-01) the visible path skips three stored stages: the WHOOP app step folded
    /// into pairing mode, notifications are asked when there is something to send, and sleep need keeps its 8 hour
    /// default and lives in Settings. A snapshot saved on one of those stages still moves on from it.
    public var next: OnboardingStage? {
        switch self {
        case .launching: .welcomeDisclosures
        case .welcomeDisclosures: .prepareBand
        case .whoopHandover: .prepareBand
        case .prepareBand: .pairing
        case .pairing: .profileSetup
        case .profileSetup: .appleHealth
        case .appleHealth: .finish
        case .notifications: .finish
        case .sleepGoal: .finish
        case .finish: .mainShell
        case .mainShell: nil
        }
    }

    /// Where Back leads. Nil where there is nothing to go back to: before
    /// the first visible step, and after onboarding has finished.
    public var previous: OnboardingStage? {
        switch self {
        case .launching, .welcomeDisclosures, .mainShell: nil
        case .whoopHandover: .welcomeDisclosures
        case .prepareBand: .welcomeDisclosures
        case .pairing: .prepareBand
        case .profileSetup: .pairing
        case .appleHealth: .profileSetup
        case .notifications: .appleHealth
        case .sleepGoal: .appleHealth
        case .finish: .appleHealth
        }
    }

    /// Where Next leads on a path. Without a band, Welcome goes straight to
    /// About you; every other step leads where it does on the band path.
    public func next(on path: OnboardingPath) -> OnboardingStage? {
        if path == .noBand, self == .welcomeDisclosures { return .profileSetup }
        return next
    }

    /// Where Back leads on a path. Without a band, About you goes back to
    /// Welcome, past the band steps the person never saw.
    public func previous(on path: OnboardingPath) -> OnboardingStage? {
        if path == .noBand, self == .profileSetup { return .welcomeDisclosures }
        return previous
    }

    /// The steps a person with a band sees, in order. `launching` and
    /// `mainShell` are gate states, not steps.
    public static let visibleSteps: [OnboardingStage] = OnboardingPath.band.steps

    /// The band steps. From any of them the person may set the band up later.
    public static let bandSteps: Set<OnboardingStage> = [.whoopHandover, .prepareBand, .pairing]

    /// Steps the person may leave blank or skip without losing anything.
    public var isOptional: Bool {
        switch self {
        case .profileSetup, .appleHealth, .notifications, .sleepGoal: true
        default: false
        }
    }

    /// One-based position in `visibleSteps`, or nil for gate states.
    public var stepNumber: Int? { stepNumber(on: .band) }

    /// One-based position on the path's steps, or nil for gate states and
    /// for steps the path skips.
    public func stepNumber(on path: OnboardingPath) -> Int? {
        path.steps.firstIndex(of: self).map { $0 + 1 }
    }

    public static var stepCount: Int { visibleSteps.count }

    /// The permission a stage primes, if any.
    public var permission: OnboardingPermission? {
        switch self {
        case .appleHealth: .appleHealth
        case .notifications: .notifications
        default: nil
        }
    }
}

/// What the person answered on Welcome: whether they have a WHOOP band to
/// pair. Nil in a snapshot means the band path, as every build before the
/// choice existed behaved.
public enum OnboardingBandChoice: String, Codable, CaseIterable, Sendable {
    case hasBand
    case noBand
}

/// The sequence of visible steps for one band choice.
public enum OnboardingPath: Equatable, Sendable {
    /// Welcome, Get your band ready, Connect, About you, Apple Health, Ready: six steps.
    case band
    /// Welcome, About you, Apple Health, Ready: four steps, none of them about a band.
    case noBand

    public var steps: [OnboardingStage] {
        switch self {
        case .band:
            [.welcomeDisclosures, .prepareBand, .pairing, .profileSetup, .appleHealth, .finish]
        case .noBand:
            [.welcomeDisclosures, .profileSetup, .appleHealth, .finish]
        }
    }

    public var stepCount: Int { steps.count }
}

/// The system permissions onboarding explains before asking for them.
public enum OnboardingPermission: String, Codable, CaseIterable, Sendable {
    case appleHealth
    case notifications

    public var stage: OnboardingStage {
        switch self {
        case .appleHealth: .appleHealth
        case .notifications: .notifications
        }
    }
}

/// What happened at a permission step. `skipped` means the person chose
/// "Not now" and iOS was never asked. The other values describe the system
/// answer as far as the app can know it; HealthKit never reveals whether
/// read access was granted, so a completed Health request is `requested`.
public enum OnboardingPermissionOutcome: String, Codable, Sendable {
    case skipped
    case requested
    case granted
    case denied
    case unavailable
}

/// The single seam through which onboarding reaches iOS permission prompts.
/// The app owns the real HealthKit and UserNotifications calls; the package
/// only decides when a request is allowed.
public protocol OnboardingPermissionCoordinator: Sendable {
    func request(_ permission: OnboardingPermission) async -> OnboardingPermissionOutcome
}

public struct NoopPermissionCoordinator: OnboardingPermissionCoordinator {
    public init() {}
    public func request(_ permission: OnboardingPermission) async -> OnboardingPermissionOutcome { .unavailable }
}

/// Versioned consent for the experimental WHOOP 5.0 and MG path.
public struct BetaConsent: Codable, Equatable, Sendable {
    public static let currentVersion = "gen5-mg-experimental-2026-09-29"
    public enum Status: String, Codable, Sendable {
        case neverGranted
        case granted
        case withdrawn
    }

    public private(set) var status: Status
    public private(set) var version: String?
    public private(set) var grantedAt: Date?
    public private(set) var withdrawnAt: Date?

    public init(status: Status = .neverGranted, version: String? = nil, grantedAt: Date? = nil, withdrawnAt: Date? = nil) {
        self.status = status
        self.version = version
        self.grantedAt = grantedAt
        self.withdrawnAt = withdrawnAt
    }

    public mutating func grant(version: String, at date: Date) {
        status = .granted
        self.version = version
        grantedAt = date
        withdrawnAt = nil
    }

    public mutating func withdraw(at date: Date) {
        guard status == .granted else { return }
        status = .withdrawn
        withdrawnAt = date
    }

    public var isGranted: Bool { status == .granted && version == Self.currentVersion }
}

/// The picker and Settings read the same versioned decision. Old grants do not
/// silently opt a person into a new experimental protocol revision.
public final class UserDefaultsBetaConsentStore: @unchecked Sendable {
    public static let key = "com.loopr.onboarding.experimentalBandConsent.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> BetaConsent {
        guard let data = defaults.data(forKey: Self.key),
              let consent = try? JSONDecoder().decode(BetaConsent.self, from: data) else {
            return BetaConsent()
        }
        return consent
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool, at date: Date = Date()) throws -> BetaConsent {
        var consent = load()
        if enabled { consent.grant(version: BetaConsent.currentVersion, at: date) }
        else { consent.withdraw(at: date) }
        defaults.set(try JSONEncoder().encode(consent), forKey: Self.key)
        return consent
    }
}

public enum OnboardingMigrationChoice: String, Codable, CaseIterable, Sendable {
    case startFresh
    case importExisting
    case decideLater
}

public struct OnboardingSnapshot: Codable, Equatable, Sendable {
    public let stage: OnboardingStage
    public let profileDraft: ProfileDraft?
    public let betaConsent: BetaConsent
    public let pairingRequested: Bool
    public let migrationChoice: OnboardingMigrationChoice?
    public let lastUpdatedAt: Date
    // The fields below were added with the 2026-09 flow. They are optional so
    // snapshots written by earlier builds still decode.
    public let appleHealthOutcome: OnboardingPermissionOutcome?
    public let notificationsOutcome: OnboardingPermissionOutcome?
    public let sleepGoalHours: Double?
    /// Added with the no-band path. Nil in snapshots from earlier builds,
    /// which read as the band path.
    public let bandChoice: OnboardingBandChoice?

    public init(
        stage: OnboardingStage,
        profileDraft: ProfileDraft? = nil,
        betaConsent: BetaConsent = BetaConsent(),
        pairingRequested: Bool = false,
        migrationChoice: OnboardingMigrationChoice? = nil,
        lastUpdatedAt: Date,
        appleHealthOutcome: OnboardingPermissionOutcome? = nil,
        notificationsOutcome: OnboardingPermissionOutcome? = nil,
        sleepGoalHours: Double? = nil,
        bandChoice: OnboardingBandChoice? = nil
    ) {
        self.stage = stage
        self.profileDraft = profileDraft
        self.betaConsent = betaConsent
        self.pairingRequested = pairingRequested
        self.migrationChoice = migrationChoice
        self.lastUpdatedAt = lastUpdatedAt
        self.appleHealthOutcome = appleHealthOutcome
        self.notificationsOutcome = notificationsOutcome
        self.sleepGoalHours = sleepGoalHours
        self.bandChoice = bandChoice
    }

    /// The steps this person walks: without a band, the band steps drop out.
    public var path: OnboardingPath { bandChoice == .noBand ? .noBand : .band }

    /// One-based position of the current stage on this person's path.
    public var stepNumber: Int? { stage.stepNumber(on: path) }

    /// The step the header shows. Nil on Welcome before the band choice, since the path's length is not known yet:
    /// it read "Step 1 of 9", then "Step 2 of 6" after "Continue without a band" (R3-NEW-16).
    public var shownStepNumber: Int? {
        stage == .welcomeDisclosures && bandChoice == nil ? nil : stepNumber
    }

    public func outcome(for permission: OnboardingPermission) -> OnboardingPermissionOutcome? {
        switch permission {
        case .appleHealth: appleHealthOutcome
        case .notifications: notificationsOutcome
        }
    }

    /// Copies the snapshot with only the named fields changed. Every
    /// transition goes through this so a new field cannot be dropped by one
    /// hand-written initializer call.
    func with(
        stage: OnboardingStage? = nil,
        profileDraft: ProfileDraft?? = nil,
        betaConsent: BetaConsent? = nil,
        pairingRequested: Bool? = nil,
        migrationChoice: OnboardingMigrationChoice?? = nil,
        lastUpdatedAt: Date,
        appleHealthOutcome: OnboardingPermissionOutcome?? = nil,
        notificationsOutcome: OnboardingPermissionOutcome?? = nil,
        sleepGoalHours: Double?? = nil,
        bandChoice: OnboardingBandChoice?? = nil
    ) -> OnboardingSnapshot {
        OnboardingSnapshot(
            stage: stage ?? self.stage,
            profileDraft: profileDraft ?? self.profileDraft,
            betaConsent: betaConsent ?? self.betaConsent,
            pairingRequested: pairingRequested ?? self.pairingRequested,
            migrationChoice: migrationChoice ?? self.migrationChoice,
            lastUpdatedAt: lastUpdatedAt,
            appleHealthOutcome: appleHealthOutcome ?? self.appleHealthOutcome,
            notificationsOutcome: notificationsOutcome ?? self.notificationsOutcome,
            sleepGoalHours: sleepGoalHours ?? self.sleepGoalHours,
            bandChoice: bandChoice ?? self.bandChoice
        )
    }
}

public protocol OnboardingRepository: Sendable {
    func load() async throws -> OnboardingSnapshot?
    func save(_ snapshot: OnboardingSnapshot) async throws
    func clear() async throws
}

public extension OnboardingRepository {
    func setExperimentalSupport(_ enabled: Bool, at date: Date = Date()) async throws {
        guard let snapshot = try await load() else { return }
        var consent = snapshot.betaConsent
        if enabled { consent.grant(version: BetaConsent.currentVersion, at: date) }
        else { consent.withdraw(at: date) }
        try await save(snapshot.with(betaConsent: consent, lastUpdatedAt: date))
    }
}

public actor InMemoryOnboardingRepository: OnboardingRepository {
    private var snapshot: OnboardingSnapshot?

    public init(snapshot: OnboardingSnapshot? = nil) { self.snapshot = snapshot }

    public func load() async throws -> OnboardingSnapshot? { snapshot }
    public func save(_ snapshot: OnboardingSnapshot) async throws { self.snapshot = snapshot }
    public func clear() async throws { snapshot = nil }
}

public protocol ContextualPairingCoordinator: Sendable {
    func requestPairing() async throws
}

public struct NoopPairingCoordinator: ContextualPairingCoordinator {
    public init() {}
    public func requestPairing() async throws {}
}

public enum OnboardingDestructiveAction: String, CaseIterable, Codable, Sendable {
    case resetProfile
    case forgetBand
    case deleteAllData
}

public protocol OnboardingDataEffects: Sendable {
    func resetProfile() async throws
    func forgetBand() async throws
    func deleteAllData() async throws
}

public struct NoopOnboardingDataEffects: OnboardingDataEffects {
    public init() {}
    public func resetProfile() async throws {}
    public func forgetBand() async throws {}
    public func deleteAllData() async throws {}
}

public actor InMemoryOnboardingDataEffects: OnboardingDataEffects {
    public private(set) var profileExists: Bool
    public private(set) var bandPaired: Bool
    public private(set) var appDataExists: Bool
    public private(set) var actions: [OnboardingDestructiveAction] = []

    public init(profileExists: Bool = true, bandPaired: Bool = true, appDataExists: Bool = true) {
        self.profileExists = profileExists
        self.bandPaired = bandPaired
        self.appDataExists = appDataExists
    }

    public func resetProfile() async throws {
        actions.append(.resetProfile)
        profileExists = false
    }

    public func forgetBand() async throws {
        actions.append(.forgetBand)
        bandPaired = false
    }

    public func deleteAllData() async throws {
        actions.append(.deleteAllData)
        appDataExists = false
        profileExists = false
        bandPaired = false
    }
}

public enum OnboardingTransitionError: Error, Equatable, Sendable, LocalizedError {
    case invalidStage(expected: OnboardingStage, received: OnboardingStage)
    case profileRequired
    case pairingRequired
    case pairingMustBeContextual
    case permissionMustBeContextual(OnboardingPermission)
    case invalidSleepGoal
    case goalsUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidStage(let expected, let received):
            "Expected onboarding stage \(expected.rawValue), received \(received.rawValue)."
        case .profileRequired: "Save your profile before you continue."
        case .pairingRequired: "Connect your band first, or choose Set up my band later."
        case .pairingMustBeContextual: "Pairing may only be requested from the pairing stage."
        case .permissionMustBeContextual(let permission):
            "The \(permission.rawValue) permission may only be requested from its own step."
        case .invalidSleepGoal: "Choose a sleep need between 4 and 12 hours."
        case .goalsUnavailable: "Loopr can't save your sleep need right now. You can set it later in Settings."
        }
    }
}

/// Owns the persisted gate sequence.  Every transition is durable before it
/// is returned, so rebuilding the controller after termination resumes at the
/// last completed stage rather than starting over.
public actor OnboardingFlowController {
    /// Sleep goals outside this range are almost certainly typos. It is a
    /// plausibility bound for a target, not advice.
    public static let sleepGoalRange: ClosedRange<Double> = 4 ... 12

    private let repository: any OnboardingRepository
    private let profileRepository: any ProfileRepository
    private let goalsRepository: (any GoalsRepository)?
    private let pairingCoordinator: any ContextualPairingCoordinator
    private let permissionCoordinator: any OnboardingPermissionCoordinator
    private let dataEffects: any OnboardingDataEffects
    private let dateProvider: any DateProviding
    private var state: OnboardingSnapshot

    public init(
        repository: any OnboardingRepository,
        profileRepository: any ProfileRepository,
        goalsRepository: (any GoalsRepository)? = nil,
        pairingCoordinator: any ContextualPairingCoordinator = NoopPairingCoordinator(),
        permissionCoordinator: any OnboardingPermissionCoordinator = NoopPermissionCoordinator(),
        dataEffects: any OnboardingDataEffects = NoopOnboardingDataEffects(),
        dateProvider: any DateProviding = SystemDateProvider()
    ) async throws {
        self.repository = repository
        self.profileRepository = profileRepository
        self.goalsRepository = goalsRepository
        self.pairingCoordinator = pairingCoordinator
        self.permissionCoordinator = permissionCoordinator
        self.dataEffects = dataEffects
        self.dateProvider = dateProvider
        self.state = try await repository.load() ?? OnboardingSnapshot(stage: .launching, lastUpdatedAt: dateProvider.now())
    }

    public func resume() async throws -> OnboardingSnapshot {
        if let persisted = try await repository.load() { state = persisted }
        return state
    }

    public func snapshot() -> OnboardingSnapshot { state }

    @discardableResult
    public func setExperimentalSupport(_ enabled: Bool) async throws -> OnboardingSnapshot {
        let now = dateProvider.now()
        var consent = state.betaConsent
        if enabled { consent.grant(version: BetaConsent.currentVersion, at: now) }
        else { consent.withdraw(at: now) }
        return try await commit(state.with(betaConsent: consent, lastUpdatedAt: now))
    }

    private func commit(_ next: OnboardingSnapshot) async throws -> OnboardingSnapshot {
        try await repository.save(next)
        state = next
        return state
    }

    /// Moves to the next stage. Steps that need a decision refuse to be
    /// skipped this way: pairing needs a pairing request (or the named
    /// `deferPairing()`), and the profile step needs a saved profile.
    /// Next from Welcome is "I have a WHOOP band": it records the band path,
    /// even for someone who chose no band, came back, and changed their mind.
    @discardableResult
    public func advance() async throws -> OnboardingSnapshot {
        if state.stage == .welcomeDisclosures {
            return try await commit(state.with(
                stage: OnboardingStage.welcomeDisclosures.next,
                lastUpdatedAt: dateProvider.now(),
                bandChoice: .some(.hasBand)
            ))
        }
        guard let next = state.stage.next(on: state.path) else { return state }
        if state.stage == .pairing && !state.pairingRequested {
            throw OnboardingTransitionError.pairingRequired
        }
        if state.stage == .profileSetup && state.profileDraft == nil {
            throw OnboardingTransitionError.profileRequired
        }
        return try await commit(state.with(stage: next, lastUpdatedAt: dateProvider.now()))
    }

    /// "Continue without a band" on Welcome: skips the three band steps and
    /// goes to About you. Nothing is paired, so `pairingRequested` stays
    /// false and later screens know there is no band to talk to.
    @discardableResult
    public func continueWithoutBand() async throws -> OnboardingSnapshot {
        guard state.stage == .welcomeDisclosures else {
            throw OnboardingTransitionError.invalidStage(expected: .welcomeDisclosures, received: state.stage)
        }
        return try await commit(state.with(
            stage: OnboardingStage.welcomeDisclosures.next(on: .noBand),
            pairingRequested: false,
            lastUpdatedAt: dateProvider.now(),
            bandChoice: .some(.noBand)
        ))
    }

    /// Back is always available on a visible step after the first. Going
    /// back keeps everything already recorded: a pairing request, a saved
    /// profile, a permission answer. It only moves the pointer, along the
    /// person's own path.
    @discardableResult
    public func goBack() async throws -> OnboardingSnapshot {
        guard let previous = state.stage.previous(on: state.path) else { return state }
        return try await commit(state.with(stage: previous, lastUpdatedAt: dateProvider.now()))
    }

    /// Leaves the band steps without pairing, for a user whose band is flat,
    /// out of range, or not yet delivered.  `advance()` deliberately refuses
    /// this transition, so the skip has to be its own named call rather than a
    /// relaxation of that guard.  `pairingRequested` stays false, which is what
    /// later screens read to decide they have no band to talk to.
    @discardableResult
    public func deferPairing() async throws -> OnboardingSnapshot {
        guard OnboardingStage.bandSteps.contains(state.stage) else {
            throw OnboardingTransitionError.invalidStage(expected: .pairing, received: state.stage)
        }
        return try await commit(state.with(
            stage: .profileSetup,
            pairingRequested: false,
            lastUpdatedAt: dateProvider.now()
        ))
    }

    /// This is the only method that may invoke the contextual Bluetooth
    /// permission/picker seam.  Launch inspection and other stages cannot call
    /// it because they fail closed with `pairingMustBeContextual`.  It does
    /// not advance: the pairing step stays on screen to show the connection
    /// until the person continues.
    @discardableResult
    public func requestContextualPairing() async throws -> OnboardingSnapshot {
        guard state.stage == .pairing else { throw OnboardingTransitionError.pairingMustBeContextual }
        try await pairingCoordinator.requestPairing()
        return try await commit(state.with(pairingRequested: true, lastUpdatedAt: dateProvider.now()))
    }

    @discardableResult
    public func saveProfileDraft(_ draft: ProfileDraft) async throws -> OnboardingSnapshot {
        guard state.stage == .profileSetup else {
            throw OnboardingTransitionError.invalidStage(expected: .profileSetup, received: state.stage)
        }
        try ProfileValidator.validate(draft)
        return try await commit(state.with(profileDraft: .some(draft), lastUpdatedAt: dateProvider.now()))
    }

    /// Saves the canonical profile and moves on to the permission steps.
    @discardableResult
    public func completeProfile(_ draft: ProfileDraft) async throws -> OnboardingSnapshot {
        try ProfileValidator.validate(draft)
        guard state.stage == .profileSetup else {
            throw OnboardingTransitionError.invalidStage(expected: .profileSetup, received: state.stage)
        }
        _ = try await profileRepository.saveProfile(draft)
        return try await commit(state.with(
            stage: OnboardingStage.profileSetup.next,
            profileDraft: .some(draft),
            lastUpdatedAt: dateProvider.now()
        ))
    }

    /// Asks iOS for one permission, then moves on whatever the answer. The
    /// request is allowed only from the step that explained it, so no other
    /// screen can trigger a system prompt through onboarding.
    @discardableResult
    public func requestPermission(_ permission: OnboardingPermission) async throws -> OnboardingSnapshot {
        guard state.stage == permission.stage else {
            throw OnboardingTransitionError.permissionMustBeContextual(permission)
        }
        let outcome = await permissionCoordinator.request(permission)
        return try await recordPermission(permission, outcome: outcome)
    }

    /// "Not now": records the choice and moves on without asking iOS.
    @discardableResult
    public func skipPermission(_ permission: OnboardingPermission) async throws -> OnboardingSnapshot {
        guard state.stage == permission.stage else {
            throw OnboardingTransitionError.invalidStage(expected: permission.stage, received: state.stage)
        }
        return try await recordPermission(permission, outcome: .skipped)
    }

    private func recordPermission(
        _ permission: OnboardingPermission,
        outcome: OnboardingPermissionOutcome
    ) async throws -> OnboardingSnapshot {
        let now = dateProvider.now()
        let next = permission.stage.next
        switch permission {
        case .appleHealth:
            return try await commit(state.with(stage: next, lastUpdatedAt: now, appleHealthOutcome: .some(outcome)))
        case .notifications:
            return try await commit(state.with(stage: next, lastUpdatedAt: now, notificationsOutcome: .some(outcome)))
        }
    }

    /// Writes the sleep target through the same ProfileKit goal that Settings
    /// and Today use, then moves on. No new persistence.
    @discardableResult
    public func saveSleepGoal(hours: Double) async throws -> OnboardingSnapshot {
        guard state.stage == .sleepGoal else {
            throw OnboardingTransitionError.invalidStage(expected: .sleepGoal, received: state.stage)
        }
        guard hours.isFinite, Self.sleepGoalRange.contains(hours) else {
            throw OnboardingTransitionError.invalidSleepGoal
        }
        guard let goalsRepository else { throw OnboardingTransitionError.goalsUnavailable }
        _ = try await goalsRepository.saveGoal(type: .sleep, target: hours, unit: "hours", isEnabled: true)
        return try await commit(state.with(
            stage: OnboardingStage.sleepGoal.next,
            lastUpdatedAt: dateProvider.now(),
            sleepGoalHours: .some(hours)
        ))
    }

    @discardableResult
    public func skipSleepGoal() async throws -> OnboardingSnapshot {
        guard state.stage == .sleepGoal else {
            throw OnboardingTransitionError.invalidStage(expected: .sleepGoal, received: state.stage)
        }
        return try await commit(state.with(stage: OnboardingStage.sleepGoal.next, lastUpdatedAt: dateProvider.now()))
    }

    /// The last step: enters the main shell.
    @discardableResult
    public func finish() async throws -> OnboardingSnapshot {
        guard state.stage == .finish else {
            throw OnboardingTransitionError.invalidStage(expected: .finish, received: state.stage)
        }
        return try await commit(state.with(stage: .mainShell, lastUpdatedAt: dateProvider.now()))
    }

    @discardableResult
    public func chooseMigration(_ choice: OnboardingMigrationChoice) async throws -> OnboardingSnapshot {
        try await commit(state.with(migrationChoice: .some(choice), lastUpdatedAt: dateProvider.now()))
    }

    public func perform(_ action: OnboardingDestructiveAction) async throws {
        // Keep these branches intentionally separate.  A confirmation UI can
        // therefore call one action without accidentally widening its effect.
        switch action {
        case .resetProfile:
            try await dataEffects.resetProfile()
            try await profileRepository.resetProfile()
        case .forgetBand:
            try await dataEffects.forgetBand()
        case .deleteAllData:
            try await dataEffects.deleteAllData()
            try await profileRepository.deleteAllData()
        }
    }
}

public enum OnboardingUniversalState: String, CaseIterable, Codable, Sendable {
    case loading
    case noRecordsYet
    case absentMetric
    case measuredZero
    case partialData
    case lowConfidence
    case settlingOrRecomputing
    case stale
    case disconnected
    case bluetoothOff
    case permissionDenied
    case unsupportedHardware
    case recoverableError
    case destructiveOrMigrationFailure
}

public struct OnboardingStateFixture: Equatable, Sendable {
    public let state: OnboardingUniversalState
    public let title: String
    public let detail: String
    public let isActionable: Bool

    public init(state: OnboardingUniversalState, title: String, detail: String, isActionable: Bool) {
        self.state = state
        self.title = title
        self.detail = detail
        self.isActionable = isActionable
    }

    public var accessibilityIdentifier: String {
        "onboarding-state-\(state.rawValue)"
    }

    public var voiceOverLabel: String {
        "\(title). \(detail)"
    }
}

public enum OnboardingStateFixtures {
    public static let all: [OnboardingStateFixture] = OnboardingUniversalState.allCases.map { state in
        switch state {
        case .loading: OnboardingStateFixture(state: state, title: "Loading", detail: "Preparing Loopr.", isActionable: false)
        case .noRecordsYet: OnboardingStateFixture(state: state, title: "No records yet", detail: "Pair a band to begin.", isActionable: true)
        case .absentMetric: OnboardingStateFixture(state: state, title: "Not available", detail: "This value is not present.", isActionable: false)
        case .measuredZero: OnboardingStateFixture(state: state, title: "Measured zero", detail: "The measured value is 0.", isActionable: false)
        case .partialData: OnboardingStateFixture(state: state, title: "Partial data", detail: "Some data is still arriving.", isActionable: true)
        case .lowConfidence: OnboardingStateFixture(state: state, title: "Low confidence", detail: "More data is needed.", isActionable: true)
        case .settlingOrRecomputing: OnboardingStateFixture(state: state, title: "Updating", detail: "Loopr is recomputing safely.", isActionable: false)
        case .stale: OnboardingStateFixture(state: state, title: "Update needed", detail: "The last sync is stale.", isActionable: true)
        case .disconnected: OnboardingStateFixture(state: state, title: "Disconnected", detail: "The band is not connected.", isActionable: true)
        case .bluetoothOff: OnboardingStateFixture(state: state, title: "Bluetooth is off", detail: "Turn on Bluetooth to pair.", isActionable: true)
        case .permissionDenied: OnboardingStateFixture(state: state, title: "Permission needed", detail: "Allow Bluetooth from the pairing action.", isActionable: true)
        case .unsupportedHardware: OnboardingStateFixture(state: state, title: "Unsupported hardware", detail: "This device is not supported.", isActionable: false)
        case .recoverableError: OnboardingStateFixture(state: state, title: "Try again", detail: "The operation can be retried.", isActionable: true)
        case .destructiveOrMigrationFailure: OnboardingStateFixture(state: state, title: "Could not finish", detail: "Your data is preserved; retry or review settings.", isActionable: true)
        }
    }
}

public enum OnboardingStateRenderer {
    public static func render(_ state: OnboardingUniversalState) -> OnboardingStateFixture {
        OnboardingStateFixtures.all.first { $0.state == state } ??
            OnboardingStateFixture(
                state: state,
                title: "Unavailable",
                detail: "This onboarding state is not available.",
                isActionable: false
            )
    }
}

public struct OnboardingAccessibilityContract: Equatable, Sendable {
    public static let minimumTouchTarget: Double = 44
    public static let requiredScreenIdentifiers: Set<String> = [
        "onboarding-screen",
        "profile-setup-screen",
        "onboarding-continue",
        "onboarding-pair",
        "profile-save",
        "onboarding-destructive-actions-screen",
        "onboarding-reset-profile",
        "onboarding-forget-band",
        "onboarding-delete-all-data"
    ]

    public let supportsDynamicType: Bool
    public let supportsReduceMotion: Bool
    public let usesSemanticVoiceOverLabels: Bool

    public init(
        supportsDynamicType: Bool = true,
        supportsReduceMotion: Bool = true,
        usesSemanticVoiceOverLabels: Bool = true
    ) {
        self.supportsDynamicType = supportsDynamicType
        self.supportsReduceMotion = supportsReduceMotion
        self.usesSemanticVoiceOverLabels = usesSemanticVoiceOverLabels
    }
}

public enum OnboardingTelemetryPolicy {
    /// Onboarding emits no analytics event before explicit consent.
    public static let emitsEventsBeforeConsent = false
}

public enum OnboardingDisclosureCopy {
    public static let nonAffiliation = "Loopr is independent from WHOOP."
    public static let healthBoundary = "Loopr is not a medical device and does not provide medical advice."
    public static let localFirst = "Loopr keeps your records on this iPhone. Nothing leaves it unless you export a backup, write samples to Apple Health, or connect your own AI provider."
    public static let noAccount = "Nothing to sign up for. Your data is not tied to any login."
    public static let stableGen4 = "WHOOP 4.0 is the band Loopr supports."
}
