import AnalyticsKit
import BluetoothKit
import DeviceCenterKit
import DomainKit
import Foundation
import Observation
import JournalKit
import ProtocolKit
import SleepKit
import StorageKit
import SyncKit

#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Error copy

/// `BandCommandError` is a typed transport result, not user copy, and its
/// default description reads as a Foundation error code. Every band failure a
/// person can see goes through here first.
nonisolated enum BandActionCopy {
    static func readable(_ error: Error) -> String {
        if let command = error as? BandCommandError {
            return switch command {
            case .notReady:
                "Your strap is not connected right now. Bring it near your iPhone, then try again."
            case .timedOut:
                "Your strap did not answer in time. Wake it until its side light pulses blue, then try again."
            case .rejected:
                "Your strap refused that. Try again in a moment."
            case .invalidName:
                "That name does not fit on the strap. Use up to \(StrapNameRules.maximumUserCharacters) letters, numbers, or spaces."
            }
        }
        if let action = error as? DeviceActionError, let description = action.errorDescription {
            return description
        }
        if let runtime = error as? LooprDeviceRuntimeCommandError, let description = runtime.errorDescription {
            return description
        }
        if let alarm = error as? LooprStrapAlarmError, let description = alarm.errorDescription {
            return description
        }
        if let phone = error as? LooprPhoneActionError, let description = phone.errorDescription {
            return description
        }
        if let configuration = error as? DeviceConfigurationError, let description = configuration.errorDescription {
            return description
        }
        return "Loopr could not finish that on your strap. Keep it near your iPhone and try again."
    }
}

// MARK: - Gesture mapping

/// The double-tap choice lives in UserDefaults. It is one small preference
/// that has to survive a reinstall of the Device Center record and be readable
/// from the band-event consumer without opening the product database.
nonisolated final class LooprGestureMappingStore: @unchecked Sendable {
    static let doubleTapKey = "loopr.device-center.double-tap-action"

    /// A WHOOP 4 has no screen, speaker, or light, so every offered action
    /// runs on this iPhone.
    static let doubleTapOptions: [DeviceAction] = [.markMoment, .ringPhone, .torch]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func doubleTapAction() -> DeviceAction? {
        guard let raw = defaults.string(forKey: Self.doubleTapKey),
              let action = DeviceAction(rawValue: raw),
              Self.doubleTapOptions.contains(action) else {
            return nil
        }
        return action
    }

    func setDoubleTapAction(_ action: DeviceAction?) {
        guard let action, Self.doubleTapOptions.contains(action) else {
            defaults.removeObject(forKey: Self.doubleTapKey)
            return
        }
        defaults.set(action.rawValue, forKey: Self.doubleTapKey)
    }
}

/// One place to write the band lines the morning hardware script greps for.
/// DEBUG only, matching the SyncKit runtime log so both land in the same
/// console stream in the same order.
nonisolated enum BandActionLog {
    static func write(_ message: @autoclosure () -> String) {
        #if DEBUG
        let line = "[Loopr Alarm] \(Date().formatted(date: .omitted, time: .standard)) \(message())\n"
        fputs(line, stderr)
        #endif
    }

    /// Same stream, same prefix. The separate name marks the call sites the
    /// morning hardware script reads when an alarm did not fire.
    static func alarm(_ message: @autoclosure () -> String) {
        write(message())
    }

    static func band(_ message: @autoclosure () -> String) {
        #if DEBUG
        let line = "[Loopr Band] \(Date().formatted(date: .omitted, time: .standard)) \(message())\n"
        fputs(line, stderr)
        #endif
    }
}

// MARK: - Runtime seams

/// Feeds the DeviceCenterKit dispatchers the connection generation they fence
/// against, taken from the one shared SyncKit runtime.
struct LooprRuntimeGenerationProvider: DeviceRuntimeGenerationProvider {
    let runtime: any LooprDeviceCenterRuntime

    func currentGeneration() async -> UInt64? {
        await runtime.runtimeState().generation
    }
}

// MARK: - Mark a moment

/// Writes the tap into the canonical journal. The note names the source so a
/// user reading the entry later knows where it came from.
struct LooprJournalMomentSink: DeviceJournalMarkerSink {
    static let note = "Marked from your band"

    let journal: any JournalStore
    let note: String

    init(journal: any JournalStore, note: String = Self.note) {
        self.journal = journal; self.note = note
    }

    func append(_ marker: DeviceJournalMarker) async throws {
        try await mark(at: marker.occurredAt)
    }

    func mark(at date: Date) async throws {
        _ = try await journal.create(
            day: Self.day(for: date),
            behaviors: [],
            tags: [],
            note: note,
            id: nil,
            now: date
        )
    }

    /// The journal keys entries by a local `yyyy-MM-dd` label, the same shape
    /// the rest of the app writes.
    static func day(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Ring iPhone and flashlight

enum LooprPhoneActionError: Error, Equatable, Sendable, LocalizedError {
    case torchUnavailable
    case ringUnavailable

    var errorDescription: String? {
        switch self {
        case .torchUnavailable: "This iPhone has no flashlight to switch on."
        case .ringUnavailable: "Loopr could not play a sound on this iPhone."
        }
    }
}

/// Rings the phone and toggles the torch.
///
/// The alert tone plays through an AVAudioSession in `.playback`, which is the
/// only category that keeps a repeating alert audible while Loopr is in the
/// foreground. The ring stops after ten seconds or as soon as the user brings
/// Loopr forward, whichever comes first, so a tap cannot leave a phone
/// screaming in a pocket.
@MainActor
final class LooprPhoneActionPerformer {
    static let ringDuration: TimeInterval = 10
    static let ringInterval: TimeInterval = 1.2

    private var ringTask: Task<Void, Never>?

    init() {}

    func ring() throws {
        #if canImport(AVFoundation) && canImport(UIKit) && os(iOS)
        ringTask?.cancel()
        // Loopr has no `audio` background mode, so activating a playback
        // session fails whenever the app is not in front. That is exactly the
        // case this action is for: phone in a pocket, screen locked. Losing
        // the session means a quieter ring, not no ring, so the alert tone and
        // the vibration go ahead either way.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.duckOthers])
        try? session.setActive(true, options: [])
        ringTask = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(Self.ringDuration)
            let feedback = UINotificationFeedbackGenerator()
            feedback.prepare()
            while Date() < deadline, !Task.isCancelled {
                AudioServicesPlaySystemSound(SystemSoundID(1005))
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                feedback.notificationOccurred(.warning)
                try? await Task.sleep(nanoseconds: UInt64(Self.ringInterval * 1_000_000_000))
            }
            self?.finishRing()
        }
        #else
        throw LooprPhoneActionError.ringUnavailable
        #endif
    }

    /// Called when the user opens Loopr, which counts as acknowledging the
    /// ring, and when the ten seconds are up.
    func stopRinging() {
        ringTask?.cancel()
        ringTask = nil
        finishRing()
    }

    private func finishRing() {
        #if canImport(AVFoundation) && os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    /// Toggling `torchMode` does not open a capture session, so it needs no
    /// camera permission and no NSCameraUsageDescription.
    func toggleTorch() throws {
        #if canImport(AVFoundation) && os(iOS)
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
            throw LooprPhoneActionError.torchUnavailable
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = device.isTorchActive ? .off : .on
        } catch {
            throw LooprPhoneActionError.torchUnavailable
        }
        #else
        throw LooprPhoneActionError.torchUnavailable
        #endif
    }
}

/// Bridges the typed DeviceCenterKit request onto the main-actor performer.
struct LooprPhoneActionSink: DevicePhoneActionSink {
    let performer: LooprPhoneActionPerformer

