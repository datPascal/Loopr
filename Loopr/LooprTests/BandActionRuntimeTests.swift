import AnalyticsKit
import BluetoothKit
import DeviceCenterKit
import DomainKit
import Foundation
import JournalKit
import SleepKit
import SyncKit
import Testing
@testable import Loopr

@MainActor
struct BandActionRuntimeTests {
    @Test
    func doubleTapMappingRoundTripsAndRejectsUnsupportedActions() {
        let defaults = UserDefaults(suiteName: "band-action-mapping-\(UUID().uuidString)")!
        let store = LooprGestureMappingStore(defaults: defaults)

        #expect(store.doubleTapAction() == nil)

        store.setDoubleTapAction(.ringPhone)
        #expect(store.doubleTapAction() == .ringPhone)
        #expect(LooprGestureMappingStore(defaults: defaults).doubleTapAction() == .ringPhone)

        store.setDoubleTapAction(nil)
        #expect(store.doubleTapAction() == nil)

        // Only the three iPhone-side actions are offered. A stored value from
        // anywhere else reads back as nothing rather than dispatching.
        defaults.set(DeviceAction.manualSync.rawValue, forKey: LooprGestureMappingStore.doubleTapKey)
        #expect(store.doubleTapAction() == nil)
    }

    @Test
    func doubleTapMarksAMomentInTheJournal() async throws {
        let journal = RecordingJournalStore()
        let runtime = BandActionTestRuntime()
        let consumer = makeConsumer(runtime: runtime, journal: journal, action: .markMoment)

        await consumer.handle(runtime.envelope(eventID: 14))

        let entries = await journal.entries
        #expect(entries.count == 1)
        #expect(entries.first?.note == LooprJournalMomentSink.note)
    }

    @Test
    func repeatedDoubleTapsWithinTheWindowRunOnce() async throws {
        let journal = RecordingJournalStore()
        let runtime = BandActionTestRuntime()
        let consumer = makeConsumer(runtime: runtime, journal: journal, action: .markMoment)
        let first = runtime.envelope(eventID: 14)

        await consumer.handle(first)
        // The band can report one physical tap more than once, and the
        // envelope carries no identifier the dispatchers could fence on.
        await consumer.handle(runtime.envelope(eventID: 14, at: first.receivedAt.addingTimeInterval(0.4)))

        #expect(await journal.entries.count == 1)
    }

    @Test
    func aDoubleTapMappedToNothingDoesNothing() async throws {
        let journal = RecordingJournalStore()
        let runtime = BandActionTestRuntime()
        let consumer = makeConsumer(runtime: runtime, journal: journal, action: nil)

        await consumer.handle(runtime.envelope(eventID: 14))

        #expect(await journal.entries.isEmpty)
    }

    @Test
    func otherBandEventsNeverReachTheJournal() async throws {
        let journal = RecordingJournalStore()
        let runtime = BandActionTestRuntime()
        let consumer = makeConsumer(runtime: runtime, journal: journal, action: .markMoment)

        await consumer.handle(runtime.envelope(eventID: 60))

        #expect(await journal.entries.isEmpty)
    }

    @Test
    func anAlarmFiredEventReArmsTheNextOccurrence() async throws {
        let runtime = BandActionTestRuntime()
        let repository = InMemoryDeviceCenterRepository(
            alarmConfiguration: StrapAlarmConfiguration(
                isEnabled: true,
                startMinute: 7 * 60,
                endMinute: 7 * 60 + 30,
                weekdays: [.monday, .thursday]
            )
        )
        let consumer = makeConsumer(
            runtime: runtime,
            journal: RecordingJournalStore(),
            action: nil,
            alarmRepository: repository
        )

        await consumer.handle(runtime.envelope(eventID: 57))

        let armed = await runtime.alarmFireDates
        #expect(armed.count == 1)
        // The band holds one absolute time, so a fired alarm has to be
        // followed by the next occurrence.
        #expect(armed.allSatisfy { $0 > Date() })

        // The band reports 57 and 58 for the same fire, and a reconnect
        // repeats the check. Only a moved occurrence is worth a second write.
        await consumer.handle(runtime.envelope(eventID: 58))
        #expect(await runtime.alarmFireDates.count == 1)
    }

