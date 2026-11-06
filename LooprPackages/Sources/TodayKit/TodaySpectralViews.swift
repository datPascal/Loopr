import Foundation
import SwiftUI
import DomainKit
import DesignSystem

enum TodayHeaderFormatting {
    /// The meta line under the Today title, in the grammar every tab shares:
    /// the day, then how long ago the band last synced. "THU 24 SEP · SYNCED
    /// 10 H AGO" on today, "YESTERDAY · WED 23 SEP · SYNCED 25 MIN AGO" on
    /// another day.
    static func meta(navigation: LooprDayNavigation, lastSync: Date?, now: Date) -> String {
        LooprHeaderMeta.line(
            dayPhrase: LooprHeaderMeta.dayPhrase(navigation),
            freshness: LooprHeaderMeta.freshness(.sync(lastSync: lastSync), indicator: nil, now: now)
        )
    }

    /// "Tue 14 Nov" for a summary's own day, for hosts without a shared day.
    static func dayLabel(for day: DayIdentity) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .autoupdatingCurrent

        guard let date = calendar.date(from: DateComponents(
            era: day.era,
            year: day.year,
            month: day.month,
            day: day.day
        )) else {
            return nil
        }

        return LooprDateFormatterCache.string(from: date, format: "EEE d MMM", calendar: calendar)
    }
}

struct TodayExternalInsightCard: View {
    let insight: TodayExternalInsight
    let action: (String) -> Void

    var body: some View {
        Button { action(insight.routeToken) } label: {
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprText("HABIT INSIGHT", style: .sectionLabel, color: .inkSecondary)
                    LooprText(insight.title, style: .cardTitle)
                    LooprText(insight.detail, style: .prose, color: .inkSecondary)
                }
            }
        }
        .buttonStyle(.looprPressableCard)
        .padding(.horizontal, LooprSpacing.screenGutter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(insight.accessibilityText)
        .accessibilityHint("Opens the habit insight details.")
        .accessibilityIdentifier("today-habit-insight")
    }
}
