import DesignSystem
import Foundation
import RoutineKit
import SwiftUI

// A new person's first protocol (ICP round 1, W1): one focused start screen with the templates as cards, a preview of
// each template's rules with who checks each one and why, and after a template the "Your list is ready" card with one
// offer of an evening reminder. Check-in and Rules show the same start screen while there is no protocol.

// MARK: - Start screen

/// What the start screen offers (ICP R1-NEW-01, R1-SEN-01, R1-HAB-11, R1-DES-03): the templates with the gentlest one
/// first and marked "Start here", Start empty last, and "Use my questions" only as a secondary row for a person who
/// already answers Journal questions. It speaks of "your list" and "rules"; "protocol" stays on the tab and the shared
/// file (ICP R2-SEN-04). No foot note: what stays in the check-in is said where it applies (ICP R2-NEW-10, R2-DES-08).
public struct ProtocolStart: Equatable, Sendable {
    public static let title = "Pick a list to start"
    public static let previewHint = "Tap one to see its rules before you use it."
    public static let questionsTitle = "Use my questions"
    public static let questionsDetail = "Turn the questions you already answer into rules"
    public static let gitHubTitle = "Find more lists on GitHub"
    public static let gitHubDetail = "Lists other people shared. Opens in Safari."
    public static let importDetail = "A list someone sent you, from Files"

    public let choices: [ProtocolTemplateChoice]
    /// "Use my questions" shows as a secondary row. A newcomer has no questions, so it never leads.
    public let offersQuestions: Bool

    public var recommended: ProtocolTemplateChoice? { choices.first(where: \.isRecommended) }

    public static func make(hasQuestions: Bool, choices: [ProtocolTemplateChoice] = ProtocolTemplateChoice.all()) -> ProtocolStart {
        let first = choices.filter(\.isRecommended)
        let last = choices.filter { $0.template == .startEmpty && !$0.isRecommended }
        let middle = choices.filter { !$0.isRecommended && $0.template != .startEmpty }
        return ProtocolStart(choices: first + middle + last, offersQuestions: hasQuestions)
    }
}

/// The start screen, on Check-in and on Rules while there is no protocol. A card opens its template's preview; nothing
/// is installed until the preview's "Use these 3 rules". A template with rules lands on Check-in, where the "Your list
/// is ready" card waits; Start empty lands on Rules to add the first rule.
struct ProtocolStartView: View {
    @ObservedObject var model: ProtocolTabModel
    let hasQuestions: Bool
    let startFromQuestions: () -> Void
    let importFile: () -> Void
    let openGitHub: () -> Void
    @State private var choices: [ProtocolTemplateChoice] = []
    @State private var preview: ProtocolTemplatePreview?
    @State private var haptic: LooprHaptic?
    @AppStorage(ProtocolReady.dismissedKey) private var readyDismissed: Double = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    private var start: ProtocolStart { ProtocolStart.make(hasQuestions: hasQuestions, choices: choices) }