    @Test
    func aRelaunchArmsTheStrapWithoutWaitingForTheUser() async throws {
        let runtime = BandActionTestRuntime()
        let repository = InMemoryDeviceCenterRepository(
            alarmConfiguration: StrapAlarmConfiguration(
                isEnabled: true,
                startMinute: 6 * 60,
                endMinute: 6 * 60 + 20,
                weekdays: Set(AlarmWeekday.allCases)
            )
        )
        // No arm record: exactly the state a fresh launch reads, and the state
        // left behind by an alarm that fired while Loopr was closed.
        let service = LooprStrapAlarmService(
            runtime: runtime,
            repository: repository,
            armRecord: isolatedArmRecord()
        )

        let armed = try await service.reconcile()

        #expect(armed != nil)
        #expect(await runtime.alarmFireDates.count == 1)
        // Nothing moved, so the second pass writes nothing.
        #expect(try await service.reconcile() == nil)
        #expect(await runtime.alarmFireDates.count == 1)
    }

    @Test
    func aNewLinkRewritesTheAlarmBecauseTheBandMayHaveLostIt() async throws {
        let runtime = BandActionTestRuntime()
        let repository = InMemoryDeviceCenterRepository(
            alarmConfiguration: StrapAlarmConfiguration(
                isEnabled: true,
                startMinute: 6 * 60,
                endMinute: 6 * 60 + 20,
                weekdays: Set(AlarmWeekday.allCases)
            )
        )
        let record = isolatedArmRecord()
        let service = LooprStrapAlarmService(runtime: runtime, repository: repository, armRecord: record)

        let armed = try #require(try await service.reconcile())
        // Same occurrence, different link. The band is a new connection and
        // Loopr cannot read back whether it still holds the alarm.
        record.write(
            fireDate: armed,
            armedAt: Date().addingTimeInterval(-3_600),
            linkGeneration: BandActionTestRuntime.generation &- 1
        )

        #expect(try await service.reconcile() != nil)
        #expect(await runtime.alarmFireDates.count == 2)
    }

    @Test
    func aRelaunchReArmsEvenThoughTheGenerationMatches() async throws {
        // The bug that cost a 07:00 wake. Generation numbers restart at the
        // same value in every process, so a record written before a crash
        // matched the fresh link and reconcile wrote nothing.
        let runtime = BandActionTestRuntime()
        let repository = InMemoryDeviceCenterRepository(
            alarmConfiguration: StrapAlarmConfiguration(
                isEnabled: true,
                startMinute: 7 * 60,
                endMinute: 7 * 60 + 30,
                weekdays: Set(AlarmWeekday.allCases)
            )
        )
        let record = isolatedArmRecord()
        let service = LooprStrapAlarmService(runtime: runtime, repository: repository, armRecord: record)
        let configuration = try #require(try await repository.readAlarmConfiguration())
        let fireDate = try #require(
            StrapAlarmSchedulePlanner.nextFireDate(
                for: configuration,
                after: Date(),
                calendar: .autoupdatingCurrent
            )
        )
        // Exactly the stale record the old process left: right occurrence,
        // matching generation, written hours ago, never verified.
        record.write(
            fireDate: fireDate,
            armedAt: Date().addingTimeInterval(-6 * 3_600),
            linkGeneration: BandActionTestRuntime.generation
        )

