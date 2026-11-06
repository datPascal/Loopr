import BluetoothKit
import DeviceCenterKit
import Foundation
import SyncKit

// MARK: - Phone layer preference

/// Whether the person wants the phone alarm under the band alarm. On by
/// default: the band has accepted alarms and stayed silent, so the phone is
/// the layer that actually wakes people.
nonisolated final class LooprPhoneAlarmPreference: @unchecked Sendable {
    static let key = "loopr.alarm.phone-layer-enabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        defaults.object(forKey: Self.key) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.key)
    }
}

// MARK: - Snapshot

/// Everything the wake alarm surfaces read, in one value.
nonisolated struct WakeAlarmSnapshot: Equatable, Sendable {
    var configuration: StrapAlarmConfiguration?
    var assurance: StrapAlarmAssurance?
    var phoneLayerEnabled: Bool
    var bandConnected: Bool
    var cancellationPending = false

    var cancellationWarning: String? {
        cancellationPending
            ? "Loopr has not confirmed that both alarms are off. One may still ring. Try turning the alarm off again with your band connected."
            : nil
    }

    var isOn: Bool { configuration?.isEnabled == true }

    var band: WakeAlarmBandLayer {
        WakeAlarmBandLayer(assurance: assurance, alarmEnabled: isOn, bandConnected: bandConnected)
    }

    var phone: WakeAlarmPhoneLayer {
        WakeAlarmPhoneLayer(
            backup: phoneLayerEnabled ? assurance?.phoneBackup : nil,
            alarmEnabled: isOn,
            layerEnabled: phoneLayerEnabled
        )
    }

    func screenModel(suggestion: WakeAlarmSuggestion?) -> WakeAlarmScreenModel {
        WakeAlarmScreenModel(
            saved: configuration.map { WakeAlarmPlan(configuration: $0) },
            band: band,
            phone: phone,
            phoneLayerEnabled: phoneLayerEnabled,
            bandConnected: bandConnected,
            suggestion: suggestion
        )
    }

    func cardState(suggestion: WakeAlarmSuggestion?, now: Date, formatter: WakeAlarmFormatter) -> WakeAlarmCardState {
        WakeAlarmCardState.make(
            configuration: configuration,
            band: band,
            phone: phone,
            suggestion: suggestion,
            now: now,
            formatter: formatter
        )
    }

    /// The short value beside the Settings row: the wake time, or "Off".
    func settingsSummary(formatter: WakeAlarmFormatter) -> String {
        guard isOn, let configuration else { return "Off" }
        return formatter.time(minuteOfDay: WakeAlarmPlan(configuration: configuration).wakeMinute)
    }
}

// MARK: - Controller seam

/// What the wake alarm surfaces can ask for. Production drives the real strap
/// alarm service and the phone alarm; fixture launches and UI tests use an
/// in-memory stand-in that never touches the band, AlarmKit, or
/// notifications.
protocol WakeAlarmControlling: Sendable {
    func snapshot() async -> WakeAlarmSnapshot
    /// Saves and arms. Returns the next guaranteed wake.
    @discardableResult
    func save(_ plan: WakeAlarmPlan) async throws -> Date?
    func turnOff() async throws
    /// Writes the current alarm to the band again.
    func retryBand() async throws
    /// RUN_ALARM: buzzes the band now.
    func testBuzz() async throws
    func setPhoneLayerEnabled(_ enabled: Bool) async throws
}

// MARK: - Production

