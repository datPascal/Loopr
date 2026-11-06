import DomainKit
import Foundation

public enum JournalAutoFillQuestion: String, Codable, CaseIterable, Sendable {
    case alcohol
    case lateCaffeine = "late_caffeine"
    case lateMeal = "meal_within_two_hours"
    case trainedToday = "trained_today"

    public var domain: JournalAutoFillDomain { self == .trainedToday ? .train : .food }
    public var period: HabitQuestionPeriod { self == .trainedToday ? .today : .evening }

    public func accepts(_ definition: HabitDefinition) -> Bool {
        definition.source == .preset(catalogID: rawValue)
            && definition.question == HabitCatalog.byID[rawValue]?.question
            && definition.checkInPeriod == period
    }
}

public enum JournalAutoFillDomain: String, Codable, Sendable {
    // The raw values are stored with saved answers, so "Train" stays. `title` is what the person reads.
    case food = "Food", train = "Train", sleep = "Sleep"

    /// The tab that fills the answer, named as DEC-12.1 names it.
    public var title: String { self == .train ? "Fitness" : rawValue }
}

public struct JournalSourceRecord: Codable, Equatable, Sendable {
    public let id: String
    public let domain: JournalAutoFillDomain
    public let title: String
    public let occurredAt: Date
    public let updatedAt: Date
    public var isValid: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && occurredAt.timeIntervalSince1970.isFinite && updatedAt.timeIntervalSince1970.isFinite
    }

    public init(id: String, domain: JournalAutoFillDomain, title: String, occurredAt: Date, updatedAt: Date) {
        self.id = id; self.domain = domain; self.title = title; self.occurredAt = occurredAt; self.updatedAt = updatedAt
    }
}

public struct JournalAutoFillProvenance: Codable, Equatable, Sendable {
    public let question: JournalAutoFillQuestion
    public let records: [JournalSourceRecord]
    public let summary: String
    public var domain: JournalAutoFillDomain { question.domain }
    public var isValid: Bool {
        !records.isEmpty && !summary.isEmpty && Set(records.map(\.id)).count == records.count
            && records.allSatisfy(\.isValid)
            && records.allSatisfy { $0.domain == domain || (question == .lateMeal && $0.domain == .sleep) }
            && (question != .lateMeal || records.contains { $0.domain == .sleep })
            && records.contains { $0.domain == domain }
    }

    public init(question: JournalAutoFillQuestion, records: [JournalSourceRecord], summary: String) {
        self.question = question
        self.records = records.sorted { $0.id < $1.id }
        self.summary = summary
    }
}

public struct JournalAutoFillAnswer: Equatable, Sendable {
    public let answer: HabitAnswer
    public let provenance: JournalAutoFillProvenance
    public init(_ answer: HabitAnswer, provenance: JournalAutoFillProvenance) {
        self.answer = answer; self.provenance = provenance
    }
}

/// A successful read covers explicit questions. Missing answers withdraw only
/// automatic responses in that scope. A failed read must throw, not return empty.
public struct JournalAutoFillSnapshot: Sendable {
    public let day: DayIdentity
    public let timeZoneID: String
    public let resolvedQuestions: Set<JournalAutoFillQuestion>
    public let answers: [JournalAutoFillQuestion: JournalAutoFillAnswer]
    public init(day: DayIdentity, timeZoneID: String, resolvedQuestions: Set<JournalAutoFillQuestion>,
                answers: [JournalAutoFillQuestion: JournalAutoFillAnswer]) {
        self.day = day; self.timeZoneID = timeZoneID
        self.resolvedQuestions = resolvedQuestions; self.answers = answers
    }
}

public protocol JournalAutoFillProviding: Sendable {
    func snapshot(for day: DayIdentity, timeZoneID: String) async throws -> JournalAutoFillSnapshot
}

public enum JournalAutoFillError: Error, Equatable, LocalizedError {
    case invalidEvidence
    public var errorDescription: String? { "The logged source could not be verified. Your answers have been kept." }
}

public struct JournalAutoFillService: Sendable {
    private let store: any HabitStore
    private let clock: any DateProviding
    public init(store: any HabitStore, clock: any DateProviding = SystemDateProvider()) {
        self.store = store; self.clock = clock
    }

    public func reconcile(_ snapshot: JournalAutoFillSnapshot) async throws {
        guard snapshot.answers.allSatisfy({ question, value in
            snapshot.resolvedQuestions.contains(question) && value.answer != .skipped
                && value.provenance.question == question && value.provenance.isValid
        }) else { throw JournalAutoFillError.invalidEvidence }
        let definitions = try await store.definitions(includeArchived: true)
        let now = clock.now()
        try Task.checkCancellation()
        try await store.updateDayRecord(for: snapshot.day) { existing in
            try Task.checkCancellation()
            var record = existing ?? HabitDayRecord(behaviorDay: snapshot.day,
                behaviorTimeZoneID: snapshot.timeZoneID, createdAt: now)
            guard record.behaviorTimeZoneID == snapshot.timeZoneID else { throw HabitStoreError.timeZoneMismatch }
            let original = record
            for definition in definitions {
                guard (!definition.isArchived || record.response(for: definition.id) != nil),
                      !record.hasUserOverride(for: definition.id),
                      case .preset(let catalogID) = definition.source,
                      let question = JournalAutoFillQuestion(rawValue: catalogID),
                      snapshot.resolvedQuestions.contains(question) else { continue }
                let answer = question.accepts(definition) ? snapshot.answers[question] : nil
                if let answer {
                    if let index = record.responses.firstIndex(where: { $0.habitID == definition.id }) {
                        guard record.responses[index].answer != answer.answer
                            || record.responses[index].autoFillProvenance != answer.provenance else { continue }
                        record.responses[index].answer = answer.answer
                        record.responses[index].autoFillProvenance = answer.provenance
                        record.responses[index].updatedAt = now
                    } else {
                        record.responses.append(.init(habitID: definition.id, behaviorDay: snapshot.day,
                            behaviorTimeZoneID: snapshot.timeZoneID, answer: answer.answer,
                            firstAnsweredAt: now, firstAnswerSource: .autoFill, autoFillProvenance: answer.provenance))
                    }
                } else {
                    record.responses.removeAll { $0.habitID == definition.id && $0.lastUpdateSource == .autoFill }
                    if record != original { record.completedAt = nil }
                }
            }
            guard record != original else { return nil }
            record.updatedAt = now
            return record
        }
    }
}