        #expect(try await service.reconcile() != nil)
        #expect(await runtime.alarmFireDates.count == 1)
    }

    @Test
    func aWakeWindowArmsTheEndAndReportsTheStart() async throws {
        let runtime = BandActionTestRuntime()
        let repository = InMemoryDeviceCenterRepository()
        let service = LooprStrapAlarmService(
            runtime: runtime,
            repository: repository,
            armRecord: isolatedArmRecord()
        )

        let armed = try #require(try await service.save(StrapAlarmConfiguration(
            isEnabled: true,
            startMinute: 6 * 60 + 30,
            endMinute: 7 * 60,
            weekdays: Set(AlarmWeekday.allCases),
            mode: .wakeWindow
        )))

        // The promise is the end of the window, never the start.
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: armed)
        #expect(components.hour == 7)
        #expect(components.minute == 0)

        let window = try #require(try await service.plannedWindow())
        #expect(window.end.timeIntervalSince(window.start) == 30 * 60)
    }

    @Test
    func anAlarmWrittenToAnOfflineBandStillLeavesAPhoneBackup() async throws {
        let runtime = OfflineBandTestRuntime()
        let repository = InMemoryDeviceCenterRepository()
        let phone = RecordingPhoneAlarm()
        let service = LooprStrapAlarmService(
            runtime: runtime,
            repository: repository,
            armRecord: isolatedArmRecord(),
            phoneAlarm: phone
        )

        let armed = try await service.save(StrapAlarmConfiguration(
            isEnabled: true,
            startMinute: 6 * 60,
            endMinute: 6 * 60 + 20,
            weekdays: Set(AlarmWeekday.allCases)
        ))

        // The band refused every write, and the person is still woken.
        #expect(armed != nil)
        #expect(await phone.scheduled == [armed].compactMap { $0 })
        let assurance = await service.assurance()
        #expect(assurance.band == .notArmed)
        #expect(assurance.phoneBackup == .systemAlarm)
    }

    @Test
    func debugRequestsParseIntoTheCommandsTheHardwareScriptSends() {
        #expect(DebugAlarmCommand.parse("test") == .runNow)
        #expect(DebugAlarmCommand.parse("disable") == .disable)
        #expect(DebugAlarmCommand.parse("read") == .read)
        #expect(DebugAlarmCommand.parse("+12") == .relative(minutes: 12))
        #expect(DebugAlarmCommand.parse("07:00") == .exact(minute: 420))
        #expect(DebugAlarmCommand.parse("06:30-07:00") == .window(startMinute: 390, endMinute: 420))
        #expect(DebugAlarmCommand.parse("raw:42 04 00") == .raw(Data([0x42, 0x04, 0x00])))
        #expect(DebugAlarmCommand.parse("half past seven") == nil)
        #expect(DebugAlarmCommand.parse("raw:abc") == nil)
    }

    @Test
    func aTapTheBandReplaysFromFlashNeverRunsAnAction() async throws {
        let journal = RecordingJournalStore()
        let runtime = BandActionTestRuntime()
        let consumer = makeConsumer(runtime: runtime, journal: journal, action: .markMoment)
        let now = Date()
        let stale = BandEventEnvelope(
            eventID: 14,
            generation: BandActionTestRuntime.generation,
            receivedAt: now,
            bandEpochSeconds: UInt32(now.addingTimeInterval(-600).timeIntervalSince1970)
        )

        await consumer.handle(stale)
        #expect(await journal.entries.isEmpty)

        // A band whose clock was never set reports 1971. That is not a late
        // tap, so the recency check has to step aside rather than drop it.
        let unsetClock = BandEventEnvelope(
            eventID: 14,
            generation: BandActionTestRuntime.generation,
            receivedAt: now,
            bandEpochSeconds: 60
        )
        await consumer.handle(unsetClock)
        #expect(await journal.entries.count == 1)
    }

    @Test
    func aDisabledAlarmIsNotReArmed() async throws {
        let runtime = BandActionTestRuntime()
        let repository = InMemoryDeviceCenterRepository(
            alarmConfiguration: StrapAlarmConfiguration(isEnabled: false)
        )
        let consumer = makeConsumer(
            runtime: runtime,
            journal: RecordingJournalStore(),
            action: nil,
            alarmRepository: repository
        )

        await consumer.handle(runtime.envelope(eventID: 57))

        #expect(await runtime.alarmFireDates.isEmpty)
    }

    @Test
    func savingAnAlarmPersistsItAndArmsTheBand() async throws {
        let runtime = BandActionTestRuntime()
        let repository = InMemoryDeviceCenterRepository()
        let service = LooprStrapAlarmService(runtime: runtime, repository: repository)
        let configuration = StrapAlarmConfiguration(
            isEnabled: true,
            startMinute: 6 * 60 + 30,
            endMinute: 7 * 60,
            weekdays: [.wednesday]
        )

        let armed = try await service.save(configuration)

        #expect(armed != nil)
        #expect(await runtime.alarmFireDates == [armed].compactMap { $0 })
        #expect(try await repository.readAlarmConfiguration()?.isEnabled == true)
    }

    @Test
    func turningAnAlarmOffClearsItOnTheBand() async throws {
        let runtime = BandActionTestRuntime()
        let repository = InMemoryDeviceCenterRepository()
        let service = LooprStrapAlarmService(runtime: runtime, repository: repository)

        let armed = try await service.save(StrapAlarmConfiguration(isEnabled: false))

        #expect(armed == nil)
        #expect(await runtime.alarmFireDates.isEmpty)
        #expect(await runtime.disableCount == 1)
    }

    private func makeConsumer(
        runtime: BandActionTestRuntime,
        journal: RecordingJournalStore,
        action: DeviceAction?,
        alarmRepository: (any StrapAlarmConfigurationRepository)? = nil
    ) -> BandEventActionConsumer {
        let defaults = UserDefaults(suiteName: "band-action-consumer-\(UUID().uuidString)")!
        let mappingStore = LooprGestureMappingStore(defaults: defaults)
        mappingStore.setDoubleTapAction(action)
        return BandEventActionConsumerFactory.make(
            runtime: runtime,
            journal: journal,
            alarmRepository: alarmRepository,
            performer: LooprPhoneActionPerformer(),
            mappingStore: mappingStore,
            armRecord: LooprStrapAlarmArmRecord(defaults: defaults),
            // The real fallback asks AlarmKit for authorization, which never
            // answers inside a test process.
            phoneAlarm: RecordingPhoneAlarm()
        )
    }

    /// Each test needs its own suite: the arm record outlives a process by
    /// design, which is the whole point of it.
    private func isolatedArmRecord() -> LooprStrapAlarmArmRecord {
        LooprStrapAlarmArmRecord(
            defaults: UserDefaults(suiteName: "band-action-alarm-\(UUID().uuidString)")!
        )
    }
}

