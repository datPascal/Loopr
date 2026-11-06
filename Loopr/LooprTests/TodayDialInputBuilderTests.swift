import BodyKit
import DesignSystem
import DeviceCenterKit
import DomainKit
import FoodKit
import Foundation
import HealthKitBridge
import RoutineKit
import SleepKit
import Testing
import TodayKit
import WorkoutKit
@testable import Loopr

nonisolated private let zone = TimeZone(identifier: "Europe/Berlin")!
nonisolated private let day = DayIdentity(year: 2026, month: 10, day: 22)
nonisolated private let locale = Locale(identifier: "en_GB")

nonisolated private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
}

nonisolated private func at(_ day: DayIdentity, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute))!
}

nonisolated private func shifted(_ days: Int) -> DayIdentity {
    let date = calendar.date(byAdding: .day, value: days, to: at(day, 12))!
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return DayIdentity(year: parts.year!, month: parts.month!, day: parts.day!)
}

nonisolated private func label(_ day: DayIdentity) -> String { String(format: "%04d-%02d-%02d", day.year, day.month, day.day) }

/// Last night 22:30 to 06:18. The trend holds it and the seven nights before, each 22:30 to 06:30.
nonisolated private func snapshot() -> SleepDaySnapshot {
    let main = SleepSessionSummary(id: "night", start: at(shifted(-1), 22, 30), end: at(day, 6, 18), durationMinutes: 468,
                                   isMainSleep: true, isPartial: false, confidence: 0.9, state: .partial)
    let trend = (0...7).map { back -> SleepTrendPoint in
        let night = shifted(-back)
        return SleepTrendPoint(id: label(night), localDay: label(night), value: 8, state: .partial, unit: "hours",
                               start: at(shifted(-back - 1), 22, 30), end: at(night, 6, 30))
    }
    return SleepDaySnapshot(day: day, state: .partial, mainSleep: main, metrics: [],
                            hypnogram: [SleepSegment(id: 0, stage: .light, durationMinutes: 30), SleepSegment(id: 1, stage: .deep, durationMinutes: 0),
                                        SleepSegment(id: 2, stage: .deep, durationMinutes: 60)],
                            trend: trend, source: "test")
}

nonisolated private func item(_ source: FoodCaptureSource) -> FoodItem {
    FoodItem(name: "Item", amount: 1, unit: .serving, provenance: [FoodProvenance(source: source, recordedAt: at(day, 7))])
}

nonisolated private func workout(_ state: WorkoutLifecycleState, source: WorkoutSource = .manual, start: Date? = at(day, 17, 30),
                     end: Date? = at(day, 18, 18)) -> WorkoutRecord {
    WorkoutRecord(id: UUID(), identity: WorkoutIdentity(canonicalKey: "w-\(UUID())"), activity: .cycle, source: source,
                  state: state, createdAt: at(day, 17), startedAt: start, endedAt: end)
}

nonisolated private func healthSample(_ kind: AppleHealthSourceKind, _ value: Double, on day: DayIdentity) -> AppleHealthSample {
    AppleHealthSample(kind: kind, value: value, original: AppleHealthOriginalReading(value: value, unit: kind.storeUnit),
                      start: at(day, 0), end: at(day, 19), localDay: label(day),
                      provenance: AppleHealthProvenance(sourceName: "Apple Watch"))
}

/// The dial's app-side builder: each store maps onto the dial's plain inputs, with fakes for every reader.
struct TodayDialInputBuilderTests {
    @Test
    func lastNightMapsTheMainSleepAndItsStageSpans() throws {
        let night = try #require(TodayDialInputMapping.night(snapshot(), provenance: .band(device: "WHOOP 4.0")))
        #expect(night.start == at(shifted(-1), 22, 30))
        #expect(night.end == at(day, 6, 18))
        #expect(night.asleepMinutes == 468)
        // The zero-length segment is skipped, the others are laid end to end.
        #expect(night.spans.map(\.stage) == [.light, .deep])
        #expect(night.spans[1].start == at(shifted(-1), 23))
        #expect(night.spans[1].end == at(day, 0))
        #expect(night.provenance == .band(device: "WHOOP 4.0"))

        let empty = SleepDaySnapshot(day: day, state: .absent, mainSleep: nil, metrics: [], source: "test")
        #expect(TodayDialInputMapping.night(empty, provenance: .band(device: "")) == nil)
    }

