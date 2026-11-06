import DesignSystem
import NotificationKit
import SwiftUI

/// Words for the "Reminders you set" section of Settings > Notifications.
enum UserReminderCopy {
    static let title = "Reminders you set"
    static let toggleSubtitle = "Reminders you confirm in Ask, start with a Patterns test, set for your supplement and medication stacks or an evening rule, or the weekly review. They arrive at the time you chose, even in quiet hours."
    static let empty = "No reminders are waiting."
    static let historyTitle = "Recent results"
    static let historyEmpty = "Nothing has been scheduled yet."

    static func detail(_ request: NotificationRequest, calendar: Calendar = .current) -> String {
        let time = LooprClockFormat.text(minuteOfDay: request.minuteOfDay(calendar: calendar))
        let weekday = request.fireDate.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.wide))
        let repeats: String = switch request.repeats {
        case .daily?: "Every day"
        case .weekly?: "Every " + weekday
        // A rule reminder planned day by day shows its next day only (ICP round 4, Q1b and Q5).
        case nil where ProtocolRuleReminder.isRuleReminder(request): "Next on " + weekday
        case nil: "Once"
        }
        // A Patterns test reminder is titled "Patterns test", so naming the source again would repeat it.
        let source = sourceName(request.reminderSource)
        return (source == request.title ? [time, repeats] : [time, repeats, source]).joined(separator: ", ")
    }

    /// One row per reminder: a rule reminder planned day by day shows its soonest day, not one row per day.
    static func listed(_ requests: [NotificationRequest]) -> [NotificationRequest] {
        var seen = Set<String>()
        return requests.filter { request in
            guard ProtocolRuleReminder.isRuleReminder(request), request.repeats == nil else { return true }
            return seen.insert(request.identity.objectID).inserted
        }
    }

    static func sourceName(_ source: UserReminderSource?) -> String {
        switch source {
        case .ask?: "Ask"
        case .patternsTest?: "Patterns test"
        case nil: "Loopr"
        }
    }

    static func historyLine(_ entry: ReminderHistoryEntry) -> String {
        let time = LooprClockFormat.text(minuteOfDay: entry.minuteOfDay)
        // The history keeps only whether a reminder repeats daily. The weekly review is the one weekly reminder.
        let isWeekly = entry.source == nil && entry.title == WeeklyReviewReminder.title
        let repeats = entry.repeatsDaily ? "every day" : isWeekly ? "every Sunday" : "once"
        return "\(entry.title), \(time), \(repeats), from \(sourceName(entry.source))"
    }

    static func outcome(_ outcome: ReminderHistoryEntry.Outcome) -> String {
        switch outcome {
        case .set: "Set"
        case .alreadySet: "Already set"
        case .familyOff: "Not set. Reminders you set were off."
        case .notAllowed: "Not set. Notifications were off for Loopr."
        case .full: "Not set. \(NotificationFamily.userReminderLimit) reminders were already waiting."
        case .waitingForPermission: "Waiting for notification permission"
        case .failed: "Not set. iOS didn't accept it."
        }
    }
}