    // The header sits beside the `protocol-templates` container, not inside a wrapper with its own identifier. A
    // container whose only child is another container shares one accessibility node with it, and an outer identifier
    // (`protocol-rules`) would hide this one.
    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            header
            templates
            secondary
        }
        .looprHaptic(haptic)
        .onAppear {
            if choices.isEmpty { choices = ProtocolTemplateChoice.all() }
            // A new protocol gets its own "Your list is ready" card, even after an earlier one was dismissed.
            readyDismissed = 0
        }
        .sheet(item: $preview) { preview in
            ProtocolTemplatePreviewSheet(model: model, preview: preview) { await use(preview.template) }
        }
    }

    /// The rosette beside the words, or above them at accessibility sizes so the sentence keeps the full width.
    private var header: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.sm))
            : AnyLayout(HStackLayout(alignment: .center, spacing: LooprSpacing.md))
        return layout {
            ProtocolRosetteOutline(size: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(ProtocolStart.title, style: .title)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("protocol-start-title")
                LooprText(ProtocolIntro.lead, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("protocol-templates-lead")
            }
        }
    }

    private var templates: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            ForEach(start.choices) { choice in
                ProtocolTemplateCard(choice: choice) {
                    preview = ProtocolTemplatePreview.make(choice, locale: model.week.locale)
                }
                .disabled(model.isSaving)
            }
            LooprText(ProtocolStart.previewHint, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("protocol-templates")
    }

    private var secondary: some View {
        LooprCard(density: .flush) {
            VStack(spacing: LooprSpacing.none) {
                if start.offersQuestions {
                    // One name for this action on both segments (ICP R3-NEW-9), now a quiet row (ICP R1-SEN-01).
                    ProtocolActionRow(title: ProtocolStart.questionsTitle, detail: ProtocolStart.questionsDetail,
                                      symbol: "checklist", identifier: "protocol-first-run-start", action: startFromQuestions)
                    LooprHairline()
                }
                ProtocolActionRow(title: ProtocolRulesText.importTitle, detail: ProtocolStart.importDetail,
                                  symbol: "square.and.arrow.down", identifier: "protocol-import", action: importFile)
                LooprHairline()
                ProtocolActionRow(title: ProtocolStart.gitHubTitle, detail: ProtocolStart.gitHubDetail,
                                  symbol: "safari", identifier: "protocol-templates-github", action: openGitHub)
            }
        }
    }

    /// Installs the template. Returns false when it could not, so the sheet stays open with the message.
    private func use(_ template: ProtocolTemplate) async -> Bool {
        guard await model.installTemplate(template) else { return false }
        haptic = .ruleKept
        model.requestedSegment = template == .startEmpty ? .rules : .checkIn
        return true
    }
}

/// One template as a card: its name, what is in it and how many rules Loopr checks for the person. The recommended one
/// leads, tinted, with "Start here".
struct ProtocolTemplateCard: View {
    let choice: ProtocolTemplateChoice
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    if choice.isRecommended {
                        ProtocolStartHereBadge()
                    }
                    LooprText(choice.title, style: choice.isRecommended ? .cardTitle : .rowTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    LooprText(choice.summary, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let counts = choice.counts {
                        LooprText(counts, style: .caption, color: .protocolChip)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LooprChevron()
            }
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .padding(.vertical, LooprSpacing.sm)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .looprCardBackground(choice.isRecommended ? .hero(.protocol) : .standard)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(choice.isRecommended ? "Start here. \(choice.title). \(choice.detail)" : "\(choice.title). \(choice.detail)")
        .accessibilityHint("Shows its rules. Nothing is saved until you use them.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("protocol-template-\(choice.id)")
    }
}

/// "Start here" over the recommended template's name.
struct ProtocolStartHereBadge: View {
    var body: some View {
        Text("Start here")
            .looprTypography(.chip)
            .foregroundStyle(Color.loopr(.protocolChip))
            .padding(.horizontal, LooprSpacing.xs)
            .padding(.vertical, LooprSpacing.xxs)
            .background(Color.loopr(.protocol).opacity(0.14), in: Capsule(style: .continuous))
            .accessibilityIdentifier("protocol-template-start-here")
    }
}

// MARK: - Preview

/// A template's rules before it is used (ICP R1-NEW-03, R1-VET-15, R1-DES-03, R1-SEN-13): each rule with who checks it
/// and why it is there, and the one button that uses them.
public struct ProtocolTemplatePreview: Equatable, Sendable, Identifiable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: RuleKey { key }
        public let key: RuleKey
        /// The title in the locale's clock: "In bed by 10:30 pm" in en_US.
        public let title: String
        /// "You tick this", "Your band checks this".
        public let checker: String
        /// "Each week", or nil for a daily rule.
        public let schedule: String?
        public let why: String?
        /// The source behind the rule, under "Where this comes from" (ICP R2-NEW-07, R2-DES-02).
        public let evidence: String?

        /// "Each week · Your band checks this".
        public var caption: String { [schedule, checker].compactMap { $0 }.joined(separator: " \u{00B7} ") }

        public var accessibilityLabel: String {
            [title, caption, why, evidence.map { "\(ProtocolTemplatePreview.evidenceTitle). \($0)" }]
                .compactMap { $0 }.joined(separator: ". ")
        }
    }

    public var id: String { template.rawValue }
    public let template: ProtocolTemplate
    public let title: String
    /// "3 rules. Loopr checks 2 of the 3 for you.", or Start empty's line.
    public let detail: String
    public let rows: [Row]