    @Test
    func mealsCarryTheirFirstPhotoAndHowTheyWereLogged() {
        let id = UUID(), photo = UUID()
        let meal = TodayDialInputMapping.meal(id: id, slot: .dinner, at: at(day, 18, 20), photo: (id: photo, fileName: "\(photo).jpg"),
                                              items: [item(.typed)])
        #expect(meal.id == id.uuidString.lowercased())
        #expect(meal.title == "Dinner")
        #expect(meal.at == at(day, 18, 20))
        #expect(meal.sticker == TodayDialSticker(photoID: photo, fileName: "\(photo).jpg"))
        #expect(meal.provenance == .food(.logged))
        #expect(TodayDialInputMapping.meal(id: id, slot: .lunch, at: at(day, 12), photo: nil, items: [item(.typed)]).sticker == nil)

        #expect(TodayDialInputMapping.foodSource([item(.typed), item(.photoAI)]) == .photoEstimate)
        #expect(TodayDialInputMapping.foodSource([item(.typed), item(.barcode)]) == .barcode)
        #expect(TodayDialInputMapping.foodSource([item(.voice), item(.label)]) == .logged)
    }

    @Test
    func finishedAndRunningWorkoutsMapAndTheRestStayOff() {
        let mapped = TodayDialInputMapping.workouts([
            workout(.completed), workout(.active, source: .live, end: nil), workout(.discarded),
            workout(.completed, start: nil), workout(.interruptedAndRecoverable)
        ], bandName: "WHOOP 4.0")
        #expect(mapped.count == 2)
        #expect(mapped[0].title == "Cycling" && mapped[0].end == at(day, 18, 18) && mapped[0].provenance == .typedIn)
        #expect(mapped[1].end == nil && mapped[1].provenance == .band(device: "WHOOP 4.0"))
    }