/// Drives the strap alarm service and the phone alarm for the wake alarm
/// screen.
///
/// It adds no new band behaviour. Saving persists through the same setup
/// service, schedules the phone layer, and hands the band write to the
/// existing `LooprStrapAlarmService.arm`, which clears, writes, waits for
/// event 56, reads back, and retries once. That write runs in the background
/// so the screen does not sit on a spinner for the band's confirmation
/// grace; the screen polls the evidence instead.
nonisolated struct LooprWakeAlarmController: WakeAlarmControlling {
    let runtime: (any LooprDeviceCenterRuntime)?
    let repository: any StrapAlarmConfigurationRepository
    let phoneAlarm: any PhoneAlarmScheduling
    var preference = LooprPhoneAlarmPreference()
    var armRecord = LooprStrapAlarmArmRecord()
    var calendar: Calendar = .autoupdatingCurrent
    var now: @Sendable () -> Date = { Date() }
    var operations = LooprAlarmOperationQueue.shared

    private var setup: DeviceAlarmSetupService { DeviceAlarmSetupService(repository: repository) }

    private var service: LooprStrapAlarmService? {
        runtime.map {
            LooprStrapAlarmService(
                runtime: $0,
                repository: repository,
                calendar: calendar,
                now: now,
                armRecord: armRecord,
                phoneAlarm: phoneAlarm,
                phonePreference: preference,
                operations: operations
            )
        }
    }

    func snapshot() async -> WakeAlarmSnapshot {
        let configuration = try? await setup.load()
        let connected = await runtime?.runtimeState().acceptsBandCommands ?? false
        var assurance: StrapAlarmAssurance
        if let service {
            assurance = await service.assurance()
            // The arm record describes the last occurrence written to the
            // band. After a new time is saved with the band away, that record
            // is the old alarm, so its confirmation says nothing about this
            // one. Report it as not on the band yet.
            if let planned = try? await service.plannedFireDate(),
               let armed = assurance.fireDate,
               abs(armed.timeIntervalSince(planned)) >= 1 {
                assurance = StrapAlarmAssurance(
                    band: .off,
                    lastReadbackAt: assurance.lastReadbackAt,
                    phoneBackup: assurance.phoneBackup,
                    windowStart: assurance.windowStart
                )
            }
        } else {
            let backup = await phoneAlarm.lastOutcome()?.assurance
                ?? .unavailable("Loopr has no backup alarm on this iPhone.")
            assurance = StrapAlarmAssurance(band: .off, phoneBackup: backup)
        }
        let phoneStillPresent = await phoneAlarm.lastOutcome() != nil
        return WakeAlarmSnapshot(
            configuration: configuration,
            assurance: assurance,
            phoneLayerEnabled: preference.isEnabled,
            bandConnected: connected,
            cancellationPending: configuration?.isEnabled != true && (armRecord.needsDisable || phoneStillPresent)
        )
    }

    @discardableResult
    func save(_ plan: WakeAlarmPlan) async throws -> Date? {
        if let service {
            return try await service.save(plan.configuration(updatedAt: now()), waitForBand: false)
        }
        return try await operations.withLock {
            let validated = try await setup.save(plan.configuration(updatedAt: now()))
            guard validated.isEnabled else {
                let needsBandCancellation = armRecord.read() != nil || armRecord.needsDisable
                if needsBandCancellation {
                    armRecord.setNeedsDisable(true)
                    armRecord.invalidateVerification()
                }
                do { try await phoneAlarm.cancelChecked() }
                catch {
                    throw needsBandCancellation ? LooprStrapAlarmError.bothCancellationsPending : .phoneCancellationPending
                }
                guard !needsBandCancellation else { throw LooprStrapAlarmError.cancellationPending }
                return nil
            }
            guard let fireDate = StrapAlarmSchedulePlanner.nextFireDate(
                for: validated, after: now(), calendar: calendar
            ) else { throw LooprStrapAlarmError.noOccurrence }
            try await schedulePhone(at: fireDate, configuration: validated)
            return fireDate
        }
    }

    func turnOff() async throws {
        let current = try await setup.load()
        var plan = WakeAlarmPlan(configuration: current)
        plan.isEnabled = false
        _ = try await save(plan)
    }

    func retryBand() async throws {
        guard let service, await runtime?.runtimeState().acceptsBandCommands == true else {
            throw BandCommandError.notReady
        }
        guard let fireDate = try await service.plannedFireDate() else {
            throw LooprStrapAlarmError.noOccurrence
        }
        guard let configuration = try await setup.load() else { throw LooprStrapAlarmError.noOccurrence }
        Task { await service.armIfCurrent(fireDate, configuration: configuration, reason: "sent again from the wake alarm screen") }
    }

    func testBuzz() async throws {
        guard let service, await runtime?.runtimeState().acceptsBandCommands == true else {
            throw BandCommandError.notReady
        }
        try await service.test()
    }

    func setPhoneLayerEnabled(_ enabled: Bool) async throws {
        try await operations.withLock {
            guard enabled else {
                do { try await phoneAlarm.cancelChecked() }
                catch { throw LooprStrapAlarmError.phoneCancellationPending }
                preference.setEnabled(false)
                return
            }
            preference.setEnabled(true)
            guard let configuration = try? await setup.load(), configuration.isEnabled,
                  let fireDate = StrapAlarmSchedulePlanner.nextFireDate(
                    for: configuration, after: now(), calendar: calendar
                  ) else { return }
            try await schedulePhone(at: fireDate, configuration: configuration)
        }
    }

    private func schedulePhone(at fireDate: Date, configuration: StrapAlarmConfiguration) async throws {
        guard preference.isEnabled else {
            do { try await phoneAlarm.cancelChecked() }
            catch { throw LooprStrapAlarmError.phoneCancellationPending }
            return
        }
        await phoneAlarm.prepare()
        let outcome = await phoneAlarm.schedule(at: fireDate, repeating: configuration)
        BandActionLog.alarm("phone alarm from the wake alarm screen: \(outcome)")
    }

}