/// FoodKit supplies confirmed records only. Nil nutrients remain unknown.
public struct JournalIntakeRecord: Sendable {
    public let source: JournalSourceRecord
    public let alcoholUnits: Double?
    public let caffeineMilligrams: Double?
    public let isMeal: Bool
    public init(source: JournalSourceRecord, alcoholUnits: Double?, caffeineMilligrams: Double?, isMeal: Bool) {
        self.source = source; self.alcoholUnits = alcoholUnits
        self.caffeineMilligrams = caffeineMilligrams; self.isMeal = isMeal
    }
}

public struct JournalFoodDay: Sendable {
    public let records: [JournalIntakeRecord]
    /// A user's explicit completed-log record, not the absence of other meals.
    public let completion: JournalSourceRecord?
    public let bedtime: JournalSourceRecord?
    public init(records: [JournalIntakeRecord], completion: JournalSourceRecord? = nil, bedtime: JournalSourceRecord? = nil) {
        self.records = records; self.completion = completion; self.bedtime = bedtime
    }
}

public enum JournalAutoFillProjection {
    public static func snapshot(day: DayIdentity, timeZoneID: String, food: JournalFoodDay? = nil,
                                training: [JournalSourceRecord]? = nil) throws -> JournalAutoFillSnapshot {
        guard let zone = TimeZone(identifier: timeZoneID) else { throw HabitStoreError.timeZoneMismatch }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let start = calendar.date(from: DateComponents(era: day.era, year: day.year, month: day.month, day: day.day)),
              let end = calendar.date(byAdding: .day, value: 1, to: start),
              let nextEnd = calendar.date(byAdding: .day, value: 1, to: end),
              calendar.component(.year, from: start) == day.year,
              calendar.component(.month, from: start) == day.month,
              calendar.component(.day, from: start) == day.day else { throw HabitStoreError.invalidDay }
        func onDay(_ date: Date) -> Bool { date >= start && date < end }
        var resolved = Set<JournalAutoFillQuestion>()
        var answers: [JournalAutoFillQuestion: JournalAutoFillAnswer] = [:]
        func insert(_ question: JournalAutoFillQuestion, _ answer: HabitAnswer, _ records: [JournalSourceRecord], _ summary: String) {
            answers[question] = .init(answer, provenance: .init(question: question, records: records, summary: summary))
        }
        if let training {
            guard training.allSatisfy({ $0.domain == .train && $0.isValid }) else { throw JournalAutoFillError.invalidEvidence }
            resolved.insert(.trainedToday)
            let sessions = training.filter { onDay($0.occurredAt) }
            if !sessions.isEmpty { insert(.trainedToday, .yes, sessions, sessions.map(\.title).joined(separator: ", ")) }
        }
        if let food {
            guard food.records.allSatisfy({ $0.source.domain == .food && $0.source.isValid }),
                  food.completion == nil || food.completion?.domain == .food,
                  food.completion?.isValid != false,
                  food.bedtime == nil || food.bedtime?.domain == .sleep,
                  food.bedtime?.isValid != false else { throw JournalAutoFillError.invalidEvidence }
            resolved.formUnion([.alcohol, .lateCaffeine, .lateMeal])
            let records = food.records.filter { onDay($0.source.occurredAt) }
            let completion = food.completion.flatMap { onDay($0.occurredAt) ? $0 : nil }
            func nutrient(_ question: JournalAutoFillQuestion, records: [JournalIntakeRecord], value: (JournalIntakeRecord) -> Double?) {
                let positive = records.filter { value($0).map { $0.isFinite && $0 > 0 } == true }
                if !positive.isEmpty {
                    insert(question, .yes, positive.map(\.source), positive.map(\.source.title).joined(separator: ", "))
                } else if let completion, records.allSatisfy({ value($0).map { $0.isFinite && $0 == 0 } == true }) {
                    insert(question, .no, [completion] + records.map(\.source), "Completed food log")
                }
            }
            nutrient(.alcohol, records: records, value: { $0.alcoholUnits })
            nutrient(.lateCaffeine, records: records.filter { calendar.component(.hour, from: $0.source.occurredAt) >= 14 }, value: { $0.caffeineMilligrams })
            if let sleep = food.bedtime, sleep.occurredAt >= start, sleep.occurredAt < nextEnd {
                let bedtime = sleep.occurredAt
                let meals = food.records.filter { $0.isMeal && $0.source.occurredAt >= bedtime.addingTimeInterval(-2 * 60 * 60) && $0.source.occurredAt <= bedtime }
                if !meals.isEmpty { insert(.lateMeal, .yes, meals.map(\.source) + [sleep], meals.map(\.source.title).joined(separator: ", ")) }
                else if let completion, completion.updatedAt >= bedtime {
                    insert(.lateMeal, .no, [completion, sleep], "Completed food log")
                }
            }
        }
        return .init(day: day, timeZoneID: timeZoneID, resolvedQuestions: resolved, answers: answers)
    }
}