    func perform(_ request: DevicePhoneActionRequest) async throws {
        try await MainActor.run {
            switch request.action {
            case .ringPhone: try performer.ring()
            case .torch: try performer.toggleTorch()
            }
        }
    }
}

// MARK: - Strap alarm

enum LooprStrapAlarmError: Error, Equatable, Sendable, LocalizedError {
    case noOccurrence

    var errorDescription: String? {
        "Pick a time and at least one weekday so Loopr knows when to wake you."
    }
}

/// Remembers the occurrence Loopr last wrote to the band, and every piece of
/// evidence that the band really took it.
///
/// This used to hold a connection generation and reconcile refused to rewrite
/// the alarm whenever the stored generation matched the current one. Generation
/// numbers restart at the same value in every process, so a record written at
/// 01:16 matched a fresh 06:50 launch, reconcile skipped, and nobody was woken
/// at 07:00. The generation is still here, but only to force a re-verify once
/// per link. Nothing in here is allowed to prevent a write on its own; only a
/// band read-back that agrees can do that.
///
/// It has to survive a relaunch, which is why it lives next to the gesture
/// choice in UserDefaults rather than in the product database.
nonisolated final class LooprStrapAlarmArmRecord: @unchecked Sendable {
    static let fireDateKey = "loopr.device-center.alarm-armed-fire-date"
    static let generationKey = "loopr.device-center.alarm-armed-generation"
    static let armedAtKey = "loopr.device-center.alarm-armed-at"
    static let verifiedAtKey = "loopr.device-center.alarm-verified-at"
    static let readbackKey = "loopr.device-center.alarm-last-readback"
    static let readbackAtKey = "loopr.device-center.alarm-last-readback-at"
    static let confirmedKey = "loopr.device-center.alarm-confirmed-by-event"
    static let writeFailedKey = "loopr.device-center.alarm-write-failed"

    struct Entry: Equatable, Sendable {
        /// The wall instant Loopr asked the band to buzz at.
        let fireDate: Date
        /// When the SET_ALARM write went out.
        let armedAt: Date
        /// The link that last wrote or verified this alarm. A different one
        /// means the band may have dropped the alarm with the connection.
        let linkGeneration: UInt64
        /// When a band read-back last agreed with `fireDate`.
        let verifiedAt: Date?
        /// The last time the band read back, whatever it said.
        let lastReadback: Date?
        let lastReadbackAt: Date?
        /// The band emitted event 56 for this alarm.
        let confirmedByEvent: Bool
        /// The SET_ALARM write itself failed, so the band is holding nothing.
        let writeFailed: Bool

        /// Only event 56 counts. The band read back the right time all night
        /// on 21 Sep and still never fired, so a read-back is a diagnostic,
        /// not evidence.
        var isTrusted: Bool { confirmedByEvent }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func read() -> Entry? {
        guard let seconds = defaults.object(forKey: Self.fireDateKey) as? Double else { return nil }
        return Entry(
            fireDate: Date(timeIntervalSince1970: seconds),
            armedAt: Self.date(defaults.object(forKey: Self.armedAtKey)) ?? Date(timeIntervalSince1970: seconds),
            linkGeneration: (defaults.object(forKey: Self.generationKey) as? NSNumber)?.uint64Value ?? 0,
            verifiedAt: Self.date(defaults.object(forKey: Self.verifiedAtKey)),
            lastReadback: Self.date(defaults.object(forKey: Self.readbackKey)),
            lastReadbackAt: Self.date(defaults.object(forKey: Self.readbackAtKey)),
            confirmedByEvent: defaults.bool(forKey: Self.confirmedKey),
            writeFailed: defaults.bool(forKey: Self.writeFailedKey)
        )
    }

    /// Records a fresh SET_ALARM write. Every piece of evidence resets: the
    /// band has not agreed to this one yet.
    func write(fireDate: Date, armedAt: Date, linkGeneration: UInt64) {
        defaults.set(fireDate.timeIntervalSince1970, forKey: Self.fireDateKey)
        defaults.set(armedAt.timeIntervalSince1970, forKey: Self.armedAtKey)
        defaults.set(NSNumber(value: linkGeneration), forKey: Self.generationKey)
        defaults.removeObject(forKey: Self.verifiedAtKey)
        defaults.removeObject(forKey: Self.readbackKey)
        defaults.removeObject(forKey: Self.readbackAtKey)
        defaults.set(false, forKey: Self.confirmedKey)
        defaults.set(false, forKey: Self.writeFailedKey)
    }

    /// The SET_ALARM write never reached the band.
    func markWriteFailed() {
        defaults.set(true, forKey: Self.writeFailedKey)
    }

    /// Stores what the band answered, matching or not, and stamps the link it
    /// was asked on so a failed read does not re-ask every minute.
    func markReadback(_ readback: Date?, at date: Date, linkGeneration: UInt64) {
        if let readback {
            defaults.set(readback.timeIntervalSince1970, forKey: Self.readbackKey)
        } else {
            defaults.removeObject(forKey: Self.readbackKey)
        }
        defaults.set(date.timeIntervalSince1970, forKey: Self.readbackAtKey)
        defaults.set(NSNumber(value: linkGeneration), forKey: Self.generationKey)
    }

    func markVerified(at date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.verifiedAtKey)
    }

    func markConfirmedByEvent(at date: Date) {
        defaults.set(true, forKey: Self.confirmedKey)
        defaults.set(date.timeIntervalSince1970, forKey: Self.verifiedAtKey)
    }

    /// Drops the evidence without dropping the target, so the next reconcile
    /// asks the band again. Used when the band reports its clock was set.
    func invalidateVerification() {
        defaults.removeObject(forKey: Self.verifiedAtKey)
        defaults.set(false, forKey: Self.confirmedKey)
        defaults.set(NSNumber(value: UInt64(0)), forKey: Self.generationKey)
    }

    func clear() {
        for key in [
            Self.fireDateKey, Self.generationKey, Self.armedAtKey,
            Self.verifiedAtKey, Self.readbackKey, Self.readbackAtKey,
            Self.confirmedKey, Self.writeFailedKey
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let seconds = value as? Double else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// Saves the alarm locally and arms the single occurrence the band can hold.
/// The band stores one absolute time, so Loopr re-arms the next one after each
/// alarm fires.
nonisolated struct LooprStrapAlarmService: Sendable {
    /// How far a band read-back may sit from the time Loopr asked for and
    /// still count as the same alarm. The band answers on whole seconds and
    /// the clock shift is rounded, so the real error is a second or two; a
    /// minute is generous and still cannot confuse today's alarm with
    /// tomorrow's.
    static let readbackTolerance: TimeInterval = 60
    /// How long the band gets to answer event 56 after an arm.
    static let confirmationGrace: TimeInterval = 6
    /// The shortest gap between two writes of the same occurrence. Without it
    /// a band that never reads back would be rewritten every reconcile.
    static let rearmThrottle: TimeInterval = 300

    let runtime: any LooprDeviceCenterRuntime
    let repository: any StrapAlarmConfigurationRepository
    var calendar: Calendar = .autoupdatingCurrent
    var now: @Sendable () -> Date = { Date() }
    var armRecord = LooprStrapAlarmArmRecord()
    /// The layer that wakes someone when the band does not. Optional so tests
    /// and fixture compositions can leave it out.
    var phoneAlarm: (any PhoneAlarmScheduling)?
    /// Lets the arm sequence wait for the band's event 56. Shared by default
    /// so a service built by a screen sees the same confirmations as the
    /// event consumer.
    var latchSignal: LooprAlarmLatchSignal? = .shared
    /// Whether the person wants the phone layer. On unless they switched it
    /// off on the wake alarm screen.
    var phonePreference = LooprPhoneAlarmPreference()

    func load() async throws -> StrapAlarmConfiguration? {
        try await DeviceAlarmSetupService(repository: repository).load()
    }

    /// Persists the configuration, then arms or clears both layers. Returns
    /// the occurrence Loopr promised, or nil when the alarm was turned off.
    ///
    /// A band that refuses the write does not fail the save. The iPhone alarm
    /// is scheduled first and on its own, so somebody whose band is flat, out
    /// of range, or wedged is still woken; the status screen is where the band
    /// failure shows up.
    @discardableResult
    func save(_ configuration: StrapAlarmConfiguration) async throws -> Date? {
        let validated = try await DeviceAlarmSetupService(repository: repository).save(configuration)
        guard validated.isEnabled else {
            await turnOff()
            return nil
        }
        guard let fireDate = StrapAlarmSchedulePlanner.nextFireDate(
            for: validated,
            after: now(),
            calendar: calendar
        ) else {
            throw LooprStrapAlarmError.noOccurrence
        }
        await phoneAlarm?.prepare()
        await schedulePhoneBackup(for: fireDate)
        await arm(fireDate, reason: "saved")
        return fireDate
    }

    /// Clears both layers. Used when the alarm is switched off.
    func turnOff() async {
        try? await runtime.disableBandAlarm()
        armRecord.clear()
        await phoneAlarm?.cancel()
        BandActionLog.write("alarm turned off on the strap and on this iPhone")
    }

    /// Re-arms after the band reports that an alarm fired. A disabled or
    /// missing configuration is left alone.
    @discardableResult
    func armNextOccurrence() async throws -> Date? {
        try await reconcile()
    }

    /// Brings both layers back in line with the next planned occurrence.
    ///
    /// The band is never trusted from memory. Every pass either has fresh
    /// evidence that the band is holding the right time, a read-back that
    /// agrees or an event 56 for this arm, or it writes the alarm again. The
    /// old version compared a stored connection generation against the live
    /// one and skipped the write when they matched. Generations restart at the
    /// same value in each process, so a record written at 01:16 matched a
    /// 06:50 relaunch, nothing was written, and the 07:00 alarm never buzzed.
    @discardableResult
    func reconcile() async throws -> Date? {
        guard let configuration = try await load(), configuration.isEnabled else {
            if armRecord.read() != nil { await turnOff() }
            return nil
        }
        guard let fireDate = StrapAlarmSchedulePlanner.nextFireDate(
            for: configuration,
            after: now(),
            calendar: calendar
        ) else {
            return nil
        }

        // The iPhone layer comes first and does not depend on the band being
        // connected. It is the one that survives the app being killed.
        await schedulePhoneBackup(for: fireDate)

        guard await runtime.runtimeState().acceptsBandCommands else { return nil }
        let generation = await runtime.runtimeState().generation ?? 0
        let existing = armRecord.read()

        guard let existing, abs(existing.fireDate.timeIntervalSince(fireDate)) < 1 else {
            await arm(fireDate, reason: existing == nil ? "no arm on record" : "the next occurrence moved")
            return fireDate
        }

        let sameLink = existing.linkGeneration == generation && generation != 0
        let recentlyWritten = now().timeIntervalSince(existing.armedAt) < Self.rearmThrottle
        if sameLink, existing.isTrusted || recentlyWritten {
            return nil
        }

        let readback = try? await runtime.readBandAlarm()
        armRecord.markReadback(readback, at: now(), linkGeneration: generation)
        if let readback, abs(readback.timeIntervalSince(fireDate)) <= Self.readbackTolerance {
            BandActionLog.write("strap reads back \(Self.label(fireDate)); arming again for event 56")
        }
        if recentlyWritten, existing.confirmedByEvent { return nil }

        // A read-back that agrees is not proof: the band read back 07:00 all
        // night on 21 Sep and stayed silent. Every new link arms again and
        // waits for event 56.
        await arm(
            fireDate,
            reason: readback == nil
                ? "the strap did not read back an alarm"
                : "new link; the strap read back the time but never confirmed it"
        )
        return fireDate
    }

    /// The band said its alarm was cleared, or its clock was set. Either way
    /// the evidence is stale, so the next reconcile asks again.
    func forgetArmRecord() {
        armRecord.invalidateVerification()
    }

    /// Records event 56 for the alarm currently on file.
    func noteLatchConfirmed() {
        guard armRecord.read() != nil else { return }
        armRecord.markConfirmedByEvent(at: now())
        BandActionLog.write("strap confirmed the alarm latched; event 56")
    }

    /// The band fired. Cancel the iPhone backup so it does not go off a moment
    /// later, then line up the next occurrence.
    func noteFired(eventID: UInt16) async {
        // The band reports one fire as 57 and 58, and replays both after a
        // reconnect. Once the next occurrence is on record, a fire event
        // belongs to the alarm that already went, not to the one ahead.
        if let entry = armRecord.read(), entry.fireDate.timeIntervalSince(now()) > 120 {
            BandActionLog.write("alarm fire event \(eventID) after re-arm; ignored")
            return
        }
        BandActionLog.write("alarm fired on the strap; event \(eventID)")
        await phoneAlarm?.cancel()
        armRecord.clear()
        _ = try? await reconcile()
    }

    /// Writes the alarm to the band, then waits for the band to agree.
    ///
    /// The sequence is clear, arm, wait for event 56, read back. A band that
    /// stays silent gets one retry. After that the record says unconfirmed and
    /// the iPhone layer is what this person is relying on, which is exactly
    /// what the status screen then tells them.
    func arm(_ fireDate: Date, reason: String) async {
        for attempt in 1...2 {
            let generation = await runtime.runtimeState().generation ?? 0
            await latchSignal?.expectLatch()
            do {
                // The runtime clears the band's slot before every write.
                try await runtime.setBandAlarm(fireDate: fireDate)
            } catch {
                armRecord.write(fireDate: fireDate, armedAt: now(), linkGeneration: generation)
                armRecord.markWriteFailed()
                BandActionLog.write("alarm write failed (\(reason)): \(error)")
                return
            }
            armRecord.write(fireDate: fireDate, armedAt: now(), linkGeneration: generation)
            BandActionLog.write(
                "alarm written (\(reason)) for \(Self.label(fireDate)); attempt \(attempt)"
            )

            let latched = await latchSignal?.waitForLatch(timeout: Self.confirmationGrace) ?? false
            if latched {
                armRecord.markConfirmedByEvent(at: now())
                BandActionLog.write("strap latched the alarm; event 56 arrived")
            }

            let readback = try? await runtime.readBandAlarm()
            armRecord.markReadback(readback, at: now(), linkGeneration: generation)
            let matches = readback.map { abs($0.timeIntervalSince(fireDate)) <= Self.readbackTolerance } ?? false
            if matches { armRecord.markVerified(at: now()) }
            BandActionLog.write(
                "alarm readback=\(readback.map(Self.label) ?? "none") matches=\(matches) latched=\(latched)"
            )

            if latched { return }
            if attempt == 2 {
                BandActionLog.write("strap never confirmed the alarm; this iPhone is the wake now")
            }
        }
    }

    func plannedFireDate() async throws -> Date? {
        guard let configuration = try await load() else { return nil }
        return StrapAlarmSchedulePlanner.nextFireDate(
            for: configuration,
            after: now(),
            calendar: calendar
        )
    }

    /// When the current wake window opens, or nil when the alarm is off or set
    /// to an exact time.
    func plannedWindow() async throws -> (start: Date, end: Date)? {
        guard let configuration = try await load(), configuration.isEnabled else { return nil }
        guard let end = StrapAlarmSchedulePlanner.nextFireDate(
            for: configuration, after: now(), calendar: calendar
        ), let start = StrapAlarmSchedulePlanner.nextWindowStart(
            for: configuration, after: now(), calendar: calendar
        ) else {
            return nil
        }
        return (start, end)
    }

    /// RUN_ALARM. Both the "test alarm" button and the smart wake window use
    /// it; the band buzzes at once and reports event 58.
    func test() async throws {
        try await runtime.testBandAlarm()
    }

    func readBandAlarm() async throws -> Date? {
        try await runtime.readBandAlarm()
    }

    /// What the status screen shows. Honest by construction: nothing here says
    /// confirmed unless the band said so.
    func assurance() async -> StrapAlarmAssurance {
        let configuration = try? await load()
        let phoneBackup: StrapAlarmAssurance.PhoneBackup = phonePreference.isEnabled
            ? await phoneAlarm?.lastOutcome()?.assurance ?? .unavailable("Loopr has no backup alarm on this iPhone.")
            : .unavailable("You switched the phone alarm off, so only your band will wake you.")
        guard let configuration, configuration.isEnabled, let entry = armRecord.read() else {
            return StrapAlarmAssurance(band: .off, phoneBackup: phoneBackup)
        }
        let window = try? await plannedWindow()
        let band: StrapAlarmAssurance.BandState
        if entry.isTrusted {
            band = .confirmed
        } else if entry.writeFailed {
            band = .notArmed
        } else if now().timeIntervalSince(entry.armedAt) < Self.confirmationGrace {
            band = .waiting
        } else {
            band = .unconfirmed
        }
        return StrapAlarmAssurance(
            band: band,
            fireDate: entry.fireDate,
            lastReadbackAt: entry.lastReadbackAt,
            phoneBackup: phoneBackup,
            windowStart: window?.start
        )
    }

    private func schedulePhoneBackup(for fireDate: Date) async {
        guard let phoneAlarm else { return }
        guard phonePreference.isEnabled else {
            // Switched off on the wake alarm screen. Clear anything an earlier
            // arm left behind, once, rather than every reconcile.
            if await phoneAlarm.lastOutcome() != nil { await phoneAlarm.cancel() }
            return
        }
        let outcome = await phoneAlarm.schedule(at: fireDate)
        BandActionLog.write("phone backup for \(Self.label(fireDate)): \(outcome)")
    }

    static func label(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

/// Lets the arm sequence wait for the band's event 56 without the service
/// having to own the event stream.
///
/// Event 56 is a single notification with no retry. The band also replays its
/// buffered event log after a reconnect, so a 56 that arrives minutes after an
/// arm is history, not confirmation. Arming a fresh expectation immediately
/// before each write is what keeps those apart.
actor LooprAlarmLatchSignal {
    /// One signal per process. Event 56 arrives on one stream, and every arm
    /// path in the app must be able to wait on it.
    static let shared = LooprAlarmLatchSignal()

    private var expectedSince: Date?
    private var latchedAt: Date?

    init() {}

    func expectLatch() {
        expectedSince = Date()
        latchedAt = nil
    }

    /// Called by the band event consumer for every event 56.
    func noteLatch() {
        guard expectedSince != nil else { return }
        latchedAt = Date()
    }

    func waitForLatch(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if latchedAt != nil { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return latchedAt != nil
    }
}

// MARK: - Sleep's suggested alarm

/// Arms the strap alarm for a suggested wake time. The suggestion is a local
/// `HH:mm` label, so this turns it into the every-day configuration the strap
/// alarm service already knows how to save and arm.
struct LooprSleepSuggestedAlarmEffect: SleepSuggestedAlarmEffect {
    let service: LooprStrapAlarmService
    let runtime: any LooprDeviceCenterRuntime

    /// The suggestion is the latest wake time. It becomes the end of a smart
    /// wake window, the same model the wake alarm screen saves: the band and
    /// the phone are armed for the suggested time and Loopr may wake the
    /// person earlier in light sleep. An existing window keeps its length and
    /// an existing alarm its days; otherwise the default window, every day.
    ///
    /// This used to save an exact-time alarm with a twenty-minute "stop"
    /// window after the suggested time, which is not a wake window at all.
    func confirm(_ suggestion: SleepSuggestedAlarm) async -> SleepAlarmConfirmation {
        guard let wakeMinute = Self.minuteOfDay(suggestion.localTime) else {
            return .unavailable("Loopr could not read the suggested time \(suggestion.localTime).")
        }
        guard await runtime.runtimeState().acceptsBandCommands else {
            return .unavailable(BandActionCopy.readable(BandCommandError.notReady))
        }
        let existing = (try? await service.load()).map { WakeAlarmPlan(configuration: $0) }
        let configuration = WakeAlarmPlan(
            isEnabled: true,
            wakeMinute: wakeMinute,
            smartWindowMinutes: existing.flatMap { $0.hasSmartWindow ? $0.smartWindowMinutes : nil }
                ?? WakeAlarmPlan.defaultSmartWindowMinutes,
            weekdays: existing?.weekdays ?? WakeAlarmPlan.everyDay
        ).configuration(updatedAt: Date())
        do {
            guard try await service.save(configuration) != nil else {
                return .unavailable("Loopr saved the time but could not find the next occurrence.")
            }
            return .applied
        } catch {
            return .unavailable(BandActionCopy.readable(error))
        }
    }

    /// Parses the canonical `HH:mm` label SleepKit publishes.
    static func minuteOfDay(_ localTime: String) -> Int? {
        let parts = localTime.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}

// MARK: - Smart wake window

/// Watches the live band stream while a wake window is open and buzzes the
/// band early when the person looks like they are surfacing.
///
/// What this can and cannot do, plainly. It needs the app running and the band
/// connected, so iOS suspending Loopr ends the early wake. That costs nothing
/// that matters: the end of the window is armed on the band and scheduled on
/// this iPhone, so the person is still woken by the time they asked for. This
/// layer only ever moves a wake earlier, never later.
actor SmartWakeWatcher {
    /// How often the decision is taken. The stream is roughly 1 Hz, so this is
    /// twenty samples per decision.
    static let decisionInterval: TimeInterval = 20
    /// Samples older than this are dropped, which keeps the buffer bounded
    /// through a long window.
    static let sampleRetention: TimeInterval = 3_600

    private let runtime: any LooprDeviceCenterRuntime
    private let service: LooprStrapAlarmService
    private var task: Task<Void, Never>?
    private var activeLatest: Date?

    init(runtime: any LooprDeviceCenterRuntime, service: LooprStrapAlarmService) {
        self.runtime = runtime
        self.service = service
    }

    func start(earliest: Date, latest: Date) {
        if task != nil, activeLatest == latest { return }
        task?.cancel()
        activeLatest = latest
        BandActionLog.alarm(
            "wake window open \(LooprStrapAlarmService.label(earliest)) to \(LooprStrapAlarmService.label(latest))"
        )
        task = Task { [weak self] in
            await self?.run(window: SmartWakeWindow(earliest: earliest, latest: latest))
        }
    }

    func stop() {
        guard task != nil else { return }
        task?.cancel()
        task = nil
        activeLatest = nil
        BandActionLog.alarm("wake window watcher stopped")
    }

    private func run(window: SmartWakeWindow) async {
        guard let subscription = try? await runtime.acquireLiveEventStream(
            kind: .compactHeartRateRR,
            consumer: .other
        ) else {
            BandActionLog.alarm("wake window could not open the live stream; the end of the window still fires")
            return
        }
        defer { Task { _ = await subscription.cancel() } }

        let buffer = SmartWakeSampleBuffer()
        let collector = Task {
            for await event in subscription.stream {
                guard !Task.isCancelled, event.generation == subscription.generation else { continue }
                guard let decoded = LiveStreamEventDecoder.decodeCardiac(event) else { continue }
                let sample = decoded.sample
                guard sample.heartRate > 0 else { continue }
                await buffer.append(SmartWakeSample(
                    at: Date(timeIntervalSince1970: TimeInterval(sample.timestampSeconds)),
                    heartRateBPM: Double(sample.heartRate)
                ))
            }
        }
        defer { collector.cancel() }

        while !Task.isCancelled {
            let now = Date()
            guard now < window.latest else {
                BandActionLog.alarm("wake window closed; the armed alarm takes it from here")
                return
            }
            let samples = await buffer.samples(after: now.addingTimeInterval(-Self.sampleRetention))
            let decision = SmartWakeDetector.decide(samples: samples, window: window, now: now)
            if decision.shouldFire {
                BandActionLog.alarm("waking early: \(decision.reason)")
                do {
                    try await service.test()
                    BandActionLog.alarm("RUN_ALARM sent for the early wake")
                } catch {
                    BandActionLog.alarm("early wake RUN_ALARM failed: \(error)")
                }
                return
            }
            do { try await Task.sleep(for: .seconds(Self.decisionInterval)) } catch { return }
        }
    }
}

/// A bounded, actor-isolated sample buffer for the wake window.
actor SmartWakeSampleBuffer {
    private var stored: [SmartWakeSample] = []

    func append(_ sample: SmartWakeSample) {
        stored.append(sample)
        if stored.count > 4_096 { stored.removeFirst(stored.count - 4_096) }
    }

    func samples(after cutoff: Date) -> [SmartWakeSample] {
        stored.filter { $0.at >= cutoff }
    }
}

// MARK: - Band event consumer

/// The one app-level reader of `bandEvents()`. It turns a double tap into the
/// action the user picked and re-arms the alarm after the band fires one.
///
/// The band can report the same physical tap more than once, and the envelope
/// carries no stable identifier, so the replay fences inside the dispatchers
/// cannot see a duplicate. The window below is the guard that can.
actor BandEventActionConsumer {
    static let doubleTapEventID: UInt16 = 14
    static let clockSetEventID: UInt16 = 16
    static let alarmLatchedEventID: UInt16 = 56
    static let alarmExecutedEventIDs: Set<UInt16> = [57, 58]
    static let alarmDisabledEventID: UInt16 = 59
    static let hapticsFiredEventID: UInt16 = 60
    /// How close to the armed time event 60 has to land before it counts as
    /// the alarm firing rather than an ordinary buzz or a test.
    static let hapticsFiredWindow: TimeInterval = 120
    static let doubleTapWindow: TimeInterval = 2
    /// The band stores taps in flash and replays them on the next drain. A tap
    /// the band timestamps as older than this is history, not a person tapping
    /// now, and must not ring a phone.
    static let doubleTapRecencyWindow: TimeInterval = 6
    /// Past a day old the band timestamp is not a late tap, it is an unset RTC
    /// reporting 1971. Dropping those would throw away real taps from a band
    /// that never learned the time, so the recency check steps aside and the
    /// duplicate window alone does the work.
    static let doubleTapImplausibleAge: TimeInterval = 86_400
    /// How often the alarm is checked against the plan while the link is up.
    /// Nothing is written when nothing moved, so this is a cheap read.
    static let alarmReconcileInterval: TimeInterval = 60

    private let runtime: any LooprDeviceCenterRuntime
    private let mappingStore: LooprGestureMappingStore
    private let gestureDispatcher: DeviceGestureActionDispatcher
    private let phoneDispatcher: DevicePhoneActionDispatcher
    private let alarmService: LooprStrapAlarmService?
    private let latchSignal: LooprAlarmLatchSignal?
    private let smartWake: SmartWakeWatcher?
    private let bandStateRecorder: (any LooprBandStateRecording)?
    private var task: Task<Void, Never>?
    private var alarmTask: Task<Void, Never>?
    private var lastDoubleTapAt: Date?

    init(
        runtime: any LooprDeviceCenterRuntime,
        mappingStore: LooprGestureMappingStore,
        gestureDispatcher: DeviceGestureActionDispatcher,
        phoneDispatcher: DevicePhoneActionDispatcher,
        alarmService: LooprStrapAlarmService?,
        latchSignal: LooprAlarmLatchSignal? = .shared,
        smartWake: SmartWakeWatcher? = nil,
        bandStateRecorder: (any LooprBandStateRecording)? = nil
    ) {
        self.runtime = runtime
        self.mappingStore = mappingStore
        self.gestureDispatcher = gestureDispatcher
        self.phoneDispatcher = phoneDispatcher
        self.alarmService = alarmService
        self.latchSignal = latchSignal
        self.smartWake = smartWake
        self.bandStateRecorder = bandStateRecorder
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            for await envelope in await self.runtime.bandEvents() {
                if Task.isCancelled { return }
                await self.handle(envelope)
            }
        }
        guard alarmService != nil, alarmTask == nil else { return }
        alarmTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reconcileAlarm()
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.alarmReconcileInterval * 1_000_000_000)
                    )
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        alarmTask?.cancel()
        alarmTask = nil
        let watcher = smartWake
        Task { await watcher?.stop() }
    }

    /// Every alarm-shaped event id, named, so the morning log reads as a
    /// story rather than a list of numbers.
    static func eventName(_ id: UInt16) -> String {
        switch id {
        case 14: "double tap"
        case 16: "clock set"
        case 56: "alarm latched"
        case 57: "alarm fired (strap)"
        case 58: "alarm fired (app)"
        case 59: "alarm disabled"
        case 60: "haptics fired"
        default: "unnamed"
        }
    }

    func handle(_ envelope: BandEventEnvelope) async {
        BandActionLog.alarm("band event \(envelope.eventID) (\(Self.eventName(envelope.eventID)))")
        switch envelope.eventID {
        case BandEventID.batteryLevel, BandEventID.chargingOn, BandEventID.chargingOff,
             BandEventID.wristOn, BandEventID.wristOff, BandEventID.extendedBatteryInformation:
            await bandStateRecorder?.recordBandState(envelope)
        case Self.doubleTapEventID:
            await handleDoubleTap(envelope)
        case let id where Self.alarmExecutedEventIDs.contains(id):
            await smartWake?.stop()
            await alarmService?.noteFired(eventID: id)
        case Self.hapticsFiredEventID:
            // 60 also fires for a test buzz and for "find my strap", so it
            // only counts as the alarm when it lands near the armed time.
            guard await firedNearArmedTime(envelope) else { break }
            await smartWake?.stop()
            await alarmService?.noteFired(eventID: envelope.eventID)
        case Self.alarmLatchedEventID:
            await latchSignal?.noteLatch()
            alarmService?.noteLatchConfirmed()
        case Self.clockSetEventID:
            // A clock set moves the frame the band's armed epoch lives in and
            // may drop the alarm outright. Drop the evidence and ask again.
            BandActionLog.alarm("strap clock was set; re-verifying the alarm")
            alarmService?.forgetArmRecord()
            await reconcileAlarm()
        case Self.alarmDisabledEventID:
            // The band says it is holding no alarm. If the person still wants
            // one, forgetting what we last wrote makes the next reconcile
            // write it again instead of trusting a stale record.
            BandActionLog.alarm("strap reports its alarm was cleared")
            alarmService?.forgetArmRecord()
            await reconcileAlarm()
        default:
            break
        }
    }

    /// Re-arms the strap when the occurrence it holds is no longer the next
    /// one, and opens the smart wake window when one is due.
    ///
    /// Runs on a slow timer because the things that move the plan, an alarm
    /// firing while the phone was away and a relaunch, leave no event behind
    /// to react to.
    private func reconcileAlarm() async {
        guard let alarmService else { return }
        _ = try? await alarmService.reconcile()
        await updateSmartWake(alarmService)
    }

    /// Opens or closes the wake window watcher. It only ever runs while this
    /// process is alive and the band is connected; the window end is armed on
    /// the band and on this iPhone either way, so a suspended app costs the
    /// early wake and nothing else.
    private func updateSmartWake(_ service: LooprStrapAlarmService) async {
        guard let smartWake else { return }
        guard let window = try? await service.plannedWindow() else {
            await smartWake.stop()
            return
        }
        let now = Date()
        guard now >= window.start, now < window.end else {
            await smartWake.stop()
            return
        }
        guard await runtime.runtimeState().acceptsBandCommands else { return }
        await smartWake.start(earliest: window.start, latest: window.end)
    }

    private func firedNearArmedTime(_ envelope: BandEventEnvelope) async -> Bool {
        guard let planned = try? await alarmService?.plannedFireDate() else { return false }
        return abs(envelope.receivedAt.timeIntervalSince(planned)) <= Self.hapticsFiredWindow
    }

    private func handleDoubleTap(_ envelope: BandEventEnvelope) async {
        if let lastDoubleTapAt,
           envelope.receivedAt.timeIntervalSince(lastDoubleTapAt) < Self.doubleTapWindow {
            return
        }
        if let bandEpochSeconds = envelope.bandEpochSeconds {
            let age = envelope.receivedAt.timeIntervalSince(
                Date(timeIntervalSince1970: TimeInterval(bandEpochSeconds))
            )
            if age > Self.doubleTapRecencyWindow, age < Self.doubleTapImplausibleAge {
                BandActionLog.write("double tap ignored; the strap timestamped it \(Int(age))s ago")
                return
            }
        }
        guard let action = mappingStore.doubleTapAction() else { return }
        lastDoubleTapAt = envelope.receivedAt
        BandActionLog.write("double tap mapped to \(action.rawValue)")

        switch action {
        case .markMoment:
            // `receivedAt` is when this iPhone saw the notification. The band
            // epoch is unusable for recency because an unset RTC reports 1971.
            let event = DeviceGestureEvent(
                eventID: UUID(),
                gesture: .doubleTap,
                generation: envelope.generation,
                occurredAt: envelope.receivedAt
            )
            _ = try? await gestureDispatcher.dispatch(event, action: .markMoment)
        case .ringPhone, .torch:
            let phoneAction: DevicePhoneAction = action == .ringPhone ? .ringPhone : .torch
            let request = DevicePhoneActionRequest(
                eventID: UUID(),
                action: phoneAction,
                generation: envelope.generation,
                occurredAt: envelope.receivedAt
            )
            _ = try? await phoneDispatcher.dispatch(request)
        default:
            break
        }
    }
}

/// Builds the consumer from the shared runtime and the journal already owned
/// by production composition.
enum BandEventActionConsumerFactory {
    @MainActor
    static func make(
        runtime: any LooprDeviceCenterRuntime,
        journal: any JournalStore,
        alarmRepository: (any StrapAlarmConfigurationRepository)?,
        performer: LooprPhoneActionPerformer,
        mappingStore: LooprGestureMappingStore = LooprGestureMappingStore(),
        armRecord: LooprStrapAlarmArmRecord = LooprStrapAlarmArmRecord(),
        phoneAlarm: (any PhoneAlarmScheduling)? = nil,
        bandStateRecorder: (any LooprBandStateRecording)? = nil
    ) -> BandEventActionConsumer {
        let generationProvider = LooprRuntimeGenerationProvider(runtime: runtime)
        let gestureDispatcher = DeviceGestureActionDispatcher(
            generationProvider: generationProvider,
            capabilityProvider: StaticDeviceGestureCapabilityProvider(supportedActions: [.markMoment]),
            journalSink: LooprJournalMomentSink(journal: journal)
        )
        let phoneDispatcher = DevicePhoneActionDispatcher(
            generationProvider: generationProvider,
            capabilityProvider: StaticDevicePhoneCapabilityProvider(supportedActions: [.ringPhone, .torch]),
            sink: LooprPhoneActionSink(performer: performer)
        )
        let latchSignal = LooprAlarmLatchSignal.shared
        let alarmService = alarmRepository.map {
            LooprStrapAlarmService(
                runtime: runtime,
                repository: $0,
                armRecord: armRecord,
                phoneAlarm: phoneAlarm ?? PhoneAlarmFallback(),
                latchSignal: latchSignal
            )
        }
        return BandEventActionConsumer(
            runtime: runtime,
            mappingStore: mappingStore,
            gestureDispatcher: gestureDispatcher,
            phoneDispatcher: phoneDispatcher,
            alarmService: alarmService,
            latchSignal: latchSignal,
            smartWake: alarmService.map { SmartWakeWatcher(runtime: runtime, service: $0) },
            bandStateRecorder: bandStateRecorder
        )
    }
}

#if DEBUG
/// One typed debug command, parsed from the request file.
enum DebugAlarmCommand: Equatable, Sendable {
    /// `HH:MM`, an exact alarm, every day.
    case exact(minute: Int)
    /// `HH:MM-HH:MM`, a smart wake window, every day.
    case window(startMinute: Int, endMinute: Int)
    /// `+N`, an exact alarm N minutes from now.
    case relative(minutes: Int)
    /// `test`, RUN_ALARM (0x44).
    case runNow
    /// `disable`, DISABLE_ALARM (0x45).
    case disable
    /// `read`, GET_ALARM only.
    case read
    /// `raw:<hex>`, an arbitrary inner packet body after `[0x23][seq]`.
    case raw(Data)

    static func parse(_ text: String) -> DebugAlarmCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        switch trimmed {
        case "test": return .runNow
        case "disable": return .disable
        case "read": return .read
        default: break
        }
        if trimmed.hasPrefix("raw:") {
            guard let body = hexBody(String(trimmed.dropFirst(4))), !body.isEmpty else { return nil }
            return .raw(body)
        }
        if trimmed.hasPrefix("+") {
            guard let minutes = Int(trimmed.dropFirst()), minutes > 0 else { return nil }
            return .relative(minutes: minutes)
        }
        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard let start = LooprSleepSuggestedAlarmEffect.minuteOfDay(String(parts[0])),
                  let end = LooprSleepSuggestedAlarmEffect.minuteOfDay(String(parts[1])) else { return nil }
            return .window(startMinute: start, endMinute: end)
        }
        guard let minute = LooprSleepSuggestedAlarmEffect.minuteOfDay(trimmed) else { return nil }
        return .exact(minute: minute)
    }

    /// Accepts `2304012a`, `23 04 01 2a`, and `23:04:01:2a`.
    private static func hexBody(_ text: String) -> Data? {
        let digits = text.filter { $0.isHexDigit }
        guard digits.count % 2 == 0 else { return nil }
        var bytes = Data()
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

/// Drives alarm experiments on real hardware from the Mac.
///
/// Write one command into `Caches/loopr-debug-alarm.txt` and Loopr runs it
/// within fifteen seconds, deletes the file, and logs the outcome under
/// `[Loopr Alarm]`. The commands are listed on `DebugAlarmCommand`.
///
/// It exists because the WHOOP 4 ACKs a byte-perfect SET_ALARM, reads it back
/// correctly, and then does not buzz. Finding the byte or the ordering that
/// matters needs many attempts against one physical band, and a relaunch per
/// attempt is too slow.
enum DebugLaunchAlarm {
    static let environmentKey = "LOOPR_DEBUG_SET_ALARM"
    static let argumentPrefix = "--loopr-debug-set-alarm="
    /// How often the request file is re-read while Loopr runs.
    static let pollInterval: TimeInterval = 15

    static var requestedTime: String? {
        if let value = ProcessInfo.processInfo.environment[environmentKey] { return value }
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(argumentPrefix) }) {
            return String(argument.dropFirst(argumentPrefix.count))
        }
        // iOS relaunches Loopr for its restored Bluetooth central before a
        // developer launch can hand over arguments, so a request file copied
        // into Caches is the path that always arrives.
        guard let url = requestFileURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var requestFileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("loopr-debug-alarm.txt")
    }

    /// A launch behind the lock screen connects no scene, so the shell's task
    /// never runs. This path composes the same service without the shell and
    /// then keeps polling for the rest of the process's life.
    @MainActor
    static func runHeadless(model: BluetoothApplicationModel) async {
        BandActionLog.alarm("debug alarm headless check; requested=\(requestedTime ?? "none")")
        let environment = AppEnvironment.production()
        guard let storageURL = environment.storageURL else { return }
        var waited = 0
        var runtime: (any LooprDeviceCenterRuntime)?
        while runtime == nil, waited < 120 {
            runtime = model.heartLiveRuntime() as? any LooprDeviceCenterRuntime
            if runtime == nil { try? await Task.sleep(for: .seconds(2)); waited += 2 }
        }
        guard let runtime else {
            BandActionLog.alarm("debug alarm gave up; no shared runtime")
            return
        }
        do {
            let database = try StorageDatabase(url: storageURL, applicationVersion: environment.applicationVersion)
            let repository = try SQLiteDeviceCenterRepository(database: database)
            let service = LooprStrapAlarmService(
                runtime: runtime,
                repository: repository,
                phoneAlarm: PhoneAlarmFallback()
            )
            await poll(service: service, runtime: runtime)
        } catch {
            BandActionLog.alarm("debug alarm failed to open storage: \(error)")
        }
    }

    /// Runs one pass now, then re-reads the request file every fifteen
    /// seconds until the task is cancelled.
    static func poll(service: LooprStrapAlarmService, runtime: any LooprDeviceCenterRuntime) async {
        while !Task.isCancelled {
            await runIfRequested(service: service, runtime: runtime)
            do { try await Task.sleep(for: .seconds(pollInterval)) } catch { return }
        }
    }

    static func runIfRequested(service: LooprStrapAlarmService, runtime: any LooprDeviceCenterRuntime) async {
        guard let raw = requestedTime else { return }
        guard let command = DebugAlarmCommand.parse(raw) else {
            BandActionLog.alarm("debug alarm request not understood: \(raw)")
            consumeRequestFile()
            return
        }
        BandActionLog.alarm("debug alarm request \(raw); waiting for the band")
        var waited = 0
        while !(await runtime.runtimeState().acceptsBandCommands) {
            guard waited < 300, !Task.isCancelled else {
                BandActionLog.alarm("debug alarm gave up; band never accepted commands")
                return
            }
            try? await Task.sleep(for: .seconds(2))
            waited += 2
        }
        // The file goes now, not at the end. A command that wedges must not
        // replay on the next poll.
        consumeRequestFile()
        await run(command, service: service, runtime: runtime)
    }

    private static func run(
        _ command: DebugAlarmCommand,
        service: LooprStrapAlarmService,
        runtime: any LooprDeviceCenterRuntime
    ) async {
        switch command {
        case .runNow:
            do {
                try await service.test()
                BandActionLog.alarm("debug RUN_ALARM sent")
            } catch {
                BandActionLog.alarm("debug RUN_ALARM failed: \(error)")
            }
        case .disable:
            do {
                try await runtime.disableBandAlarm()
                service.forgetArmRecord()
                BandActionLog.alarm("debug DISABLE_ALARM sent")
            } catch {
                BandActionLog.alarm("debug DISABLE_ALARM failed: \(error)")
            }
        case .read:
            let readback = try? await service.readBandAlarm()
            BandActionLog.alarm(
                "debug GET_ALARM readback=\(readback.map { String($0.timeIntervalSince1970) } ?? "none")"
            )
        case .raw(let body):
            do {
                let response = try await runtime.sendDebugRawBandCommand(body: body, expectingOpcode: nil)
                BandActionLog.alarm(
                    "debug raw sent; response=\(response.map { String(format: "%02x", $0) }.joined())"
                )
            } catch {
                BandActionLog.alarm("debug raw failed: \(error)")
            }
        case .relative(let minutes):
            let fireDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
            await service.arm(fireDate, reason: "debug +\(minutes)m")
            BandActionLog.alarm("debug relative alarm at \(fireDate.timeIntervalSince1970)")
        case .exact(let minute):
            await save(service: service, startMinute: minute, endMinute: (minute + 20) % 1_440, mode: .exactTime)
        case .window(let start, let end):
            await save(service: service, startMinute: start, endMinute: end, mode: .wakeWindow)
        }
    }

    private static func save(
        service: LooprStrapAlarmService,
        startMinute: Int,
        endMinute: Int,
        mode: StrapAlarmMode
    ) async {
        let configuration = StrapAlarmConfiguration(
            isEnabled: true,
            startMinute: startMinute,
            endMinute: endMinute,
            weekdays: Set(AlarmWeekday.allCases),
            updatedAt: Date(),
            mode: mode
        )
        do {
            let fireDate = try await service.save(configuration)
            BandActionLog.alarm(
                "debug alarm armed (\(mode.rawValue)); fireDate=\(fireDate.map { String($0.timeIntervalSince1970) } ?? "nil")"
            )
            let readback = try? await service.readBandAlarm()
            BandActionLog.alarm(
                "debug alarm readback=\(readback.map { String($0.timeIntervalSince1970) } ?? "none")"
            )
        } catch {
            BandActionLog.alarm("debug alarm failed: \(error)")
        }
    }

    private static func consumeRequestFile() {
        guard let url = requestFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
#endif

/// Saves the user's choice and reconciles it through the shared runtime.
/// A new connection always gets a new write. A failed write remains queued.
@MainActor
@Observable
final class LooprHeartRateSharingService {
    private let runtime: any LooprDeviceCenterRuntime
    private let defaults: UserDefaults
    private let key = "band.share-heart-rate"
    private(set) var requested: Bool?
    private(set) var confirmed: Bool?
    private(set) var message = "Band state unavailable."
    private var appliedConnection: String?
    private var inFlight = false
    private var revision = 0

    init(runtime: any LooprDeviceCenterRuntime, defaults: UserDefaults = .standard) {
        self.runtime = runtime
        self.defaults = defaults
        requested = defaults.object(forKey: key) as? Bool
    }

    var enabled: Bool { requested ?? confirmed ?? false }

    func setEnabled(_ enabled: Bool) async {
        requested = enabled
        defaults.set(enabled, forKey: key)
        revision += 1
        appliedConnection = nil
        confirmed = nil
        message = "Waiting for the next connection."
        await reconcile()
    }

    func reconcile() async {
        guard !inFlight else { return }
        let state = await runtime.runtimeState()
        guard !inFlight else { return }
        guard state.acceptsBandCommands, let generation = state.generation else {
            appliedConnection = nil
            confirmed = nil
            message = requested == nil ? "Band state unavailable." : "Waiting for the next connection."
            return
        }
        let connection = "\(generation):\(String(describing: state.connection)):\(String(describing: state.bandModel))"
        guard appliedConnection != connection else { return }
        inFlight = true
        let attempt = revision
        defer { inFlight = false }
        do {
            let readback: Bool?
            if let requested {
                readback = try await runtime.setHeartRateSharing(enabled: requested)
            } else {
                readback = try await runtime.readHeartRateSharing()
            }
            let latest = await runtime.runtimeState()
            guard latest.acceptsBandCommands, latest.generation == generation, revision == attempt else { return }
            confirmed = readback
            appliedConnection = connection
            if let readback {
                message = readback ? "On, confirmed by the band." : "Off, confirmed by the band."
                if let requested, requested != readback {
                    message = readback ? "The band reports sharing is on. Try again."
                        : "The band reports sharing is off. Try again."
                }
            } else {
                message = requested == nil ? "Band state unavailable." : "Sent. This band doesn't confirm the change."
            }
        } catch {
            confirmed = nil
            if revision == attempt { appliedConnection = connection }
            message = "Couldn't confirm. Try again or reconnect."
        }
    }
}