// MARK: - Fixture

/// The wake alarm for fixture launches, previews, and UI tests.
///
/// Nothing here reaches hardware or the system: no band command, no AlarmKit
/// schedule, no notification. The phone layer reports "scheduled" because a
/// fixture has to show the populated state, and the band confirms a moment
/// after a save when the fixture says it is connected.
///
/// DEBUG launches can pick a starting state with
/// `--loopr-wake-alarm-fixture=empty|set|confirmed|unconfirmed|disconnected`.
actor FixtureWakeAlarmController: WakeAlarmControlling {
    static let shared = FixtureWakeAlarmController(seed: .fromLaunchArguments())

    enum Seed: String {
        case empty, set, confirmed, unconfirmed, disconnected

        static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Seed {
            let prefix = "--loopr-wake-alarm-fixture="
            guard let raw = arguments.first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count) else {
                return .empty
            }
            return Seed(rawValue: String(raw)) ?? .empty
        }
    }

    private var configuration: StrapAlarmConfiguration?
    private var band: StrapAlarmAssurance.BandState
    private var connected: Bool
    private var phoneLayerEnabled = true
    private var lastReadbackAt: Date?
    private let confirmationDelay: Duration

    init(seed: Seed, confirmationDelay: Duration = .milliseconds(1_200)) {
        self.confirmationDelay = confirmationDelay
        let standard = WakeAlarmPlan(isEnabled: true, wakeMinute: 7 * 60, smartWindowMinutes: 30).configuration()
        switch seed {
        case .empty:
            configuration = nil; band = .off; connected = true
        case .set:
            configuration = standard; band = .waiting; connected = true
        case .confirmed:
            configuration = standard; band = .confirmed; connected = true; lastReadbackAt = Date()
        case .unconfirmed:
            configuration = standard; band = .unconfirmed; connected = true; lastReadbackAt = Date()
        case .disconnected:
            configuration = standard; band = .notArmed; connected = false
        }
    }

    func snapshot() async -> WakeAlarmSnapshot {
        let on = configuration?.isEnabled == true
        return WakeAlarmSnapshot(
            configuration: configuration,
            assurance: StrapAlarmAssurance(
                band: on ? band : .off,
                lastReadbackAt: lastReadbackAt,
                phoneBackup: on ? .systemAlarm : .unavailable("No alarm is set.")
            ),
            phoneLayerEnabled: phoneLayerEnabled,
            bandConnected: connected
        )
    }

    @discardableResult
    func save(_ plan: WakeAlarmPlan) async throws -> Date? {
        let validated = try plan.configuration(updatedAt: Date()).validated()
        configuration = validated
        guard validated.isEnabled else {
            band = .off
            return nil
        }
        band = connected ? .waiting : .notArmed
        if connected { scheduleConfirmation() }
        return StrapAlarmSchedulePlanner.nextFireDate(for: validated, after: Date(), calendar: .autoupdatingCurrent)
    }

    func turnOff() async throws {
        var plan = WakeAlarmPlan(configuration: configuration)
        plan.isEnabled = false
        configuration = plan.configuration(updatedAt: Date())
        band = .off
    }

    func retryBand() async throws {
        guard connected else { throw BandCommandError.notReady }
        band = .waiting
        scheduleConfirmation()
    }

    func testBuzz() async throws {
        guard connected else { throw BandCommandError.notReady }
    }

    func setPhoneLayerEnabled(_ enabled: Bool) async {
        phoneLayerEnabled = enabled
    }

    private func scheduleConfirmation() {
        let delay = confirmationDelay
        Task {
            try? await Task.sleep(for: delay)
            self.confirm()
        }
    }

    private func confirm() {
        guard band == .waiting else { return }
        band = .confirmed
        lastReadbackAt = Date()
    }
}

// MARK: - Composition

enum WakeAlarmControllerFactory {
    /// Fixture launches get the in-memory controller; production gets the
    /// real one when its alarm store is open, and nil when it is not.
    @MainActor
    static func make(repositories: ProductRepositoryContainer?) -> (any WakeAlarmControlling)? {
        if repositories?.isFixtureComposition ?? true {
            return FixtureWakeAlarmController.shared
        }
        guard let repository = repositories?.persistent?.device as? any StrapAlarmConfigurationRepository else {
            return nil
        }
        return LooprWakeAlarmController(
            runtime: repositories?.deviceCenterRuntime,
            repository: repository,
            phoneAlarm: PhoneAlarmFallback()
        )
    }
}