    @Test
    func appleHealthTotalsKeepTheirSourceAndAbsencesKeepTheirReason() {
        let key = TodayDialSources.dayKey(day)
        #expect(key == "2026-10-22")
        #expect(TodayDialInputMapping.daylight(.values([healthSample(.daylight, 34, on: day)]), dayKey: key)
            == .dailyTotal(minutes: 34, provenance: .appleHealth(source: "Apple Watch")))
        #expect(TodayDialInputMapping.daylight(.values([healthSample(.daylight, 34, on: shifted(-1))]), dayKey: key) == .missing(.noData))
        #expect(TodayDialInputMapping.daylight(.absent(.switchedOff), dayKey: key) == .missing(.switchedOff))
        #expect(TodayDialInputMapping.daylight(.absent(.notAuthorized), dayKey: key) == .missing(.notAllowed))
        #expect(TodayDialInputMapping.dailyTotal(.absent(.noSamples), dayKey: key) == .missing(.noData))
        #expect(TodayDialInputMapping.dailyTotal(.absent(.queryFailed("locked")), dayKey: key) == .missing(.unavailable))
        #expect(TodayDialInputMapping.dailyTotal(.values([healthSample(.steps, 9_812, on: day)]), dayKey: key)
            == .value(9_812, .appleHealth(source: "Apple Watch")))
    }

    @Test
    func zone2AndHistoryReadTheBandsDay() throws {
        #expect(TodayDialInputMapping.zone2([BodyZoneMinutes(id: 1, name: "Zone 1", minutes: 30), BodyZoneMinutes(id: 2, name: "Zone 2", minutes: 48)],
                                            bandName: "WHOOP 4.0") == .value(48, .band(device: "WHOOP 4.0")))
        #expect(TodayDialInputMapping.zone2(nil, bandName: "") == .missing(.noData))
        #expect(TodayDialInputMapping.zone2([BodyZoneMinutes(id: 1, name: "Zone 1", minutes: 30)], bandName: "") == .missing(.noData))

        let clock = try #require(TodayDialClock(day: day, calendar: calendar))
        let points = (0...6).reversed().map { back in
            MetricHistoryPoint(day: calendar.startOfDay(for: at(shifted(-back), 12)), value: back == 0 ? 49 : 53, source: .band)
        }
        let heart = TodayDialInputMapping.sleepHeartRate(points, clock: clock, bandName: "WHOOP 4.0")
        #expect(heart.reading == .value(49, .band(device: "WHOOP 4.0")))
        #expect(heart.before == Array(repeating: 53, count: 6))
        #expect(TodayDialInputMapping.today(Array(points.dropLast()), clock: clock, bandName: "") == .missing(.noData))
        #expect(TodayDialInputMapping.today([MetricHistoryPoint(day: clock.start, value: 91, source: .appleHealth)], clock: clock,
                                            bandName: "") == .value(91, .appleHealth(source: "")))
    }

    @Test
    func rulesCarryTheirMetricLimitAndTodaysCheck() throws {
        let kitchen = ProtocolRule(key: "kitchen", title: "Kitchen closes", group: .food,
                                   target: RuleTarget(kind: .atMost, metric: "last_meal_time", value: 1_110), timeOfDayMinutes: 1_080,
                                   source: .food, isEvening: true)
        let screens = ProtocolRule(key: "screens-off", title: "Screens off", timeOfDayMinutes: 1_305, isEvening: true)
        let check = try RuleCheck(ruleKey: "kitchen", day: day, version: 1, state: .kept, source: .food, recordedAt: at(day, 19))
        let rules = TodayDialInputMapping.rules(TodayDialProtocolDay(rules: [kitchen, screens], checks: [check]))
        #expect(rules == [
            TodayDialRuleInput(key: "kitchen", title: "Kitchen closes", metric: "last_meal_time", timeOfDayMinutes: 1_080, targetValue: 1_110,
                               isEvening: true, source: .food, state: .kept),
            TodayDialRuleInput(key: "screens-off", title: "Screens off", timeOfDayMinutes: 1_305, isEvening: true, source: .manual,
                               state: .unknown)
        ])
    }

    @Test
    func theAlarmMapsOnlyWhileItIsOn() {
        let plan = WakeAlarmPlan(isEnabled: true, wakeMinute: 390, smartWindowMinutes: 20, weekdays: WakeAlarmPlan.everyDay)
        #expect(TodayDialInputMapping.alarm(plan, weekday: 5)
            == TodayDialAlarmInput(wakeMinuteOfDay: 390, smartWindowMinutes: 20, ringsToday: true, ringsTomorrow: true))
        var off = plan
        off.isEnabled = false
        #expect(TodayDialInputMapping.alarm(off, weekday: 5) == nil)
        #expect(TodayDialInputMapping.alarm(nil, weekday: 5) == nil)
    }

    @Test
    func theBuilderAssemblesEveryReaderIntoTheDial() async throws {
        let protocolDay = TodayDialProtocolDay(rules: [
            ProtocolRule(key: "in-bed", title: "In bed", group: .sleep, target: RuleTarget(kind: .atMost, metric: "in_bed_time", value: 1_350),
                         source: .band),
            ProtocolRule(key: "screens-off", title: "Screens off", timeOfDayMinutes: 1_305, isEvening: true)
        ], checks: [])
        let sources = TodayDialSources(
            readSleep: { requested in requested == day ? snapshot() : nil },
            readSleepGoalMinutes: { 480 },
            readHistory: { key, _, _ in
                switch key {
                case .sleepingHeartRate: [MetricHistoryPoint(day: calendar.startOfDay(for: at(day, 12)), value: 49, source: .band)]
                case .sleepConsistency: [MetricHistoryPoint(day: calendar.startOfDay(for: at(day, 12)), value: 91, source: .band)]
                default: []
                }
            },
            readMeals: nil,
            readWorkouts: { [workout(.completed)] },
            readAppleHealth: { kind, _, _ in
                kind == .daylight ? .values([healthSample(.daylight, 34, on: day)]) : .absent(.switchedOff)
            },
            readZoneMinutes: { _ in [BodyZoneMinutes(id: 2, name: "Zone 2", minutes: 48)] },
            readProtocol: { _, _, _ in protocolDay },
            readAlarm: { WakeAlarmPlan(isEnabled: true, wakeMinute: 375, smartWindowMinutes: 0, weekdays: WakeAlarmPlan.everyDay) },
            bandName: "WHOOP 4.0")

        let inputs = try #require(await sources.inputs(day: day, now: at(day, 19, 49), calendar: calendar, recovery: nil, locale: locale))
        #expect(inputs.lastNight?.asleepMinutes == 468)
        #expect(inputs.recentNights.count == 14)
        #expect(inputs.recentNights.last?.bedMinuteAfterNoon == 630)
        #expect(inputs.tonight?.wakeMinuteOfDay == 390)
        #expect(inputs.sleepHeartRate == .value(49, .band(device: "WHOOP 4.0")))
        #expect(inputs.regularity == .value(91, .band(device: "WHOOP 4.0")))
        #expect(inputs.recoveryProvenance == .band(device: "WHOOP 4.0"))
        #expect(inputs.meals.isEmpty)
        #expect(inputs.workouts.count == 1)
        #expect(inputs.daylight == .dailyTotal(minutes: 34, provenance: .appleHealth(source: "Apple Watch")))
        #expect(inputs.steps == .missing(.switchedOff))
        #expect(inputs.zone2Minutes == .value(48, .band(device: "WHOOP 4.0")))
        #expect(inputs.rules.map(\.key) == ["in-bed", "screens-off"])
        #expect(inputs.alarm == TodayDialAlarmInput(wakeMinuteOfDay: 375, ringsToday: true, ringsTomorrow: true))

        let model = try #require(TodayDialModel(inputs))
        #expect(model.mode == .evening)
        guard case .countdown(let countdown) = model.centre else {
            Issue.record("Expected the bedtime countdown")
            return
        }
        #expect(countdown.text == "2:41")
        #expect(countdown.caption == "until bed at 22:30")
        #expect(model.readouts.map(\.text) == [nil, "48", nil])
        #expect(model.alarm?.isTomorrow == true)
    }

    @Test
    func withNoStoresTheDialIsEmptyAndSaysSo() async throws {
        let inputs = try #require(await TodayDialSources().inputs(day: day, now: at(day, 7, 12), calendar: calendar, recovery: nil,
                                                                  locale: locale))
        #expect(inputs.lastNight == nil)
        #expect(inputs.daylight == .missing(.unavailable))
        #expect(inputs.steps == .missing(.unavailable))
        #expect(inputs.sleepHeartRate == .missing(.noData))
        let model = try #require(TodayDialModel(inputs))
        #expect(model.render.kind == .empty)
        #expect(model.hand != nil)
    }

    @Test
    func aPastDayReadsNoTonightAndNoAlarm() async throws {
        let sources = TodayDialSources(
            readSleep: { _ in snapshot() },
            readAlarm: { WakeAlarmPlan(isEnabled: true, wakeMinute: 375, weekdays: WakeAlarmPlan.everyDay) })
        let inputs = try #require(await sources.inputs(day: day, now: at(shifted(2), 9), calendar: calendar, recovery: nil, locale: locale))
        #expect(inputs.lastNight != nil)
        #expect(inputs.tonight == nil)
        #expect(inputs.alarm == nil)
    }
}