/// Records the semantic band calls without standing up a transport.
extension BandActionRuntimeTests {
    /// Changed on purpose: the suggestion used to save an exact-time alarm
    /// at the suggested time with a twenty-minute "stop" window after it. It
    /// is now the latest edge of a smart wake window, the model the wake
    /// alarm screen saves, so the guaranteed buzz is still the suggested time.
    @Test
    func confirmingASuggestedAlarmArmsTheStrapForThatTime() async throws {
        let runtime = BandActionTestRuntime()
        let repository = InMemoryDeviceCenterRepository()
        let effect = LooprSleepSuggestedAlarmEffect(
            service: LooprStrapAlarmService(runtime: runtime, repository: repository),
            runtime: runtime
        )
        let suggestion = SleepSuggestedAlarm(
            localTime: "07:30", reason: "Protect the suggested sleep opportunity.", source: "test"
        )

        #expect(await effect.confirm(suggestion) == .applied)

        let saved = try #require(await repository.readAlarmConfiguration())
        #expect(saved.isEnabled)
        #expect(saved.mode == .wakeWindow)
        #expect(saved.guaranteedMinute == 7 * 60 + 30)
        #expect(saved.endMinute == 7 * 60 + 30)
        #expect(saved.startMinute == 7 * 60 + 30 - WakeAlarmPlan.defaultSmartWindowMinutes)
        #expect(saved.weekdays.count == 7)
        let armed = await runtime.alarmFireDates
        #expect(armed.count == 1)
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: try #require(armed.first))
        #expect(components.hour == 7)
        #expect(components.minute == 30)
    }

    @Test
    func aSuggestionKeepsAnExistingWindowLengthAndDays() async throws {
        let runtime = BandActionTestRuntime()
        let repository = InMemoryDeviceCenterRepository(
            alarmConfiguration: WakeAlarmPlan(
                isEnabled: true, wakeMinute: 6 * 60, smartWindowMinutes: 10, weekdays: [.monday]
            ).configuration()
        )
        let effect = LooprSleepSuggestedAlarmEffect(
            service: LooprStrapAlarmService(runtime: runtime, repository: repository, armRecord: isolatedArmRecord()),
            runtime: runtime
        )

        #expect(await effect.confirm(SleepSuggestedAlarm(localTime: "07:15", reason: "", source: "test")) == .applied)

        let saved = try #require(await repository.readAlarmConfiguration())
        #expect(saved.guaranteedMinute == 7 * 60 + 15)
        #expect(saved.windowMinutes == 10)
        #expect(saved.weekdays == [.monday])
    }