    /// "Use these 3 rules", "Use this rule", or "Start with no rules".
    public var useTitle: String {
        switch rows.count {
        case 0: "Start with no rules"
        case 1: "Use this rule"
        default: "Use these \(rows.count) rules"
        }
    }

    public static let changeLater = "You can change or remove any rule later, on Rules."
    /// The heading over a rule's source.
    public static let evidenceTitle = "Where this comes from"

    public static func make(_ choice: ProtocolTemplateChoice, locale: Locale = .current) -> ProtocolTemplatePreview {
        let rows = choice.rules.map { rule in
            Row(key: rule.key, title: rule.displayTitle(locale: locale), checker: checker(rule.source),
                schedule: rule.cadence.flatMap { $0.isEveryDay ? nil : ProtocolAutoFill.capitalizedFirst(ProtocolRulesPresentation.cadenceText($0)) },
                why: rule.why, evidence: rule.evidence)
        }
        return ProtocolTemplatePreview(template: choice.template, title: choice.title, detail: choice.counts ?? choice.summary, rows: rows)
    }

    /// Who checks a rule, said as a whole sentence for a person who has never seen a check source (ICP R1-DES 5.4).
    public static func checker(_ source: CheckSource) -> String {
        switch source {
        case .manual: "You tick this"
        case .band: "Your band checks this"
        case .food: "Food checks this"
        case .fitness: "Fitness checks this"
        case .appleHealth: "Apple Health checks this"
        }
    }
}

/// The preview sheet, at half height first. "Use these 3 rules" stays pinned at the foot; Cancel installs nothing.
struct ProtocolTemplatePreviewSheet: View {
    @ObservedObject var model: ProtocolTabModel
    let preview: ProtocolTemplatePreview
    let use: () async -> Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        LooprText(preview.title, style: .titleLarge)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        LooprText(preview.detail, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !preview.rows.isEmpty {
                        LooprCard(density: .flush) {
                            VStack(spacing: LooprSpacing.none) {
                                ForEach(Array(preview.rows.enumerated()), id: \.element.id) { index, row in
                                    if index > 0 { LooprHairline() }
                                    ProtocolTemplatePreviewRow(row: row)
                                }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("protocol-template-preview-rules")
                    }
                    LooprText(ProtocolTemplatePreview.changeLater, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = model.rulesErrorMessage {
                        LooprInlineMessage(message, tone: .warning)
                            .accessibilityIdentifier("protocol-template-preview-message")
                    }
                }
                .padding(LooprSpacing.screenGutter)
            }
            .safeAreaInset(edge: .bottom) {
                Button(preview.useTitle) {
                    Task { if await use() { dismiss() } }
                }
                .buttonStyle(LooprButtonStyle(accent: .protocol))
                .disabled(model.isSaving)
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.vertical, LooprSpacing.sm)
                .background(Color.loopr(.background).ignoresSafeArea())
                .accessibilityIdentifier("protocol-template-preview-use")
            }
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("protocol-template-preview-cancel")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(Color.loopr(.protocol))
        .accessibilityIdentifier("protocol-template-preview")
    }
}

