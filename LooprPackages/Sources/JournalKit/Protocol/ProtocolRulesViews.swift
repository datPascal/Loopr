import DesignSystem
import DomainKit
import RoutineKit
import SwiftUI

/// A rule editor on screen: the draft and a token so the same rule can open twice.
struct ProtocolRuleEditing: Identifiable {
    let id = UUID()
    let draft: ProtocolRuleDraft
}

// MARK: - Segment

/// The Rules segment (contract phone p-proto, Rules): "Your rules" with the day and the count, then the newest
/// version's rules grouped by time of day. Each row says why the rule is there and who checks it. A tap opens the rule
/// editor, and saving writes the next version. Share, Import and Versions sit in the header's menu; "Add a rule" stays
/// in view (ICP R1-DES-17, R1-NEW-21). With no protocol yet it shows the start screen (`ProtocolStartView`).
struct ProtocolRulesSegment: View {
    @ObservedObject var model: ProtocolTabModel
    let edit: (ProtocolRuleDraft) -> Void
    let openHistory: () -> Void
    let openShare: () -> Void
    let importFile: () -> Void
    let openGitHub: () -> Void
    /// Nil without Journal questions, so the row never offers questions the person never wrote.
    let startFromQuestions: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
            if let routine = model.routine {
                rules
                fromJournal(routine)
            } else if case .noProtocol? = model.content?.routine {
                // The same start screen as Check-in (ICP R1-DES-03).
                ProtocolStartView(model: model, hasQuestions: startFromQuestions != nil, startFromQuestions: { startFromQuestions?() },
                                  importFile: importFile, openGitHub: openGitHub)
            } else if case .unavailable(let message)? = model.content?.routine {
                ProtocolUnavailableCard(message: message) { Task { await model.load() } }
            } else {
                LooprSkeleton(height: 160).accessibilityIdentifier("protocol-rules-loading")
            }
            messages
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("protocol-rules")
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            header
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                let sections = model.ruleSections
                if sections.isEmpty {
                    LooprCard {
                        LooprText("This version has no rules yet. Add one below.", style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                    }
                }
                // The first row with week dots carries the day letters once, for the whole list (ICP R3-HAB-06).
                let lettered = sections.lazy.flatMap(\.rows).first { !$0.weekDots.isEmpty }?.id
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        LooprText(section.title, style: .sectionLabel, color: .inkSecondary)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("protocol-rules-part-\(section.part.rawValue)")
                        LooprCard(density: .flush) {
                            VStack(spacing: LooprSpacing.none) {
                                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                                    if index > 0 { LooprHairline() }
                                    ProtocolRuleRowView(row: row, showsDayLetters: row.id == lettered) { edit(model.draft(for: row.rule)) }
                                }
                            }
                        }
                    }
                }
                ProtocolActionRow(title: ProtocolRulesText.addRule, detail: ProtocolRulesText.addRuleDetail, symbol: "plus",
                                  identifier: "protocol-rule-add") { edit(.newRule()) }
                    .looprCardBackground()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("protocol-rules-list")
        }
    }

    /// "Your rules", with the one menu for the rest (ICP R1-NEW-17, R1-DES-16, R1-DES-17). The day and the count show once,
    /// in the tab's header above the segments, not again here (ICP R3-DES-03, R3-SEN-06).
    private var header: some View {
        HStack(alignment: .center, spacing: LooprSpacing.sm) {
            LooprText(model.rulesTitle, style: .title)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("protocol-rules-header")
            Menu {
                Button(action: openShare) { Label(ProtocolRulesText.shareTitle, systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("protocol-share")
                Button(action: importFile) { Label(ProtocolRulesText.importTitle, systemImage: "square.and.arrow.down") }
                    .accessibilityIdentifier("protocol-import")
                if model.hasEarlierVersions {
                    Button(action: openHistory) { Label(ProtocolRulesText.historyTitle, systemImage: "clock.arrow.circlepath") }
                        .accessibilityIdentifier("protocol-versions-open")
                }
                Button(action: openGitHub) { Label(ProtocolRulesText.findOnGitHub, systemImage: "safari") }
                    .accessibilityIdentifier("protocol-rules-github")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .looprTypography(.title)
                    .foregroundStyle(Color.loopr(.protocolChip))
                    .frame(width: LooprSpacing.interactiveRowHeight, height: LooprSpacing.interactiveRowHeight)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(ProtocolRulesText.menuTitle)
            .accessibilityHint("Share, import a file or see earlier versions")
            .accessibilityIdentifier("protocol-rules-menu")
        }
        .padding(.horizontal, LooprSpacing.xxs)
    }

    /// Which habit questions became rules and which stayed questions about the day, for as long as the protocol holds
    /// rules from the Journal (ICP R1-UPG-12).
    @ViewBuilder
    private func fromJournal(_ routine: ProtocolRoutineData) -> some View {
        if !routine.habitRuleIDs.isEmpty {
            let intro = ProtocolIntro.make(rules: routine.rules, habitRuleIDs: routine.habitRuleIDs,
                                           stayed: model.habits.checkInDefinitions.map(\.checkInTitle), locale: model.week.locale)
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                if let moved = intro.moved { LooprText(moved, style: .caption, color: .inkSecondary) }
                if let stayed = intro.stayed { LooprText(stayed, style: .caption, color: .inkSecondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("protocol-rules-from-journal")
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let message = model.importError {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprInlineMessage(message, tone: .warning)
                LooprText("Nothing was changed.", style: .caption, color: .inkSecondary)
                Button("Dismiss") { model.dismissImportError() }
                    .buttonStyle(.borderless)
                    .frame(minHeight: LooprSpacing.interactiveRowHeight)
                    .accessibilityIdentifier("protocol-import-error-dismiss")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("protocol-import-error")
        }
        if let message = model.rulesErrorMessage {
            LooprInlineMessage(message, tone: .warning)
                .accessibilityIdentifier("protocol-rules-message")
        }
    }
}

/// One rule, short enough to scan ten of them (ICP R2-HAB-05, R2-DES-15): the title with who checks it, one why line,
/// then this week's seven dots with the run from three days on, and the bell only when a reminder is set. A rule with a
/// longer period shows how far it has come instead of dots: "Each week · 112 of 150 min this week".
struct ProtocolRuleRowView: View {
    let row: ProtocolRuleRow
    /// Day letters over the dots, on the list's first row with dots only (ICP R3-HAB-06).
    var showsDayLetters = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                            title.layoutPriority(1)
                            Spacer(minLength: LooprSpacing.xxs)
                            ProtocolRuleChip(symbol: row.sourceSymbol, text: row.sourceChip)
                        }
                        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                            title
                            ProtocolRuleChip(symbol: row.sourceSymbol, text: row.sourceChip)
                        }
                    }
                    if let why = row.why {
                        // One plain sentence, never cut off (ICP R2-NEW-07): the rule's why is written short.
                        LooprText(why, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let schedule = row.schedule {
                        LooprText(schedule, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let share = row.weekShare {
                        ProtocolRuleWeekBar(share: share)
                    }
                    if let test = row.testText {
                        ProtocolRuleChip(symbol: "flask", text: test, tint: .protocolChip)
                            .accessibilityIdentifier("protocol-rule-\(row.rule.key.rawValue)-test")
                    }
                    if !row.weekDots.isEmpty || row.reminderText != nil {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: LooprSpacing.sm) { weekLine }
                            VStack(alignment: .leading, spacing: LooprSpacing.xxs) { weekLine }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LooprChevron()
            }
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .padding(.vertical, LooprSpacing.xs)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint("Opens the rule to change it.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("protocol-rule-\(row.rule.key.rawValue)")
    }

    private var title: some View {
        LooprText(row.title, style: .rowTitle)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var weekLine: some View {
        if !row.weekDots.isEmpty {
            HStack(alignment: .bottom, spacing: LooprSpacing.xs) {
                if showsDayLetters {
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                        ProtocolRuleWeekLetters(dots: row.weekDots)
                        ProtocolRuleWeekDots(dots: row.weekDots)
                    }
                } else {
                    ProtocolRuleWeekDots(dots: row.weekDots)
                }
                if let run = row.runText {
                    LooprText(run, style: .caption, color: .protocolChip)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if let reminder = row.reminderText {
            ProtocolRuleChip(symbol: "bell.fill", text: reminder, tint: .protocolChip)
        }
    }
}

/// Seven small dots, Monday to Sunday, drawn the way the Check-in draws a rule's state (`ProtocolDotDrawing`), so a day
/// reads the same on both. Today sits on a short underline. Days still to come and days off are a faint speck.
struct ProtocolRuleWeekDots: View {
    let dots: [ProtocolRuleWeekDot]
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 9

    var body: some View {
        Canvas { context, canvas in
            let step = canvas.width / CGFloat(max(dots.count, 1))
            let radius = min(step, canvas.height) * 0.36
            for (index, dot) in dots.enumerated() {
                let center = CGPoint(x: step * (CGFloat(index) + 0.5), y: canvas.height * 0.42)
                var layer = context
                switch dot.state {
                case .kept: ProtocolDotDrawing.draw(.kept, at: center, radius: radius, in: &layer, dark: colorScheme == .dark)
                case .missed: ProtocolDotDrawing.draw(.missed, at: center, radius: radius, in: &layer, dark: colorScheme == .dark)
                case .skipped: ProtocolDotDrawing.draw(.skipped, at: center, radius: radius, in: &layer, dark: colorScheme == .dark)
                case .open: ProtocolDotDrawing.draw(.pending, at: center, radius: radius, in: &layer, dark: colorScheme == .dark)
                case .unknown: ProtocolDotDrawing.draw(.unknown, at: center, radius: radius, in: &layer, dark: colorScheme == .dark)
                case .off, .future:
                    let speck = radius * 0.35
                    layer.fill(Path(ellipseIn: CGRect(x: center.x - speck, y: center.y - speck, width: speck * 2, height: speck * 2)),
                               with: .color(Color.loopr(.inkMuted).opacity(0.5)))
                }
                if dot.isToday {
                    var line = Path()
                    line.move(to: CGPoint(x: center.x - radius, y: canvas.height - 1))
                    line.addLine(to: CGPoint(x: center.x + radius, y: canvas.height - 1))
                    context.stroke(line, with: .color(Color.loopr(.protocol)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
        }
        .frame(width: size * 1.6 * CGFloat(dots.count), height: size * 1.5)
        .accessibilityHidden(true)
    }
}

/// "M T W T F S S" over a row's seven dots, each letter on its dot's column, today's in the Protocol accent and bold
/// (ICP R3-HAB-06). VoiceOver reads the row's week instead.
struct ProtocolRuleWeekLetters: View {
    let dots: [ProtocolRuleWeekDot]
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 9

    var body: some View {
        HStack(spacing: 0) {
            ForEach(dots) { dot in
                Text(String(dot.dayName.prefix(1)))
                    .font(.system(size: size, weight: dot.isToday ? .bold : .regular))
                    .foregroundStyle(Color.loopr(dot.isToday ? .protocol : .inkSecondary))
                    .frame(width: size * 1.6)
            }
        }
        .accessibilityHidden(true)
        .accessibilityIdentifier("protocol-rules-day-letters")
    }
}

/// A thin bar under a weekly amount: the share of the target done this week, never drawn when nothing is measured
/// (ICP R3-VET-09).
struct ProtocolRuleWeekBar: View {
    let share: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.loopr(.protocol).opacity(0.18))
                Capsule().fill(Color.loopr(.protocol)).frame(width: proxy.size.width * share)
            }
        }
        .frame(maxWidth: 180)
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// A small capsule with a symbol and a word: who checks a rule, or its reminder.
struct ProtocolRuleChip: View {
    let symbol: String
    let text: String
    var tint: LooprColorToken = .inkSecondary

    var body: some View {
        HStack(spacing: LooprSpacing.xxs) {
            Image(systemName: symbol)
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .looprTypography(.caption)
        .foregroundStyle(Color.loopr(tint))
        .padding(.horizontal, LooprSpacing.xs)
        .padding(.vertical, LooprSpacing.xxs / 2)
        .background(Color.loopr(.surfaceElevated), in: Capsule())
    }
}

/// A 56 pt row with a symbol, a title, a line under it and a chevron.
struct ProtocolActionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LooprSpacing.sm) {
                Image(systemName: symbol)
                    .looprTypography(.metricValue)
                    .foregroundStyle(Color.loopr(.protocolChip))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                    LooprText(title, style: .rowTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    LooprText(detail, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LooprChevron()
            }
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .padding(.vertical, LooprSpacing.xs)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Rule editor

/// Edits one rule, or a new one, in a sheet that opens at half height (ICP R1-DES-08, R2-HAB-08, R2-DES-09). The first
/// view is short: a line that says what the rule does, then Name, Why and Days, with Save in the bar. The time, the
/// reminder, who checks it, the line for the morning, the group and the target fold under "More options". Save writes
/// the next version, with an optional "Why this change?" as its note (ICP R2-VET-07), and the Rules segment says so
/// afterwards, with Undo. Remove asks first.
struct ProtocolRuleEditor: View {
    @ObservedObject var model: ProtocolTabModel
    @State var draft: ProtocolRuleDraft
    let saved: (ProtocolSavedNotice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var valueText = ""
    @State private var showsMore = LooprFoldSummary.opensForCapture
    @State private var confirmsRemoval = false
    /// Save was tapped while something was missing. Until then the name hint stays away (ICP R2-DES-10).
    @State private var triedSave = false
    @State private var changeReason = ""
    /// The rule that already measures what this one would, while "Keep both?" is asked (ICP R3-VET-05).
    @State private var overlap: ProtocolRule?

    /// "You" first, then the sources that check a rule for the person.
    private static let sources: [CheckSource] = [.manual, .band, .food, .fitness, .appleHealth]
    private static let periods: [RuleCadence] = [
        RuleCadence(unit: .week), RuleCadence(unit: .week, every: 2), RuleCadence(unit: .month),
        RuleCadence(unit: .month, every: 3), RuleCadence(unit: .month, every: 6), RuleCadence(unit: .month, every: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                    LooprText(draft.summary(locale: model.week.locale), style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("rule-editor-summary")
                    name
                    why
                    if let evidence = draft.evidence { evidenceNote(evidence) }
                    days
                    LooprFoldSection(ProtocolRulesText.moreOptions, summary: ProtocolRulesText.moreOptionsSummary,
                                     identifier: "rule-editor-more", isOpen: $showsMore, spacing: LooprSpacing.md) {
                        time
                        checkedBy
                        if draft.keepsMorningLine { rebuttal }
                        details
                    }
                    if !draft.isAdding { changeReasonField }
                    if let message = model.rulesErrorMessage {
                        LooprInlineMessage(message, tone: .warning)
                            .accessibilityIdentifier("rule-editor-message")
                    }
                    if !draft.isAdding {
                        Button(role: .destructive) { confirmsRemoval = true } label: {
                            Label(ProtocolRulesText.removeTitle, systemImage: "trash")
                        }
                        .buttonStyle(LooprDestructiveButtonStyle())
                        .disabled(model.isSaving)
                        .accessibilityIdentifier("rule-editor-delete")
                    }
                }
                .padding(LooprSpacing.screenGutter)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("rule-editor")
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle(draft.isAdding ? ProtocolRulesText.addTitle : ProtocolRulesText.editTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("rule-editor-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Save stays tappable while something is missing, so the tap can say what (ICP R2-DES-10). It is off
                    // only when nothing changed.
                    Button("Save") { attemptSave() }
                        .disabled(model.isSaving || (draft.problem == nil && !draft.canSave))
                        .accessibilityIdentifier("rule-editor-save")
                }
            }
            .confirmationDialog("Remove \(draft.title)?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
                Button(ProtocolRulesText.removeConfirm, role: .destructive) {
                    var removal = draft
                    removal.isRemoved = true
                    save(removal)
                }
                .accessibilityIdentifier("rule-editor-remove-confirm")
                Button("Keep it", role: .cancel) {}
            } message: {
                Text(ProtocolRulesText.removeNote)
            }
            .confirmationDialog(overlap.map(ProtocolRulesText.overlapTitle) ?? "",
                                isPresented: Binding(get: { overlap != nil }, set: { if !$0 { overlap = nil } }),
                                titleVisibility: .visible, presenting: overlap) { existing in
                Button(ProtocolRulesText.overlapKeepBoth) { save(draft) }
                    .accessibilityIdentifier("rule-editor-overlap-keep-both")
                Button(ProtocolRulesText.overlapReplace(existing, locale: model.week.locale), role: .destructive) {
                    save(draft, replacing: existing.key)
                }
                .accessibilityIdentifier("rule-editor-overlap-replace")
                // A plain button, not the cancel role: iOS 26 hides a cancel button in this popover, and a beginner
                // needs to see the way back.
                Button(ProtocolRulesText.overlapGoBack) { overlap = nil }
                    .accessibilityIdentifier("rule-editor-overlap-go-back")
            } message: { existing in
                Text(ProtocolRulesText.overlapDetail(existing, locale: model.week.locale))
            }
        }
        .tint(Color.loopr(.protocol))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { valueText = draft.value.map(Self.format) ?? "" }
    }

    // MARK: Name and why

    private var name: some View {
        LooprSectionGroup(title: ProtocolRulesText.nameTitle) {
            LooprFormCard(padding: LooprSpacing.none) {
                VStack(alignment: .leading, spacing: LooprSpacing.none) {
                    TextField(ProtocolRulesText.nameTitle, text: $draft.title,
                              prompt: Text("For example, screens off by \(LooprClockFormat.text(minuteOfDay: 21 * 60 + 45, locale: model.week.locale))"))
                        .looprTypography(.prose)
                        .padding(.horizontal, LooprSpacing.formCardPadding)
                        .frame(minHeight: LooprSpacing.interactiveRowHeight)
                        .accessibilityLabel(ProtocolRulesText.nameTitle)
                        .accessibilityIdentifier("rule-editor-title")
                    if let shown = draft.shownTitle(locale: model.week.locale) {
                        note("Shows as \"\(shown)\". The time in the name moves when you change the rule's time.")
                            .accessibilityIdentifier("rule-editor-title-shown")
                    }
                    hint(.name)
                }
            }
        }
    }

    /// The one reason field (ICP R2-DES-09, R2-HAB-07).
    private var why: some View {
        LooprSectionGroup(title: ProtocolRulesText.whyTitle) {
            LooprFormCard(padding: LooprSpacing.none) {
                VStack(alignment: .leading, spacing: LooprSpacing.none) {
                    TextField(ProtocolRulesText.whyTitle, text: $draft.why, prompt: Text(ProtocolRulesText.whyPrompt), axis: .vertical)
                        .lineLimit(1...5)
                        .looprTypography(.prose)
                        .padding(.horizontal, LooprSpacing.formCardPadding)
                        .padding(.vertical, LooprSpacing.xs)
                        .frame(minHeight: LooprSpacing.interactiveRowHeight)
                        .accessibilityLabel(ProtocolRulesText.whyTitle)
                        .accessibilityIdentifier("rule-editor-why")
                    if draft.why.count > ProtocolFile.maximumWhyLength - 40 {
                        note("\(draft.why.count) of \(ProtocolFile.maximumWhyLength) characters")
                    }
                    hint(.why)
                }
            }
        }
    }

    /// "Where this comes from" under the Why, read only: the source the template or file gave (ICP R3-VET-08).
    private func evidenceNote(_ evidence: String) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            LooprText(ProtocolRulesText.evidenceTitle, style: .label, color: .inkSecondary)
                .accessibilityAddTraits(.isHeader)
            LooprText(evidence, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, LooprSpacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("rule-editor-evidence")
    }

    // MARK: Days

    /// One "How often" row that shows the rule's real cadence, "Every 3 months" or "Mon, Wed, Fri", and opens a menu of
    /// the four ways to pick days, with what the pick needs right under it. It used to be four rows that took half the
    /// sheet (ICP R3-DES-07).
    private var days: some View {
        LooprSectionGroup(title: ProtocolRulesText.howOftenTitle) {
            LooprFormCard(padding: LooprSpacing.none) {
                VStack(alignment: .leading, spacing: LooprSpacing.none) {
                    howOftenMenu
                    if draft.daysMode != .everyDay { LooprHairline() }
                    daysDetail
                }
            }
        }
    }

    private var howOftenMenu: some View {
        Menu {
            ForEach(ProtocolRuleDraft.DaysMode.allCases, id: \.self) { mode in
                Button { draft.daysMode = mode } label: {
                    if mode == draft.daysMode { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                }
                .accessibilityIdentifier("rule-editor-days-\(mode.rawValue)")
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                LooprText(ProtocolRulesText.howOftenTitle, style: .settingsRow)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: LooprSpacing.sm)
                LooprText(draft.cadenceSummary, style: .settingsRow, color: .protocolChip)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(Color.loopr(.inkMuted))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, LooprSpacing.formCardPadding)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .contentShape(Rectangle())
        }
        .animation(LooprMotion.stateChange, value: draft.daysMode)
        .sensoryFeedback(.selection, trigger: draft.daysMode)
        .accessibilityLabel(ProtocolRulesText.howOftenTitle)
        .accessibilityValue(draft.cadenceSummary)
        .accessibilityHint("Opens the ways to pick days.")
        .accessibilityIdentifier("rule-editor-days")
    }

    @ViewBuilder
    private var daysDetail: some View {
        switch draft.daysMode {
        case .everyDay:
            EmptyView()
        case .someDays:
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprWeekdayPicker(ProtocolRulesText.daysTitle, selection: weekdays, accent: .protocol, identifier: "rule-editor-weekdays")
                LooprText("On the other days Loopr does not ask about this rule.", style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                hint(.days, padded: false)
            }
            .padding(LooprSpacing.formCardPadding)
        case .timesAWeek:
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                Stepper(value: $draft.timesPerWeek, in: RuleCadence.timesPerWeekRange) {
                    LooprText("\(draft.timesPerWeek) times a week", style: .settingsRow)
                }
                .frame(minHeight: LooprSpacing.interactiveRowHeight)
                .accessibilityIdentifier("rule-editor-times")
                LooprText("Any days you like. The week runs Monday to Sunday.", style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(LooprSpacing.formCardPadding)
        case .lessOften:
            LooprPickerRow(title: ProtocolRulesText.repeatsTitle, selection: Binding(get: { RuleCadence(unit: draft.cadenceUnit, every: draft.cadenceEvery) },
                                                                  set: { draft.cadenceUnit = $0.unit; draft.cadenceEvery = $0.every }),
                           options: periods, label: { ProtocolAutoFill.capitalizedFirst(ProtocolRulesPresentation.cadenceText($0)) })
                .accessibilityIdentifier("rule-editor-cadence")
        }
    }

    // MARK: More options

    /// A compact time row instead of a wheel (ICP R2-DES-09), with the reminder under it.
    private var time: some View {
        LooprSectionGroup(title: ProtocolRulesText.whenTitle) {
            LooprFormCard(padding: LooprSpacing.none) {
                VStack(alignment: .leading, spacing: LooprSpacing.none) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: LooprSpacing.sm) { timeRow }
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) { timeRow }
                    }
                    .padding(.horizontal, LooprSpacing.formCardPadding)
                    .padding(.vertical, LooprSpacing.xxs)
                    .frame(minHeight: LooprSpacing.interactiveRowHeight)
                    if model.hasReminders {
                        LooprHairline()
                        LooprToggleRow(title: ProtocolRulesText.remindTitle,
                                       subtitle: draft.hasTime ? ProtocolRulesText.remindDetail : ProtocolRulesText.remindNeedsTime,
                                       accent: .protocol, identifier: "rule-editor-reminder",
                                       isOn: Binding(get: { draft.remindMe }, set: { on in
                                           draft.remindMe = on
                                           if on && !draft.hasTime { draft.hasTime = true }
                                       }))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var timeRow: some View {
        LooprText(ProtocolRulesText.timeTitle, style: .settingsRow)
            .frame(maxWidth: .infinity, alignment: .leading)
        if draft.hasTime {
            HStack(spacing: LooprSpacing.xs) {
                DatePicker(ProtocolRulesText.timeTitle, selection: minuteBinding(\.minuteOfDay), displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                    .accessibilityLabel(ProtocolRulesText.timeTitle)
                    .accessibilityIdentifier("rule-editor-time")
                Button {
                    draft.hasTime = false
                    draft.remindMe = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.loopr(.inkMuted))
                        .frame(width: LooprSpacing.interactiveRowHeight, height: LooprSpacing.interactiveRowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Any time")
                .accessibilityHint("Takes the time off this rule.")
                .accessibilityIdentifier("rule-editor-time-clear")
            }
        } else {
            Button(ProtocolRulesText.setATime) {
                draft.hasTime = true
            }
            .buttonStyle(.borderless)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .accessibilityValue(ProtocolRulesText.anyTime)
            .accessibilityIdentifier("rule-editor-time-set")
        }
    }

    private var checkedBy: some View {
        LooprSectionGroup(title: ProtocolRulesText.checkedByTitle) {
            LooprFormCard(padding: LooprSpacing.none) {
                VStack(alignment: .leading, spacing: LooprSpacing.none) {
                    choiceList(ProtocolRulesText.checkedByTitle,
                               choices: Self.sources.map { ($0.rawValue, ProtocolRulesPresentation.sourceChip($0)) },
                               selection: draft.source.rawValue, identifier: "rule-editor-source") { choice in
                        guard let source = CheckSource(rawValue: choice) else { return }
                        draft.setSource(source)
                        syncValueText()
                    }
                    note(ProtocolRulesPresentation.sourceHelp(draft.source))
                        .padding(.top, LooprSpacing.xs)
                    if draft.offersAlsoAsk {
                        LooprHairline()
                        LooprToggleRow(title: ProtocolRulesText.eveningTitle, subtitle: ProtocolRulesText.eveningDetail,
                                       accent: .protocol, identifier: "rule-editor-evening",
                                       isOn: Binding(get: { draft.isEvening }, set: { on in
                                           draft.isEvening = on
                                           if on && !draft.hasTime { draft.minuteOfDay = ProtocolRuleDraft.defaultEveningMinute }
                                       }))
                    }
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprFormCard(padding: LooprSpacing.none) {
                VStack(spacing: LooprSpacing.none) {
                    LooprPickerRow(title: ProtocolRulesText.groupTitle, selection: $draft.group, options: RuleGroup.allCases,
                                   label: ProtocolRulesPresentation.groupTitle)
                        .accessibilityIdentifier("rule-editor-group")
                    if draft.source != .manual { measure }
                }
            }
            hint(.target, padded: false)
        }
    }

    @ViewBuilder
    private var measure: some View {
        LooprHairline()
        LooprPickerRow(title: "Measure", selection: Binding(get: { draft.metric }, set: { draft.setMetric($0); syncValueText() }),
                       options: ProtocolRuleDraft.metrics(for: draft.source), label: ProtocolRulesPresentation.metricTitle)
            .accessibilityIdentifier("rule-editor-metric")
        if let kept = draft.keptMetric { note("Checks \(kept)") }
        LooprHairline()
        LooprPickerRow(title: "Target", selection: Binding(get: { draft.targetKind }, set: { kind in
            draft.targetKind = kind
            if kind != .done, draft.value == nil { draft.value = 0 }
            syncValueText()
        }), options: RuleTargetKind.allCases, label: ProtocolRulesPresentation.targetKindTitle)
            .accessibilityIdentifier("rule-editor-target-kind")
        if draft.targetKind != .done { LooprHairline(); target }
    }

    private var target: some View {
        Group {
            if draft.metric.isTimeOfDay {
                DatePicker("Target time", selection: minuteBinding(nil), displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact)
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                    .looprTypography(.prose)
                    .padding(.horizontal, LooprSpacing.formCardPadding)
                    .frame(minHeight: LooprSpacing.interactiveRowHeight)
            } else {
                HStack(spacing: LooprSpacing.sm) {
                    LooprText("Amount", style: .settingsRow)
                    TextField("Amount", text: $valueText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .looprTypography(.prose)
                        .onChange(of: valueText) { _, text in
                            // "045" reads as 45: leading zeros go as they are typed (ICP R2-OPT-6).
                            let trimmed = ProtocolRuleDraft.trimmingLeadingZeros(text)
                            if trimmed != text { valueText = trimmed; return }
                            draft.setAmount(Double(text.replacingOccurrences(of: ",", with: ".")))
                        }
                    if !draft.unitLabel.isEmpty {
                        LooprText(draft.unitLabel, style: .caption, color: .inkSecondary)
                    }
                }
                .padding(.horizontal, LooprSpacing.formCardPadding)
                .frame(minHeight: LooprSpacing.interactiveRowHeight)
            }
        }
        .accessibilityIdentifier("rule-editor-target")
    }

    /// "A line to yourself for the morning", the rebuttal the reminder shows (DEC-12.18), under More options.
    private var rebuttal: some View {
        LooprSectionGroup(title: ProtocolRulesText.rebuttalTitle) {
            LooprFormCard {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    TextField(ProtocolRulesText.rebuttalTitle, text: $draft.rebuttal, prompt: Text(ProtocolRulesText.rebuttalPrompt),
                              axis: .vertical)
                        .lineLimit(1...6)
                        .looprTypography(.prose)
                        .frame(minHeight: LooprSpacing.interactiveRowHeight, alignment: .topLeading)
                        .accessibilityLabel(ProtocolRulesText.rebuttalTitle)
                        .accessibilityIdentifier("rule-editor-rebuttal")
                    LooprText(ProtocolRulesText.rebuttalHelp, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if draft.rebuttal.count > ProtocolFile.maximumRebuttalLength - 40 {
                        LooprText("\(draft.rebuttal.count) of \(ProtocolFile.maximumRebuttalLength)", style: .caption,
                                  color: draft.rebuttal.count > ProtocolFile.maximumRebuttalLength ? .critical : .inkSecondary)
                    }
                    hint(.reason, padded: false)
                }
            }
        }
    }

    /// "Why this change?", saved as the version's note (ICP R2-VET-07). Optional; without it Loopr notes what changed.
    private var changeReasonField: some View {
        LooprSectionGroup(title: ProtocolRulesText.changeReasonTitle) {
            LooprFormCard(padding: LooprSpacing.none) {
                VStack(alignment: .leading, spacing: LooprSpacing.none) {
                    TextField(ProtocolRulesText.changeReasonTitle, text: $changeReason,
                              prompt: Text(ProtocolRulesText.changeReasonPrompt), axis: .vertical)
                        .lineLimit(1...4)
                        .looprTypography(.prose)
                        .padding(.horizontal, LooprSpacing.formCardPadding)
                        .padding(.vertical, LooprSpacing.xs)
                        .frame(minHeight: LooprSpacing.interactiveRowHeight)
                        .accessibilityLabel(ProtocolRulesText.changeReasonTitle)
                        .accessibilityIdentifier("rule-editor-change-reason")
                    if changeReason.count > ProtocolFile.maximumWhyLength - 40 {
                        note("\(changeReason.count) of \(ProtocolFile.maximumWhyLength) characters")
                    }
                }
            }
        }
    }

    // MARK: Parts

    /// Plain rows with a check on the one picked: the days and who checks the rule.
    private func choiceList(_ title: String, choices: [(id: String, title: String)], selection: String, identifier: String,
                            onSelect: @escaping (String) -> Void) -> some View {
        VStack(spacing: LooprSpacing.none) {
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                if index > 0 { LooprHairline() }
                let selected = choice.id == selection
                Button { onSelect(choice.id) } label: {
                    HStack(spacing: LooprSpacing.sm) {
                        LooprText(choice.title, style: .settingsRow, color: selected ? .protocolChip : .ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if selected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.loopr(.protocolChip))
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, LooprSpacing.formCardPadding)
                    .frame(minHeight: LooprSpacing.interactiveRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.looprPressableRow)
                .accessibilityLabel("\(title), \(choice.title)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("\(identifier)-\(choice.id)")
            }
        }
        .animation(LooprMotion.stateChange, value: selection)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private func note(_ text: String) -> some View {
        LooprText(text, style: .caption, color: .inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, LooprSpacing.formCardPadding)
            .padding(.bottom, LooprSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Why Save cannot go ahead, next to the field it is about (ICP R1-DES-20). The name hint waits for a Save attempt,
    /// so an untouched field is never told off (ICP R2-DES-10).
    @ViewBuilder
    private func hint(_ field: ProtocolRuleDraft.Field, padded: Bool = true) -> some View {
        if draft.problemField == field, triedSave || field != .name, let problem = draft.problem {
            LooprText(problem, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, padded ? LooprSpacing.formCardPadding : LooprSpacing.none)
                .padding(.bottom, padded ? LooprSpacing.xs : LooprSpacing.none)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("rule-editor-problem")
        }
    }

    private var periods: [RuleCadence] {
        let current = RuleCadence(unit: draft.cadenceUnit, every: draft.cadenceEvery)
        return Self.periods.contains(current) ? Self.periods : Self.periods + [current]
    }

    private var weekdays: Binding<Set<LooprWeekday>> {
        Binding(get: { Set(draft.chosenDays.compactMap { LooprWeekday(rawValue: $0.isoNumber) }) },
                set: { draft.chosenDays = Set($0.map { RuleWeekday.allCases[$0.rawValue - 1] }) })
    }

    /// A clock time as a `Date` on 1 Jan 2001 in UTC, so the picker and the stored minutes never shift with a zone.
    /// A nil key path edits the target value.
    private func minuteBinding(_ path: WritableKeyPath<ProtocolRuleDraft, Int>?) -> Binding<Date> {
        Binding(get: {
            let minute = path.map { draft[keyPath: $0] } ?? Int(draft.value ?? 0)
            return Date(timeIntervalSinceReferenceDate: TimeInterval((minute % 1_440) * 60))
        }, set: { date in
            let minute = Int(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 86_400) / 60)
            let clock = ((minute % 1_440) + 1_440) % 1_440
            // The time in the rule's name moves with the time it stands for (ICP R1-OPT-9).
            if path != nil { draft.setMinuteOfDay(clock) } else { draft.setTargetMinute(clock) }
        })
    }

    private func syncValueText() { valueText = draft.value.map(Self.format) ?? "" }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// Save with something missing opens where it is and says it; otherwise it saves.
    private func attemptSave() {
        if let problem = draft.problem {
            triedSave = true
            if draft.problemField == .target || draft.problemField == .reason { showsMore = true }
            AccessibilityNotification.Announcement(problem).post()
            return
        }
        if let existing = model.ruleSharingMeasure(with: draft) {
            overlap = existing
            return
        }
        save(draft)
    }

    private func save(_ draft: ProtocolRuleDraft, replacing: RuleKey? = nil) {
        Task {
            if let notice = await model.saveRule(draft, reason: changeReason, replacing: replacing) {
                saved(notice)
                dismiss()
            }
        }
    }
}

// MARK: - Version history

/// Every version, newest first, with its date, what changed and, when the version has one, why (ICP R2-VET-07). An old
/// version opens read only.
struct ProtocolVersionHistoryScreen: View {
    @ObservedObject var model: ProtocolTabModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText("Each save makes a new version. Earlier versions stay as they were.", style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.versionEntries.isEmpty {
                    LooprSkeleton(height: 120).accessibilityLabel("Loading the versions")
                }
                LooprCard(density: .flush) {
                    VStack(spacing: LooprSpacing.none) {
                        ForEach(Array(model.versionEntries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { LooprHairline() }
                            NavigationLink {
                                ProtocolVersionDetailScreen(model: model, number: entry.number)
                            } label: {
                                row(entry)
                            }
                            .buttonStyle(.looprPressableRow)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(label(entry))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("protocol-version-\(entry.number)")
                        }
                    }
                }
            }
            .padding(LooprSpacing.screenGutter)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("protocol-versions")
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle(ProtocolRulesText.historyTitle)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color.loopr(.protocol))
        .task { await model.loadVersions() }
    }

    private func row(_ entry: ProtocolVersionEntry) -> some View {
        HStack(alignment: .top, spacing: LooprSpacing.sm) {
            LooprText("v\(entry.number)", style: .metricValue, color: entry.isCurrent ? .protocolChip : .inkSecondary)
                .frame(minWidth: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                LooprText(title(entry), style: .rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                LooprText(entry.summary, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = entry.reason {
                    // A drawn opening quote, since a typed one can render as a closing glyph (ICP R3-DES-08).
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xxs) {
                        Image(systemName: "quote.opening")
                            .imageScale(.small)
                            .accessibilityHidden(true)
                        LooprText(reason, style: .caption, color: .protocolChip)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Color.loopr(.protocolChip))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            LooprChevron()
        }
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .padding(.vertical, LooprSpacing.xs)
        .frame(minHeight: LooprSpacing.interactiveRowHeight)
        .contentShape(Rectangle())
    }

    private func title(_ entry: ProtocolVersionEntry) -> String {
        let date = entry.dateText(locale: model.week.locale, timeZone: model.week.calendar.timeZone)
        return entry.isCurrent ? "\(date), current" : date
    }

    private func label(_ entry: ProtocolVersionEntry) -> String {
        ["Version \(entry.number), \(title(entry))", entry.summary, entry.reason.map { "Why: \($0)" }]
            .compactMap { $0 }.joined(separator: ". ")
    }
}

/// One saved version, read only: what changed against the version before it first, then the rules that stayed the same,
/// folded (ICP R1-VET-06). The first version lists its rules.
struct ProtocolVersionDetailScreen: View {
    @ObservedObject var model: ProtocolTabModel
    let number: Int
    @State private var showsUnchanged = LooprFoldSummary.opensForCapture

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                if let detail = model.versionDetail(number) {
                    LooprText(ProtocolRulesText.readOnly, style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if detail.previousNumber == nil {
                        if let note = detail.note {
                            LooprText(note, style: .caption, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        rows(detail.unchanged)
                        if detail.unchanged.isEmpty {
                            LooprText("This version has no rules.", style: .prose, color: .inkSecondary)
                        }
                    } else {
                        changes(detail)
                        if !detail.unchanged.isEmpty {
                            LooprFoldSection(detail.unchangedTitle, summary: "As they were in version \(detail.previousNumber ?? 1)",
                                             identifier: "protocol-version-unchanged", isOpen: $showsUnchanged) {
                                rows(detail.unchanged)
                            }
                        }
                    }
                }
            }
            .padding(LooprSpacing.screenGutter)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("protocol-version-detail")
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Version \(number)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func changes(_ detail: ProtocolVersionDetail) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprText(detail.changesTitle, style: .sectionLabel, color: .inkSecondary)
                .accessibilityAddTraits(.isHeader)
            LooprCard(density: .flush) {
                VStack(spacing: LooprSpacing.none) {
                    if detail.changes.isEmpty {
                        LooprText(detail.note ?? "Same rules as version \(detail.previousNumber ?? 1).", style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                            .padding(.horizontal, LooprSpacing.cardHorizontal)
                    }
                    ForEach(Array(detail.changes.enumerated()), id: \.element.id) { index, line in
                        if index > 0 { LooprHairline() }
                        changeRow(line)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("protocol-version-changes")
    }

    private func changeRow(_ line: ProtocolVersionChangeLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
            Image(systemName: line.kind == .added ? "plus.circle" : line.kind == .removed ? "minus.circle" : "pencil.circle")
                .foregroundStyle(Color.loopr(.protocolChip))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                LooprText(line.title, style: .rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = line.detail {
                    LooprText(detail, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .padding(.vertical, LooprSpacing.xs)
        .frame(minHeight: LooprSpacing.interactiveRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityLabel)
        .accessibilityIdentifier("protocol-version-change-\(line.key.rawValue)")
    }

    private func rows(_ rows: [ProtocolRuleRow]) -> some View {
        LooprCard(density: .flush) {
            VStack(spacing: LooprSpacing.none) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { LooprHairline() }
                    ProtocolReadOnlyRuleRow(row: row)
                }
            }
        }
    }
}

struct ProtocolReadOnlyRuleRow: View {
    let row: ProtocolRuleRow

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
            LooprText(row.title, style: .rowTitle)
                .fixedSize(horizontal: false, vertical: true)
            LooprText(row.caption, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .padding(.vertical, LooprSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}