    @Test
    func anUnreadableTimeOrASleepingStrapSaysSoInsteadOfClaimingAnAlarm() async throws {
        let ready = BandActionTestRuntime()
        let readyEffect = LooprSleepSuggestedAlarmEffect(
            service: LooprStrapAlarmService(runtime: ready, repository: InMemoryDeviceCenterRepository()),
            runtime: ready
        )
        let garbled = SleepSuggestedAlarm(localTime: "half past seven", reason: "", source: "test")
        #expect(await readyEffect.confirm(garbled) == .unavailable("Loopr could not read the suggested time half past seven."))
        #expect(await ready.alarmFireDates.isEmpty)

        let offline = OfflineBandTestRuntime()
        let offlineEffect = LooprSleepSuggestedAlarmEffect(
            service: LooprStrapAlarmService(runtime: offline, repository: InMemoryDeviceCenterRepository()),
            runtime: offline
        )
        let suggestion = SleepSuggestedAlarm(localTime: "07:30", reason: "", source: "test")
        #expect(await offlineEffect.confirm(suggestion)
            == .unavailable(BandActionCopy.readable(BandCommandError.notReady)))
    }

    @Test
    func theBatteryForecastOnlyBecomesANumberWhenTheBandIsActuallyDraining() {
        let hour: Int64 = 3_600
        #expect(DeviceCenterRuntimeProjection.batteryForecast(nil).isAbsent)
        // A run too short to fit a rate abstains, and so does the projection.
        #expect(DeviceCenterRuntimeProjection.batteryForecast(
            .abstain(reason: ForecastNote.needHistory(2, 4))
        ).isAbsent)

        let draining = AnalyticsKit.BatteryForecast(
            samplesUsed: 16, spanUsed: .seconds(14 * hour), drainPctPerHour: 2, currentPct: 60
        )
        guard case .measured(let forecast) = DeviceCenterRuntimeProjection.batteryForecast(draining) else {
            Issue.record("A measured drain rate should produce a forecast")
            return
        }
        #expect(forecast.hoursRemaining == 30)
        #expect(forecast.confidence == .high)

        let thin = AnalyticsKit.BatteryForecast(
            samplesUsed: 5, spanUsed: .seconds(3 * hour), drainPctPerHour: 4, currentPct: 40
        )
        guard case .measured(let low) = DeviceCenterRuntimeProjection.batteryForecast(thin) else {
            Issue.record("A short but usable run should still produce a forecast")
            return
        }
        #expect(low.confidence == .low)
    }
}

/// Stands in for AlarmKit so the fallback can be asserted without a device.
private actor RecordingPhoneAlarm: PhoneAlarmScheduling {
    private(set) var scheduled: [Date] = []
    private(set) var cancelCount = 0
    private var outcome: PhoneAlarmOutcome?

    func prepare() async {}

    @discardableResult
    func schedule(at fireDate: Date) async -> PhoneAlarmOutcome {
        scheduled.append(fireDate)
        outcome = .systemAlarm
        return .systemAlarm
    }

    func cancel() async {
        cancelCount += 1
        outcome = nil
    }

    func lastOutcome() async -> PhoneAlarmOutcome? { outcome }
}

/// A strap that is paired but not in range. Every band command must refuse.
private actor OfflineBandTestRuntime: LooprDeviceCenterRuntime {
    func acquireLiveStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamConsumerHandle {
        throw HeartLiveStreamAdapterError.unavailable
    }

    func bufferedLiveSamples(for kind: LiveStreamKind) async -> [LiveStreamSample] { [] }

    func runtimeState() async -> BluetoothAdoptionRuntimeState {
        BluetoothAdoptionRuntimeState(
            running: false,
            generation: nil,
            connection: .idle,
            setupReady: false,
            setupComplete: false,
            radioState: .poweredOn,
            health: ConnectionHealthReport(
                healthy: false, stale: true, shouldBounce: false,
                ageOfLatestObservation: nil, corruptionRate: 0, reasons: []
            ),
            pendingReconnect: nil,
            liveConsumerCount: 0,
            pendingHistoryReplayCount: 0,
            validFrameCount: 0,
            corruptFrameCount: 0,
            writeTimeoutCount: 0,
            lastError: nil
        )
    }

    func performManualSync(maxDuration: TimeInterval) async -> Bool { false }
}

