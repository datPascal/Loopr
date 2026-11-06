import Foundation
import SwiftUI

public struct LooprRatingCalendarModel: Sendable {
    public struct Day: Identifiable, Sendable {
        public var id: Date { date }
        public let date: Date
        public let value: Int?
        public let label: String
    }
    public let days: [Day]
    public let firstLabel: String
    public let lastLabel: String
    public var recordedCount: Int { days.filter { $0.value != nil }.count }

    public init(values: [Date: Int], endingOn: Date, calendar: Calendar) {
        let end = calendar.startOfDay(for: endingOn)
        var byDay: [Date: Int] = [:]
        for (date, value) in values.sorted(by: { $0.key < $1.key }) where (1...5).contains(value) {
            byDay[calendar.startOfDay(for: date)] = value
        }
        let spoken = DateFormatter()
        spoken.calendar = calendar; spoken.timeZone = calendar.timeZone
        spoken.setLocalizedDateFormatFromTemplate("dMMMMyyyy")
        days = (0..<84).compactMap { index in
            guard let date = calendar.date(byAdding: .day, value: index - 83, to: end) else { return nil }
            return Day(date: date, value: byDay[date], label: spoken.string(from: date))
        }
        let label = DateFormatter()
        label.calendar = calendar; label.timeZone = calendar.timeZone
        label.setLocalizedDateFormatFromTemplate("dMMM")
        firstLabel = days.first.map { label.string(from: $0.date).looprLabelCased } ?? ""
        lastLabel = days.last.map { label.string(from: $0.date).looprLabelCased } ?? ""
    }
}

/// Twelve weeks of ordinal ratings. Unanswered days have no accent fill.
public struct LooprRatingCalendar: View {
    private let model: LooprRatingCalendarModel
    private let title: String
    private let accent: LooprColorToken
    private let identifier: String

    public init(model: LooprRatingCalendarModel, title: String, accent: LooprColorToken, identifier: String) {
        self.model = model; self.title = title; self.accent = accent; self.identifier = identifier
    }
    public var body: some View {
        VStack(spacing: LooprSpacing.md) {
            HStack(alignment: .top, spacing: LooprSpacing.xxs) {
                ForEach(0..<12, id: \.self) { week in
                    VStack(spacing: LooprSpacing.xxs) {
                        ForEach(0..<7, id: \.self) { weekday in
                            let index = week * 7 + weekday
                            if model.days.indices.contains(index) {
                                let day = model.days[index]
                                RoundedRectangle(cornerRadius: LooprRadius.calendarCell)
                                    .fill(day.value.map { Color.loopr(accent).opacity(0.2 + Double($0) * 0.16) } ?? Color.loopr(.surfaceElevated))
                                    .frame(height: LooprSpacing.sm)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityAddTraits(.isStaticText)
                                    .accessibilityLabel("\(day.label), \(title), \(day.value.map { "\($0) of 5" } ?? "Not recorded")")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack {
                LooprText(model.firstLabel, style: .confidence, color: .inkSecondary)
                Spacer(minLength: LooprSpacing.xs)
                LooprText(model.lastLabel, style: .confidence, color: .inkSecondary)
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), last 12 weeks, \(model.recordedCount) of \(model.days.count) days recorded")
        .accessibilityIdentifier(identifier)
    }
}

#Preview {
    let calendar = Calendar(identifier: .gregorian)
    let end = Date(timeIntervalSince1970: 1_700_000_000)
    LooprCard {
        LooprRatingCalendar(model: .init(values: [end: 4], endingOn: end, calendar: calendar),
            title: "Mood", accent: .cyclePlum, identifier: "mood-preview")
    }.padding()
}
