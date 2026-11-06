import CoachKit
import DesignSystem
import DomainKit
import Foundation
import HealthKitBridge
import JournalKit
import RoutineKit
import StorageKit
import Testing
import TodayKit
@testable import Loopr

/// LV-04 step 3: the app's loader for Today's note, rail and experiment strip, on a real `RoutineStore` and
/// `ExperimentStore` in a temporary SQLite file seeded like the DEBUG fixture. Today reads the Protocol tab's fixture
/// store, so both tabs show one protocol (ICP R2-UPG-4).
@MainActor struct TodayNoteRailLoaderTests {
    /// Tuesday 14 November 2023.
    private let day = DayIdentity(year: 2023, month: 11, day: 14)
    private let zone = TimeZone(identifier: "UTC")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2023, month: 11, day: 14, hour: hour, minute: minute))!
    }

    private final class Context {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("today-note-rail-\(UUID().uuidString)")
        let stores: ProtocolTabFixture.Stores
        init(day: DayIdentity, calendar: Calendar) throws {
            // The fixture clock: Tue 14 Nov 2023, 22:13 UTC.
            stores = try ProtocolTabFixture.makeStores(in: root, now: Date(timeIntervalSince1970: 1_700_000_000),
                                                       timeZone: calendar.timeZone)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private func loader(_ stores: ProtocolTabFixture.Stores, bedtime: Bool = false,
                        morning: MorningNoteInput? = nil) -> TodayNoteRailLoader {
        let routine = stores.routine, experiments = stores.experiments
        return TodayNoteRailLoader(sources: TodayNoteRailSources(
            readProtocol: { day, now, zone in
                try await TodayNoteRailReaders.protocolDay(store: routine, day: day, now: now, zone: zone) { day, zone, now in
                    ProtocolTabFixture.snapshots(day: day, timeZone: zone, now: now)
                }
            },
            tick: { key, day, now in try RoutineDayEvaluation(store: routine).tickOnce(ruleKey: key, day: day, at: now) != nil },
            readExperiment: { try? experiments.running() },
            readMorning: { _, _ in morning },
            bedtimeEnabled: { bedtime },
            bandName: "WHOOP 4.0"))
    }

    private func load(_ loader: TodayNoteRailLoader, hour: Int, minute: Int) async -> TodayCompanionLoad {
        await loader.load(day: day, now: at(hour, minute), calendar: calendar, isToday: true, isClockPinned: true,
                          locale: Locale(identifier: "en_GB"))
    }

    @Test func theMorningRailShowsTodaysRulesWithTheirChecksAndSources() async throws {
        let context = try Context(day: day, calendar: calendar)
        let loaded = await load(loader(context.stores), hour: 7, minute: 12)
        guard case .rules(let rules)? = loaded.content.rail else {
            Issue.record("Expected the rail")
            return
        }
        let rail = TodayRailRules.content(rules, isToday: true, mode: .morning, locale: Locale(identifier: "en_GB"))
        #expect(rail.chips.map(\.id) == ["morning-light"])
        #expect(rail.chips.allSatisfy { $0.state == .kept })
        // Version 3 swapped the daily Zone 2 for the weekly one (ICP R3-VET-05), and the blood panel was done 12 days ago
        // and is next due in three months, so Today leaves both out (ICP R3-NEW-07).
        #expect(rail.rows.map(\.id) == ["protein", "no-alcohol", "zone-2-week", "caffeine-cutoff",
                                        "kitchen-closed", "magnesium", "screens-off", "read-before-bed", "in-bed"])
        let rows = Dictionary(uniqueKeysWithValues: rail.rows.map { ($0.id, $0) })
        #expect(rows["protein"]?.detail == "82 g so far · Food checks it")
        #expect(rows["kitchen-closed"]?.detail == "By 18:30 · Food checks it")
        #expect(rows["screens-off"]?.detail == "Tap to tick")
        #expect(rows["screens-off"]?.canTick == true)
        #expect(rows["in-bed"]?.detail == "The band checks it")
        // The dial draws the same rules and checks: the Protocol tab's eleven less the blood panel, which is not due.
        #expect(loaded.protocolDay?.dialDay.rules.count == dueRules.count)
        #expect(loaded.protocolDay?.rules.map(\.key) == dueRules.map(\.key))
        #expect(loaded.protocolDay?.checks.contains { $0.ruleKey == "blood-panel" } == false)
        #expect(rail.ruleCount == dueRules.count)
    }

    /// The fixture's rules due on Tuesday: every one but the blood panel every 3 months.
    private var dueRules: [ProtocolRule] { ProtocolTabFixture.allRules.filter { $0.key != "blood-panel" } }

    /// ICP R3-NEW-07: Today asks what the deck asks. A rule done for its period drops out until it is due again; a rule
    /// with an answer today stays, so a tick never makes its row vanish.
    @Test func todayListsOnlyTheRulesTheDeckWouldAsk() throws {
        let day = DayIdentity(year: 2023, month: 11, day: 14)
        let panel = ProtocolRule(key: "panel", title: "Blood panel", cadence: RuleCadence(unit: .month, every: 3))
        let walk = ProtocolRule(key: "walk", title: "Walk", cadence: .timesAWeek(2))
        let read = ProtocolRule(key: "read", title: "Read before bed")
        func check(_ key: RuleKey, _ on: DayIdentity, _ state: CheckState) throws -> RuleCheck {
            try RuleCheck(ruleKey: key, day: on, version: 1, state: state, source: .manual, recordedAt: Date(timeIntervalSince1970: 0))
        }
        let early = try [check("panel", DayIdentity(year: 2023, month: 11, day: 2), .kept)]
        let due = try TodayNoteRailReaders.dueRules([panel, walk, read], checks: [check("walk", day, .pending)], day: day,
                                                    keptThisWeek: ["walk": 2]) { rule in rule.key == "panel" ? early : [] }
        #expect(due.map(\.key) == ["read"], "The panel waits for February and the walk was kept twice this week")
        let tickedToday = try TodayNoteRailReaders.dueRules([panel], checks: [check("panel", day, .kept)], day: day,
                                                            keptThisWeek: [:]) { _ in try [check("panel", day, .kept)] + early }
        #expect(tickedToday.map(\.key) == ["panel"], "Kept today, so it stays on the list as kept")
        let neverDone = try TodayNoteRailReaders.dueRules([panel], checks: [], day: day, keptThisWeek: [:]) { _ in [] }
        #expect(neverDone.map(\.key) == ["panel"], "A rule never done is due")
    }

    /// ICP R2-UPG-4: Today's rail and the Protocol tab read one fixture store, so they list the same rules, count the
    /// same kept rules, and a tick on Today is the Protocol tab's answer too.
    @Test func todaysRailAndTheProtocolTabCountOneProtocol() async throws {
        let context = try Context(day: day, calendar: calendar)
        let now = at(22, 13), zone = zone, gb = Locale(identifier: "en_GB")
        let protocolTab = ProtocolTabLoader(store: context.stores.routine, timeZone: { zone },
                                            snapshots: { day, zone, now in ProtocolTabFixture.snapshots(day: day, timeZone: zone, now: now) },
                                            locale: gb)
        let loaded = await load(loader(context.stores), hour: 22, minute: 13)
        guard case .rules(let rules)? = loaded.content.rail else {
            Issue.record("Expected the rail")
            return
        }
        let data = try #require(await protocolTab.load(now: now).routineData)
        // Today leaves out the blood panel, which is not due (ICP R3-NEW-07), and so does the Protocol day (ICP R4 Q3):
        // both list the same rules and say 10.
        #expect(rules.map(\.key) == data.rules.filter { $0.key != "blood-panel" }.map(\.key.rawValue))
        let todayInput = try #require(data.countedToday)
        #expect(todayInput.rules.map(\.rule.key.rawValue) == rules.map(\.key))
        let rosette = ProtocolDayPresentation.make(todayInput, week: ProtocolWeekCalendar(timeZone: zone, locale: gb))
        let rail = TodayRailRules.content(rules, isToday: true, mode: .evening, locale: gb)
        #expect(rail.ruleCount == ProtocolTabFixture.allRules.count - 1)
        #expect(rail.ruleCount == rosette.total)
        #expect(rosette.total == 10)
        #expect(rail.keptCount == rosette.kept)
        #expect(rail.summary == "\(rosette.kept) of \(rosette.total) rules kept")
        let sheet = try #require(ProtocolDayRules.content(for: day, routine: data, calendar: ProtocolWeekCalendar(timeZone: zone, locale: gb)))
        #expect(sheet.rows.count == rail.ruleCount)
        #expect(sheet.notDue == "Not due today: Blood panel, next in February.")

        #expect(await loader(context.stores).tick("magnesium", day: day, now: now))
        let after = try #require(await protocolTab.load(now: now).routineData?.todayInput)
        #expect(after.rules.first { $0.rule.key == "magnesium" }?.state == .kept)
    }

    /// ICP R2-NEW-2: only the populated fixture seeds a protocol. A launch that starts with onboarding, pairing or an
    /// empty install meets the Protocol tab's templates, as a fresh install does.
    @Test func onlyThePopulatedFixtureSeedsAProtocol() {
        #expect(!ProtocolTabFixture.startsEmpty(composition: .populated, arguments: []))
        #expect(ProtocolTabFixture.startsEmpty(composition: .populated, arguments: [ProtocolTabFixture.emptyArgument]))
        for composition in [AppEnvironment.Composition.onboarding, .pairing, .empty, .stale, .disconnected] {
            #expect(ProtocolTabFixture.startsEmpty(composition: composition, arguments: []), "\(composition)")
        }
    }

    @Test func theEveningNoteComesFromTheRulesAndNeverQuotesTheRebuttal() async throws {
        let context = try Context(day: day, calendar: calendar)
        let loaded = await load(loader(context.stores), hour: 19, minute: 49)
        let evening = try #require(loaded.content.evening)
        #expect(evening.text.hasPrefix("Kitchen closed at 12:30. That is 2 of 2 days this week. Still to come before bed: "),
                "\(evening.text)")
        #expect(!evening.text.contains("news"))
        #expect(evening.chips.map(\.action) == [.startWindDown, .ask])
        // The bedtime activity is off, so the note leaves Start wind-down to the first-evening card.
        #expect(loaded.content.note(for: .evening)?.card?.chips.map(\.action) == [])
        #expect(loaded.content.showsFirstEvening(for: .evening))
        let on = await load(loader(context.stores, bedtime: true), hour: 19, minute: 49)
        #expect(on.content.note(for: .evening)?.card?.chips.map(\.action) == [.startWindDown])
        #expect(!on.content.showsFirstEvening(for: .evening))
    }

    @Test func theRunningExperimentShowsTonightsNightAndArm() async throws {
        let context = try Context(day: day, calendar: calendar)
        let loaded = await load(loader(context.stores), hour: 7, minute: 12)
        let strip = try #require(loaded.content.experiment)
        #expect(strip.progress == "Night 9 of 14")
        #expect(strip.title == "Magnesium glycinate, 300 mg")
        #expect(strip.detail == "Outcome: deep sleep. Tonight is a magnesium night.")
        #expect(strip.beads.count == 14)
        #expect(strip.beads.filter { $0.phase == .past }.count == 8)
        #expect(strip.beads[8].phase == .tonight)
    }

    @Test func theOnNightLineFollowsTheSchedule() throws {
        let start = try ExperimentStart(protocolID: ProtocolID(), title: "Magnesium before bed", interventionName: "magnesium",
                                        ruleKey: "magnesium", design: .alternatingDays, washout: 0, minimumNightsPerArm: 7,
                                        plannedNights: 14, outcome: .deepSleep, startDay: day.adding(days: -8)!,
                                        timeZoneIdentifier: "UTC", createdAt: at(9, 0))
        let experiment = Experiment(start: start)
        #expect(TodayNoteRailMapping.experimentInput(experiment, tonight: day)?.tonight == "Tonight is a magnesium night.")
        let tomorrow = try #require(TodayNoteRailMapping.experimentInput(experiment, tonight: day.adding(days: 1)!))
        #expect(tomorrow.night == 10)
        #expect(tomorrow.tonight == "Tonight is an off night. No magnesium.")
        // Outside the plan, and once it has finished, there is no strip at all.
        #expect(TodayNoteRailMapping.experimentInput(experiment, tonight: day.adding(days: 6)!) == nil)
        #expect(TodayNoteRailMapping.experimentInput(Experiment(start: start, status: .finished, endDay: day), tonight: day) == nil)
    }

    @Test func aManualTickWritesOnceAndASecondHoldWritesNothing() async throws {
        let context = try Context(day: day, calendar: calendar)
        let loader = loader(context.stores)
        let protocolID = try #require(try context.stores.routine.activeProtocol()?.routineProtocol.id)
        #expect(await loader.tick("screens-off", day: day, now: at(21, 50)))
        let first = try #require(try context.stores.routine.check(protocolID: protocolID, ruleKey: "screens-off", day: day))
        #expect(first.state == .kept && first.source == .manual)
        #expect(await loader.tick("screens-off", day: day, now: at(22, 5)))
        let second = try #require(try context.stores.routine.check(protocolID: protocolID, ruleKey: "screens-off", day: day))
        #expect(second == first)
        // A rule a source checks cannot be ticked.
        #expect(await loader.tick("in-bed", day: day, now: at(22, 5)) == false)

        let loaded = await load(loader, hour: 22, minute: 6)
        guard case .rules(let rules)? = loaded.content.rail else {
            Issue.record("Expected the rail")
            return
        }
        let row = TodayRailRules.content(rules, isToday: true, mode: .evening).rows.first { $0.id == "screens-off" }
        #expect(row?.state == .kept)
        #expect(row?.canTick == false)
        #expect(row?.detail == "Ticked")
        // The dial's bead for the rule turns kept too.
        let bead = loaded.protocolDay.map { TodayDialInputMapping.rules($0.dialDay) }?.first { $0.key == "screens-off" }
        #expect(bead?.state == .kept)
    }

    @Test func theRailAndTheBedtimeActivityShowTheEveningRulesInTheSameOrder() async throws {
        let context = try Context(day: day, calendar: calendar)
        let loaded = await load(loader(context.stores), hour: 19, minute: 49)
        let protocolDay = try #require(loaded.protocolDay)
        let rail = TodayRailRules.ordered(TodayNoteRailMapping.railRules(protocolDay))
            .filter { $0.isEvening && $0.metric != RoutineMetric.inBedTime.rawValue }.map(\.key)
        let evening = try #require(BedtimeActivityWindow.evening(startingOn: at(12, 0), bedtimeMinute: 22 * 60 + 30, calendar: calendar))
        let steps = BedtimeActivitySteps.steps(rules: protocolDay.rules, checks: protocolDay.checks, evening: evening, calendar: calendar)
        #expect(rail == steps.map(\.id))
        #expect(rail == ["kitchen-closed", "magnesium", "screens-off", "read-before-bed"])
    }

    @Test func withoutAProtocolTheRailSaysWhereRulesComeFrom() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("today-note-rail-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(database: try StorageDatabase(url: root.appendingPathComponent("routine.sqlite"), applicationVersion: "test"))
        let loader = TodayNoteRailLoader(sources: TodayNoteRailSources(
            readProtocol: { day, now, zone in
                try await TodayNoteRailReaders.protocolDay(store: store, day: day, now: now, zone: zone) { _, _, _ in RoutineSourceSnapshots() }
            }))
        let loaded = await load(loader, hour: 7, minute: 12)
        #expect(loaded.content.rail == .noProtocol)
        #expect(loaded.content.evening == nil)
        #expect(loaded.content.experiment == nil)
        // No reader at all leaves the rail out.
        let none = await load(TodayNoteRailLoader(sources: TodayNoteRailSources()), hour: 7, minute: 12)
        #expect(none.content.rail == nil)
        #expect(none.content.morning == nil)
    }

    @Test func theMorningSlotIsLearningUntilTheUsualHasItsNights() async throws {
        let context = try Context(day: day, calendar: calendar)
        let few = MorningNoteInput(lastNight: NightOutcome(kind: .sleepHeartRate, value: 49, day: day),
                                   usual: NoteUsual(median: 52, nights: 3, windowDays: 30))
        let loaded = await load(loader(context.stores, morning: few), hour: 7, minute: 12)
        #expect(loaded.content.morning == .learning(have: 3, need: 7))
        #expect(loaded.morningNote == nil)

        let fixture = TodayNoteRailFixture.morningInput(today: day, outcomes: [:])
        let note = await load(loader(context.stores, morning: fixture), hour: 7, minute: 12)
        let card = try #require(note.content.morning?.card)
        #expect(card.text.hasPrefix("Sleep heart rate was 49 bpm last night"))
        #expect(card.receipt?.groups.map(\.nightCount) == [20, 9])
        #expect(card.chips.map(\.label) == ["Why 49?", "All 29 nights"])
        #expect(card.sources.first?.provenance == .band(device: "WHOOP 4.0"))
    }

    // MARK: One fixture history (LV-04 step 5)

    @Test func theFixtureReadoutTheDialAndTheNoteReadTheSameNights() async throws {
        let history = TodayFixtureMetricHistory(day: day, calendar: calendar)
        let sources = TodayDialSources(readHistory: { key, days, end in try await history.series(for: key, days: days, endingOn: end) },
                                       bandName: "WHOOP 4.0")
        let inputs = try #require(await sources.inputs(day: day, now: at(7, 12), calendar: calendar, recovery: nil,
                                                       locale: Locale(identifier: "en_GB")))
        // The dial reads last night and the 28 nights before it from the fixture series. Sun 12 Nov, the fixture's day
        // without band data, has no night in it either.
        #expect(inputs.sleepHeartRate.value == 49)
        #expect(inputs.sleepHeartRateBefore.count == 28)
        let model = try #require(TodayDialModel(inputs))
        let readout = try #require(model.readouts.first { $0.id == .sleepHeartRate })
        #expect(readout.text == "49")
        #expect(readout.caption == "4 under usual")

        // The note reads the same series through the same seam and says the same two numbers.
        let input = await TodayNoteRailFixture.morning(day: day, calendar: calendar, history: history)
        #expect(input.lastNight?.value == 49)
        #expect(input.usual?.median == 53)
        #expect(input.usual?.nights == inputs.sleepHeartRateBefore.count)
        let writer = CoachNoteWriter(context: NoteContext(locale: Locale(identifier: "en_GB"), calendar: calendar))
        let card = try #require(TodayNoteCards.morning(input, writer: writer).state.card)
        #expect(card.text.hasPrefix("Sleep heart rate was 49 bpm last night, 4 bpm below your usual over the previous 28 nights."))
        #expect(card.text.contains("averaged 5 bpm lower"))
        // The receipt's nights are the dial's nights: last night plus the 28 before it.
        let receipt = try #require(card.receipt)
        #expect(receipt.groups.map(\.nightCount) == [20, 9])
        #expect(card.chips.map(\.label) == ["Why 49?", "All 29 nights"])
        let receiptValues = receipt.groups.flatMap(\.values).sorted()
        #expect(receiptValues == (inputs.sleepHeartRateBefore + [49]).sorted())

        // Other metrics come from the metric pages' fixture series, without the fixture's empty day (R1-NEW-4).
        let steps = try await history.series(for: .steps, days: 7, endingOn: at(12, 0))
        let pages = try await FixtureMetricHistoryProvider(calendar: calendar).series(for: .steps, days: 7, endingOn: at(12, 0))
            .filter { !TodayNoteRailFixture.isEmptyFixtureDay(TodayNoteRailMapping.day($0.day, calendar: calendar), fixtureDay: day) }
        #expect(steps == pages)
    }

    @Test func theTimelinesNowFollowsTheFixtureClock() throws {
        var perth = Calendar(identifier: .gregorian)
        perth.timeZone = TimeZone(identifier: "Australia/Perth")!
        for (argument, minute) in [("morning", 7 * 60 + 12), ("evening", 19 * 60 + 49), ("noon", 13 * 60 + 30)] {
            let arguments = ["--loopr-today-clock=\(argument)"]
            let now = try #require(TodayAgentLoader.fixtureNow(day: day, calendar: perth, arguments: arguments))
            let parts = perth.dateComponents([.year, .month, .day, .hour, .minute], from: now)
            #expect(parts.year == 2023 && parts.month == 11 && parts.day == 14, "\(argument)")
            #expect((parts.hour ?? 0) * 60 + (parts.minute ?? 0) == minute, "\(argument)")
            // The dial pins the same wall-clock minute.
            #expect(TodayDialFixtureClock.minuteOfDay(arguments: arguments) == minute)
        }
        let unpinned = try #require(TodayAgentLoader.fixtureNow(day: day, calendar: perth, arguments: []))
        #expect(perth.component(.hour, from: unpinned) == 13 && perth.component(.minute, from: unpinned) == 30)
    }

    @Test func theFixturesDayWithoutBandDataHasNoNightInTheReadoutOrTheNote() async throws {
        let empty = try #require(day.adding(days: -2))
        let history = TodayFixtureMetricHistory(day: day, calendar: calendar)
        let sources = TodayDialSources(readHistory: { key, days, end in try await history.series(for: key, days: days, endingOn: end) })
        let inputs = try #require(await sources.inputs(day: empty, now: at(7, 12), calendar: calendar, recovery: nil))
        #expect(inputs.sleepHeartRate.value == nil)
        let model = try #require(TodayDialModel(inputs))
        let readout = try #require(model.readouts.first { $0.id == .sleepHeartRate })
        #expect(readout.text == nil)
        let input = await TodayNoteRailFixture.morning(day: empty, calendar: calendar, history: history)
        #expect(input.lastNight == nil)
        let writer = CoachNoteWriter(context: NoteContext(locale: Locale(identifier: "en_GB"), calendar: calendar))
        #expect(TodayNoteCards.morning(input, writer: writer).state == .absent)
    }

    @Test func theFixtureSuppliesTimeInDaylightOnItsDaysWithData() throws {
        let start = calendar.startOfDay(for: at(12, 0))
        let daylight = TodayFixtureAppleHealth.read(.daylight, dayStart: start, fixtureDay: day, calendar: calendar)
        guard case .dailyTotal(let minutes, let provenance) = TodayDialInputMapping.daylight(daylight, dayKey: TodayDialSources.dayKey(day)) else {
            Issue.record("Expected a daylight total")
            return
        }
        #expect(minutes == 22)
        #expect(provenance == .appleHealth(source: "Apple Watch"))
        var inputs = TodayDialInputs(day: day, now: at(7, 12), calendar: calendar)
        inputs.daylight = .dailyTotal(minutes: minutes, provenance: provenance)
        let model = try #require(TodayDialModel(inputs))
        #expect(model.daylight.absence == nil)
        // The fixture's day without band data has no daylight either.
        let empty = try #require(calendar.date(byAdding: .day, value: -2, to: start))
        #expect(TodayFixtureAppleHealth.read(.daylight, dayStart: empty, fixtureDay: day, calendar: calendar) == .absent(.noSamples))
    }
}