private actor BandActionTestRuntime: LooprDeviceCenterRuntime {
    static let generation: UInt64 = 7

    private(set) var alarmFireDates: [Date] = []
    private(set) var disableCount = 0

    nonisolated func envelope(eventID: UInt16, at date: Date = Date()) -> BandEventEnvelope {
        BandEventEnvelope(
            eventID: eventID,
            generation: Self.generation,
            receivedAt: date,
            bandEpochSeconds: nil
        )
    }

    func acquireLiveStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamConsumerHandle {
        throw HeartLiveStreamAdapterError.unavailable
    }

    func bufferedLiveSamples(for kind: LiveStreamKind) async -> [LiveStreamSample] { [] }

    func runtimeState() async -> BluetoothAdoptionRuntimeState {
        BluetoothAdoptionRuntimeState(
            running: true,
            generation: Self.generation,
            connection: .listening(
                generation: Self.generation,
                peripheral: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
            ),
            setupReady: true,
            setupComplete: true,
            radioState: .poweredOn,
            health: ConnectionHealthReport(
                healthy: true,
                stale: false,
                shouldBounce: false,
                ageOfLatestObservation: 1,
                corruptionRate: 0,
                reasons: []
            ),
            pendingReconnect: nil,
            liveConsumerCount: 0,
            pendingHistoryReplayCount: 0,
            validFrameCount: 4,
            corruptFrameCount: 0,
            writeTimeoutCount: 0,
            lastError: nil,
            bondRepairRequired: nil
        )
    }

    func performManualSync(maxDuration: TimeInterval) async -> Bool { true }

    func setBandAlarm(fireDate: Date) async throws {
        alarmFireDates.append(fireDate)
        // The fake band latches at once, like a band that answers event 56.
        await LooprAlarmLatchSignal.shared.noteLatch()
    }

    func disableBandAlarm() async throws {
        disableCount += 1
    }
}

private actor RecordingJournalStore: JournalStore {
    private(set) var entries: [JournalEntry] = []

    func save(_ entry: JournalEntry) async throws -> JournalEntry {
        entries.append(entry)
        return entry
    }

    func create(
        day: String,
        behaviors: Set<String>,
        tags: Set<String>,
        note: String?,
        id: UUID?,
        now: Date
    ) async throws -> JournalEntry {
        try await save(JournalEntry(
            id: id ?? UUID(),
            day: day,
            behaviors: behaviors,
            tags: tags,
            note: note,
            createdAt: now
        ))
    }

    func edit(id: UUID, behaviors: Set<String>?, tags: Set<String>?, note: String??, now: Date) async throws -> JournalEntry {
        throw JournalError.missingEntry
    }

    func entry(id: UUID) async -> JournalEntry? {
        entries.first { $0.id == id }
    }

    func history(descending: Bool) async -> [JournalEntry] { entries }
    func search(_ query: JournalSearchQuery) async -> [JournalEntry] { entries }
    func delete(id: UUID) async throws { entries.removeAll { $0.id == id } }
    func export(includeContent: Bool) async -> JournalExport {
        JournalExport(entries: entries, includesJournalContent: includeContent)
    }
    func approve(_ proposal: JournalProposal) async {}
    func saveProposal(_ proposal: JournalProposal, accepted: Bool, now: Date) async throws -> JournalEntry? { nil }
    func redactedSnapshot() async -> JournalPrivacyPayload { JournalPrivacyPayload() }
    func deleteAll() async { entries.removeAll() }
}

// MARK: - Wake alarm screen controller

extension BandActionRuntimeTests {
    private func isolatedPreference() -> LooprPhoneAlarmPreference {
        LooprPhoneAlarmPreference(defaults: UserDefaults(suiteName: "wake-alarm-phone-\(UUID().uuidString)")!)
    }

    @Test
    func thePhoneLayerIsOnUntilSomeoneSwitchesItOff() {
        let preference = isolatedPreference()
        #expect(preference.isEnabled)
        preference.setEnabled(false)
        #expect(!preference.isEnabled)
    }