/// The toggle for the family, every reminder that waits with a cancel button, and the local history of results.
struct UserRemindersSettingsSection: View {
    var runtime: LooprNotificationRuntime = .shared
    /// Bumped by the screen after anything that can change the list, such as the scene coming back.
    let refreshToken: Int
    @State private var isOn = true
    @State private var reminders: [NotificationRequest] = []
    @State private var history: [ReminderHistoryEntry] = []
    @State private var loaded = false
    @State private var message: String?
    @State private var weeklyReviewOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprFormCard(padding: 0) {
                VStack(spacing: 0) {
                    LooprToggleRow(title: UserReminderCopy.title, subtitle: UserReminderCopy.toggleSubtitle, isOn: Binding(
                        get: { isOn },
                        set: { setEnabled($0) }
                    ))
                    .accessibilityIdentifier("settings-notification-userReminders")
                    LooprHairline()
                    LooprToggleRow(title: WeeklyReviewReminderCopy.title, subtitle: WeeklyReviewReminderCopy.subtitle,
                                   identifier: "reminder-weekly-review",
                                   isOn: Binding(get: { weeklyReviewOn }, set: { setWeeklyReview($0) }))
                    LooprHairline()
                    if !loaded {
                        LooprSkeleton(height: 56).padding(LooprSpacing.formCardPadding)
                    } else if reminders.isEmpty {
                        LooprText(UserReminderCopy.empty, style: .prose, color: .inkSecondary)
                            .padding(LooprSpacing.formCardPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("settings-reminders-empty")
                    } else {
                        ForEach(Array(reminders.enumerated()), id: \.element.identity) { index, request in
                            reminderRow(request)
                            if index < reminders.count - 1 { LooprHairline() }
                        }
                    }
                }
            }
            if let message { LooprInlineMessage(message, tone: .warning) }
            LooprFormCard(padding: 0) {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        if history.isEmpty {
                            LooprText(UserReminderCopy.historyEmpty, style: .prose, color: .inkSecondary)
                        }
                        ForEach(history) { entry in
                            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                                LooprText(UserReminderCopy.historyLine(entry), style: .settingsRow)
                                LooprText(UserReminderCopy.outcome(entry.outcome) + " " + entry.date.formatted(date: .abbreviated, time: .shortened),
                                          style: .caption, color: .inkSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, LooprSpacing.sm)
                } label: {
                    LooprText(UserReminderCopy.historyTitle, style: .settingsRow)
                }
                .padding(.horizontal, LooprSpacing.formCardPadding)
                .frame(minHeight: LooprSpacing.interactiveRowHeight)
                .accessibilityIdentifier("settings-reminders-history")
            }
        }
        .task(id: refreshToken) { await refresh() }
    }

    private func reminderRow(_ request: NotificationRequest) -> some View {
        HStack(alignment: .center, spacing: LooprSpacing.sm) {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(request.title, style: .settingsRow)
                LooprText(UserReminderCopy.detail(request), style: .caption, color: .inkSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-reminder-\(request.identity.objectID)")
            Spacer(minLength: LooprSpacing.sm)
            Button("Cancel") { cancel(request) }
                .buttonStyle(LooprButtonStyle(prominent: false, quiet: true))
                // The style fills the width it gets; here it hugs its text so every Cancel sits on the trailing edge.
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Cancel \(request.title)")
                .accessibilityIdentifier("settings-reminder-cancel-\(request.identity.objectID)")
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .frame(minHeight: LooprSpacing.interactiveRowHeight)
    }

    private func setEnabled(_ enabled: Bool) {
        isOn = enabled
        Task {
            do {
                try await runtime.setPreference(id: NotificationFamily.userReminders.rawValue, enabled: enabled)
                message = nil
            } catch {
                message = "Loopr couldn't save this change. \(error.localizedDescription)"
            }
            await refresh()
        }
    }

    /// The weekly review reminder is off until the person turns it on here.
    private func setWeeklyReview(_ enabled: Bool) {
        weeklyReviewOn = enabled
        #if DEBUG
        if Self.usesFixture { return }
        #endif
        Task {
            if enabled {
                message = WeeklyReviewReminderCopy.message(await runtime.scheduleWeeklyReviewReminder())
            } else {
                await runtime.cancelWeeklyReviewReminder()
                message = nil
            }
            await refresh()
        }
    }

    private func cancel(_ request: NotificationRequest) {
        #if DEBUG
        if Self.usesFixture { fixtureRemoved.insert(request.identity.objectID); reminders.removeAll { $0.identity == request.identity }; return }
        #endif
        Task {
            await runtime.cancelUserReminder(request)
            await refresh()
        }
    }

    private func refresh() async {
        isOn = await runtime.isEnabled(.userReminders)
        reminders = UserReminderCopy.listed(await runtime.userReminders())
        history = await runtime.userReminderHistory()
        weeklyReviewOn = reminders.contains(where: WeeklyReviewReminder.isWeeklyReviewReminder)
        #if DEBUG
        if Self.usesFixture {
            reminders = Self.fixtureReminders.filter { !fixtureRemoved.contains($0.identity.objectID) }
            history = Self.fixtureHistory
        }
        #endif
        loaded = true
    }

    #if DEBUG
    /// `--loopr-reminders-fixture` shows two reminders and a short history without scheduling anything, so a UI test can
    /// capture the list and press Cancel.
    static var usesFixture: Bool { ProcessInfo.processInfo.arguments.contains("--loopr-reminders-fixture") }

    @State private var fixtureRemoved: Set<String> = []

    static var fixtureReminders: [NotificationRequest] {
        let calendar = Calendar.current
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.nextDate(after: Date(), matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime) ?? Date()
        }
        return [
            UserReminderRequestFactory.request(source: .ask, objectID: "ask.fixture-wind-down", day: UserReminderRequestFactory.recurringDay,
                                               fireDate: at(20, 15), title: "Wind down", detail: "Screens off.", repeats: .daily),
            UserReminderRequestFactory.request(source: .patternsTest, objectID: "patterns.fixture-late-dinner", day: UserReminderRequestFactory.recurringDay,
                                               fireDate: at(21, 0), title: "Patterns test", detail: "Open Patterns.", repeats: .daily)
        ]
    }

    static var fixtureHistory: [ReminderHistoryEntry] {
        [ReminderHistoryEntry(date: Date(), source: .ask, title: "Wind down", minuteOfDay: 20 * 60 + 15, repeatsDaily: true, outcome: .set),
         ReminderHistoryEntry(date: Date().addingTimeInterval(-3_600), source: .ask, title: "Stretch", minuteOfDay: 23 * 60 + 30, repeatsDaily: false, outcome: .full)]
    }
    #endif
}