/// One rule in the preview: its name, who checks it, why it is there, and where that comes from.
struct ProtocolTemplatePreviewRow: View {
    let row: ProtocolTemplatePreview.Row

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            LooprText(row.title, style: .rowTitle)
                .fixedSize(horizontal: false, vertical: true)
            LooprText(row.caption, style: .caption, color: .protocolChip)
                .fixedSize(horizontal: false, vertical: true)
            if let why = row.why {
                LooprText(why, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let evidence = row.evidence {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                    LooprText(ProtocolTemplatePreview.evidenceTitle, style: .label, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LooprText(evidence, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, LooprSpacing.xxs)
            }
        }
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .padding(.vertical, LooprSpacing.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityIdentifier("protocol-template-preview-rule-\(row.key.rawValue)")
    }
}

// MARK: - Your list is ready

/// The card on Check-in on a new protocol's first day (ICP R1-SEN-03, R1-SEN-04): what happens each evening, and one
/// offer of a reminder. "Remind me" sets it in one tap: the button turns into "Reminder set for 20:30" with a check and
/// the card folds away (ICP R2-DES-07). It also goes with "Not now" or "Got it". It sits under the deck, so the first
/// card's Yes and No show without a scroll (R2-DES-01).
public struct ProtocolReady: Equatable, Sendable {
    public static let dismissedKey = "loopr.protocol.readyDismissed"
    public static let title = "Your list is ready"
    public static let defaultReminderMinute = 20 * 60 + 30
    /// A reminder never comes before the evening starts.
    static let earliestReminderMinute = 17 * 60

    /// What happens each evening, in two or three short sentences.
    public let body: String
    public let reminderMinute: Int

    /// On a new protocol's first day with rules, until it is dismissed. A protocol moved over from the Journal has its
    /// own card (`ProtocolIntro`).
    public static func shows(_ routine: ProtocolRoutineData, dismissed: Double) -> Bool {
        routine.version == 1 && routine.dayNumber <= 1 && !routine.rules.isEmpty && routine.habitRuleIDs.isEmpty
            && dismissed != stamp(routine)
    }

    /// Which protocol a dismissal belongs to: its first version's time.
    public static func stamp(_ routine: ProtocolRoutineData) -> Double {
        routine.versionCreatedAt.timeIntervalSince1970.rounded()
    }

    public static func make(rules: [ProtocolRule], locale: Locale = .current) -> ProtocolReady {
        ProtocolReady(body: body(rules, locale: locale), reminderMinute: reminderMinute(for: rules))
    }

    /// 20:30, or an hour before the earliest evening rule the person ticks, if that comes sooner, and never before
    /// 17:00. Rules a source checks need no answer, so they do not move it.
    public static func reminderMinute(for rules: [ProtocolRule]) -> Int {
        let times = rules.filter { $0.isEvening && $0.source == .manual }.compactMap(\.timeOfDayMinutes)
            .filter { $0 >= earliestReminderMinute }
        guard let earliest = times.min() else { return defaultReminderMinute }
        return max(earliestReminderMinute, min(defaultReminderMinute, earliest - 60))
    }

    /// "Each evening, Loopr asks you here about 1 rule. Tap Yes or No. The band and Apple Health check the other 2."
    static func body(_ rules: [ProtocolRule], locale: Locale) -> String {
        let ticked = rules.filter { $0.source == .manual }
        let daily = ticked.filter { $0.cadence?.isEveryDay ?? true }
        let checked = rules.filter { $0.source != .manual }
        let sources = Set(checked.map(\.source))
        let names = ProtocolAutoFill.capitalizedFirst(ProtocolAutoFill.names(sources, locale: locale))
        let verb = sources.count == 1 ? "checks" : "check"
        var sentences: [String] = []
        if !daily.isEmpty {
            sentences.append("Each evening, Loopr asks you here about \(daily.count) \(daily.count == 1 ? "rule" : "rules"). Tap Yes or No.")
        } else if !ticked.isEmpty {
            sentences.append("Loopr asks you here when a rule you tick is due. Tap Yes or No.")
        }
        if checked.isEmpty { return sentences.joined(separator: " ") }
        if ticked.isEmpty {
            let all = checked.count == 2 ? "both" : "all \(checked.count)"
            sentences.append("\(names) \(verb) \(all) for you. Look here each evening to see how the day went.")
        } else {
            sentences.append("\(names) \(verb) the other \(checked.count == 1 ? "one" : "\(checked.count)").")
        }
        return sentences.joined(separator: " ")
    }

    /// "Remind me at 20:30 each evening?"
    public static func offer(minute: Int, locale: Locale = .current) -> String {
        "Remind me at \(LooprClockFormat.text(minuteOfDay: minute, locale: locale)) each evening?"
    }

    /// Where the switch is, said under the offer before the tap (ICP R2-SEN-11, R3-SEN-05): the round person button at
    /// the top right of every tab opens Your data, which lists "Reminders you set". The button has no word on it, so the
    /// line says its shape and place.
    public static let offSwitch = "To stop it later, tap the round person button at the top right, then Reminders you set."

    /// The button once the reminder is set: "Reminder set for 20:30" (ICP R2-DES-07).
    public static func confirmation(minute: Int, locale: Locale = .current) -> String {
        "Reminder set for \(LooprClockFormat.text(minuteOfDay: minute, locale: locale))"
    }

    /// How long "Reminder set for 20:30" shows before the card folds away.
    static let foldDelay: Duration = .seconds(2)
}

/// The evening check-in reminder under "Reminders you set". The app sets it through NotificationKit's
/// `ProtocolCheckInReminder`; without one in the environment the ready card offers no reminder.
public protocol ProtocolCheckInReminding: Sendable {
    /// The waiting reminder's minute of the day, or nil when none is waiting.
    func waitingMinute() async -> Int?
    /// Sets or moves the daily reminder. Nil when it is set, else a sentence that says why not.
    func set(minuteOfDay: Int) async -> String?
}

extension EnvironmentValues {
    @Entry public var protocolCheckInReminder: (any ProtocolCheckInReminding)? = nil
}

/// The ready card in place: it draws nothing unless `ProtocolReady.shows` says so.
struct ProtocolReadyCard: View {
    let routine: ProtocolRoutineData
    let locale: Locale
    @AppStorage(ProtocolReady.dismissedKey) private var dismissed: Double = 0
    @Environment(\.protocolCheckInReminder) private var reminder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var waitingMinute: Int?
    /// The minute "Remind me" set, shown on the button until the card folds.
    @State private var setMinute: Int?
    @State private var message: String?
    @State private var isSetting = false
    @State private var haptic: LooprHaptic?

    var body: some View {
        if ProtocolReady.shows(routine, dismissed: dismissed) {
            let ready = ProtocolReady.make(rules: routine.rules, locale: locale)
            LooprCard(style: .hero(.protocol)) {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprText(ProtocolReady.title, style: .cardTitle)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    LooprText(ready.body, style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("protocol-ready-body")
                    if let setMinute {
                        // Set just now: the button says so with a check, then the card folds.
                        setLabel(minute: setMinute)
                    } else if let waitingMinute {
                        setLabel(minute: waitingMinute)
                        button("Got it", prominent: false, identifier: "protocol-ready-done") { dismiss() }
                    } else if reminder != nil {
                        LooprText(ProtocolReady.offer(minute: ready.reminderMinute, locale: locale), style: .rowTitle)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("protocol-ready-offer")
                        LooprText(ProtocolReady.offSwitch, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("protocol-ready-off-switch")
                        if let message {
                            LooprInlineMessage(message, tone: .warning)
                                .accessibilityIdentifier("protocol-ready-message")
                        }
                        button("Remind me", prominent: true, identifier: "protocol-ready-remind") {
                            Task { await remind(at: ready.reminderMinute) }
                        }
                        .disabled(isSetting)
                        button("Not now", prominent: false, identifier: "protocol-ready-not-now") { dismiss() }
                    } else {
                        button("Got it", prominent: false, identifier: "protocol-ready-done") { dismiss() }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("protocol-ready")
            .looprHaptic(haptic)
            .task { waitingMinute = await reminder?.waitingMinute() }
        }
    }

    private func button(_ title: String, prominent: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(LooprButtonStyle(prominent: prominent, accent: .protocol))
            .accessibilityIdentifier(identifier)
    }

    /// "Reminder set for 20:30" with a check, in the place of the Remind me button.
    private func setLabel(minute: Int) -> some View {
        Label(ProtocolReady.confirmation(minute: minute, locale: locale), systemImage: "checkmark.circle.fill")
            .looprTypography(.button)
            .foregroundStyle(Color.loopr(.protocolChip))
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight)
            .background(Color.loopr(.protocol).opacity(0.12), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("protocol-ready-reminder-set")
    }

    /// Sets the reminder in one tap, shows "Reminder set for 20:30" for two seconds, then folds the card.
    private func remind(at minute: Int) async {
        guard let reminder, !isSetting else { return }
        isSetting = true
        defer { isSetting = false }
        message = await reminder.set(minuteOfDay: minute)
        guard message == nil else { haptic = .error; return }
        haptic = .ruleKept
        withAnimation(LooprMotion.reducesMotion(reduceMotion) ? nil : LooprMotion.stateChange) {
            setMinute = minute
        }
        try? await Task.sleep(for: ProtocolReady.foldDelay)
        dismiss()
    }

    private func dismiss() {
        withAnimation(LooprMotion.reducesMotion(reduceMotion) ? nil : LooprMotion.stateChange) {
            dismissed = ProtocolReady.stamp(routine)
        }
    }
}