    @Test
    func savingWithTheBandAwaySetsThePhoneAlarmAndLeavesTheBandForLater() async throws {
        let runtime = OfflineBandTestRuntime()
        let repository = InMemoryDeviceCenterRepository()
        let phone = RecordingPhoneAlarm()
        let controller = LooprWakeAlarmController(
            runtime: runtime, repository: repository, phoneAlarm: phone, preference: isolatedPreference(),
            armRecord: isolatedArmRecord()
        )

        let wake = try #require(try await controller.save(
            WakeAlarmPlan(isEnabled: true, wakeMinute: 6 * 60 + 45, smartWindowMinutes: 20)
        ))

        let saved = try #require(await repository.readAlarmConfiguration())
        #expect(saved.mode == .wakeWindow)
        #expect(saved.guaranteedMinute == 6 * 60 + 45)
        #expect(saved.windowMinutes == 20)
        #expect(await phone.scheduled == [wake])

        let snapshot = await controller.snapshot()
        #expect(snapshot.band == .notConnected)
        #expect(snapshot.phone == .systemAlarm)
        #expect(!snapshot.bandConnected)
    }

    @Test
    func savingWithTheBandConnectedHandsTheWriteToTheArmSequence() async throws {
        let runtime = BandActionTestRuntime()
        let repository = InMemoryDeviceCenterRepository()
        let controller = LooprWakeAlarmController(
            runtime: runtime, repository: repository, phoneAlarm: RecordingPhoneAlarm(), preference: isolatedPreference(),
            armRecord: isolatedArmRecord()
        )

        let wake = try #require(try await controller.save(WakeAlarmPlan(isEnabled: true, wakeMinute: 7 * 60)))

        // The write runs in the background so the screen does not wait on
        // the band's confirmation grace.
        for _ in 0..<50 where await runtime.alarmFireDates.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await runtime.alarmFireDates == [wake])
    }

    @Test
    func switchingThePhoneLayerOffCancelsItAndSavesSkipIt() async throws {
        let repository = InMemoryDeviceCenterRepository()
        let phone = RecordingPhoneAlarm()
        let preference = isolatedPreference()
        let controller = LooprWakeAlarmController(
            runtime: OfflineBandTestRuntime(), repository: repository, phoneAlarm: phone, preference: preference,
            armRecord: isolatedArmRecord()
        )
        try await controller.save(WakeAlarmPlan(isEnabled: true, wakeMinute: 7 * 60))
        #expect(await phone.scheduled.count == 1)

        await controller.setPhoneLayerEnabled(false)
        #expect(await phone.cancelCount >= 1)
        #expect(!preference.isEnabled)

        try await controller.save(WakeAlarmPlan(isEnabled: true, wakeMinute: 7 * 60 + 5))
        #expect(await phone.scheduled.count == 1)
        #expect(await controller.snapshot().phone == .disabled)

        await controller.setPhoneLayerEnabled(true)
        #expect(await phone.scheduled.count == 2)
    }

    @Test
    func turningOffKeepsTheTimeButClearsBothLayers() async throws {
        let runtime = BandActionTestRuntime()
        let repository = InMemoryDeviceCenterRepository()
        let phone = RecordingPhoneAlarm()
        let controller = LooprWakeAlarmController(
            runtime: runtime, repository: repository, phoneAlarm: phone, preference: isolatedPreference(),
            armRecord: isolatedArmRecord()
        )
        try await controller.save(WakeAlarmPlan(isEnabled: true, wakeMinute: 6 * 60 + 10, smartWindowMinutes: 0))

        try await controller.turnOff()

        let saved = try #require(await repository.readAlarmConfiguration())
        #expect(!saved.isEnabled)
        #expect(saved.guaranteedMinute == 6 * 60 + 10)
        #expect(await runtime.disableCount >= 1)
        #expect(await phone.cancelCount >= 1)
        #expect(await controller.snapshot().band == .off)
    }

    @Test
    func aConfirmationForTheOldTimeDoesNotCountForANewOne() async throws {
        let repository = InMemoryDeviceCenterRepository()
        let record = isolatedArmRecord()
        let controller = LooprWakeAlarmController(
            runtime: OfflineBandTestRuntime(), repository: repository, phoneAlarm: RecordingPhoneAlarm(),
            preference: isolatedPreference(), armRecord: record
        )
        // Yesterday's alarm, confirmed by the band with event 56.
        record.write(fireDate: Date().addingTimeInterval(3_600), armedAt: Date(), linkGeneration: 1)
        record.markConfirmedByEvent(at: Date())

        try await controller.save(WakeAlarmPlan(isEnabled: true, wakeMinute: 5 * 60 + 17))

        #expect(await controller.snapshot().band == .notConnected)
    }

    @Test
    func testBuzzAndRetryRefuseWithoutABand() async throws {
        let controller = LooprWakeAlarmController(
            runtime: OfflineBandTestRuntime(),
            repository: InMemoryDeviceCenterRepository(),
            phoneAlarm: RecordingPhoneAlarm(),
            preference: isolatedPreference(),
            armRecord: isolatedArmRecord()
        )
        await #expect(throws: BandCommandError.notReady) { try await controller.testBuzz() }
        await #expect(throws: BandCommandError.notReady) { try await controller.retryBand() }
    }

    @Test
    func aStoreWithNoRuntimeStillSetsThePhoneAlarm() async throws {
        let phone = RecordingPhoneAlarm()
        let controller = LooprWakeAlarmController(
            runtime: nil,
            repository: InMemoryDeviceCenterRepository(),
            phoneAlarm: phone,
            preference: isolatedPreference(),
            armRecord: isolatedArmRecord()
        )
        let wake = try await controller.save(WakeAlarmPlan(isEnabled: true, wakeMinute: 8 * 60))
        #expect(wake != nil)
        #expect(await phone.scheduled.count == 1)
        #expect(await controller.snapshot().band == .notConnected)
    }

    @Test
    func theFixtureControllerConfirmsWithoutTouchingHardware() async throws {
        let fixture = FixtureWakeAlarmController(seed: .empty, confirmationDelay: .milliseconds(50))
        #expect(await fixture.snapshot().configuration == nil)

        try await fixture.save(WakeAlarmPlan(isEnabled: true, wakeMinute: 7 * 60))
        #expect(await fixture.snapshot().band == .waiting)
        for _ in 0..<40 where await fixture.snapshot().band == .waiting {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(await fixture.snapshot().band == .confirmed)
        #expect(await fixture.snapshot().phone == .systemAlarm)

        try await fixture.turnOff()
        #expect(await fixture.snapshot().band == .off)
        #expect(await fixture.snapshot().isOn == false)
    }

    @Test
    func savingAnAlarmRestartsConfirmationPolling() async throws {
        let fixture = FixtureWakeAlarmController(seed: .empty, confirmationDelay: .seconds(30))
        let idle = WakeAlarmPollingCadence(band: await fixture.snapshot().band)
        try await fixture.save(WakeAlarmPlan(isEnabled: true, wakeMinute: 7 * 60))
        let waiting = WakeAlarmPollingCadence(band: await fixture.snapshot().band)

        // The cadence is the SwiftUI task identity. Changing it cancels a
        // pending idle sleep as soon as save publishes the waiting snapshot.
        #expect(idle != waiting)
        #expect(idle.interval == .seconds(15))
        #expect(waiting.interval == .seconds(2))
        #expect(waiting != WakeAlarmPollingCadence(band: .confirmed))
    }

    @Test
    func fixtureSeedsCoverTheScreenshotStates() async {
        #expect(await FixtureWakeAlarmController(seed: .confirmed).snapshot().band == .confirmed)
        #expect(await FixtureWakeAlarmController(seed: .unconfirmed).snapshot().band == .notConfirmed)
        #expect(await FixtureWakeAlarmController(seed: .disconnected).snapshot().band == .notConnected)
        #expect(FixtureWakeAlarmController.Seed.fromLaunchArguments(["--loopr-wake-alarm-fixture=set"]) == .set)
        #expect(FixtureWakeAlarmController.Seed.fromLaunchArguments([]) == .empty)
    }

    @Test
    func settingsShowsTheWakeTimeOrOff() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let formatter = WakeAlarmFormatter(calendar: calendar, locale: Locale(identifier: "en_GB"))
        let on = WakeAlarmSnapshot(
            configuration: WakeAlarmPlan(isEnabled: true, wakeMinute: 6 * 60 + 30).configuration(),
            assurance: nil, phoneLayerEnabled: true, bandConnected: false
        )
        #expect(on.settingsSummary(formatter: formatter) == "06:30")
        let off = WakeAlarmSnapshot(configuration: nil, assurance: nil, phoneLayerEnabled: true, bandConnected: false)
        #expect(off.settingsSummary(formatter: formatter) == "Off")
    }
}
