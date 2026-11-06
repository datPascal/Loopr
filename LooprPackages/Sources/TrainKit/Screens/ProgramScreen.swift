import DesignSystem
import SwiftUI

/// What the Program screen can ask the app to do. The app persists the change and passes a new model back.
public struct ProgramScreenActions {
    public var setEarlyLightWeek: @MainActor (Bool) -> Void
    public var setMissedRule: @MainActor (MissedSessionRule) -> Void
    /// Called with the new switch value. Turning it on is the one place Loopr asks for Calendar access.
    public var setCalendarExport: @MainActor (Bool) -> Void
    public var edit: @MainActor () -> Void
    /// Opens Ask with "Program" as its origin.
    public var changePlan: @MainActor () -> Void
    public var accept: @MainActor () -> Void
    public var discard: @MainActor () -> Void
    public var openSettings: @MainActor () -> Void

    public init(setEarlyLightWeek: @escaping @MainActor (Bool) -> Void = { _ in },
                setMissedRule: @escaping @MainActor (MissedSessionRule) -> Void = { _ in },
                setCalendarExport: @escaping @MainActor (Bool) -> Void = { _ in },
                edit: @escaping @MainActor () -> Void = {}, changePlan: @escaping @MainActor () -> Void = {},
                accept: @escaping @MainActor () -> Void = {}, discard: @escaping @MainActor () -> Void = {},
                openSettings: @escaping @MainActor () -> Void = {}) {
        self.setEarlyLightWeek = setEarlyLightWeek; self.setMissedRule = setMissedRule
        self.setCalendarExport = setCalendarExport; self.edit = edit; self.changePlan = changePlan
        self.accept = accept; self.discard = discard; self.openSettings = openSettings
    }
}

/// One program: the request it came from, the weeks as a grid, its rules and how it is going (mockup 13).
///
/// A draft shows a banner with Accept and Discard first. Until the person accepts, the program is not
/// scheduled and its Calendar switch is locked.
public struct ProgramScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsMissed = false
    private let model: ProgramScreenModel
    private let actions: ProgramScreenActions

    public init(model: ProgramScreenModel, actions: ProgramScreenActions) {
        self.model = model
        self.actions = actions
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
                if model.isDraft { draftBanner }
                if let request = model.request { hero(request) }
                weeksSection
                rulesSection
                if let soFar = model.soFar { soFarSection(soFar) }
                if !model.changes.isEmpty { changesSection }
                Button { actions.changePlan() } label: {
                    Label("Change this plan", systemImage: "sparkles")
                }
                .buttonStyle(LooprButtonStyle(prominent: false, accent: .movement))
                .accessibilityIdentifier("program-change-plan")
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.tabContentTop)
            .padding(.bottom, LooprSpacing.tabSection)
        }
        .background(Color.loopr(.background))
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { actions.edit() }
                    .accessibilityIdentifier("program-edit")
            }
        }
        .sheet(isPresented: $showsMissed) {
            ProgramMissedRuleSheet(selection: model.missedRule) { rule in
                showsMissed = false
                actions.setMissedRule(rule)
            }
        }
        .accessibilityIdentifier("program-screen")
    }

    // MARK: Draft

    private var draftBanner: some View {
        LooprCard(style: .warning) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                StatusChip("Draft", symbol: "sparkles", tone: .warning)
                LooprText(ProgramScreenModel.draftMessage, style: .prose, color: .ink)
                    .fixedSize(horizontal: false, vertical: true)
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: LooprSpacing.sm))
                    : AnyLayout(HStackLayout(spacing: LooprSpacing.sm))
                layout {
                    Button("Discard") { actions.discard() }
                        .buttonStyle(LooprButtonStyle(prominent: false, accent: .movement))
                        .accessibilityIdentifier("program-draft-discard")
                    Button("Accept") { actions.accept() }
                        .buttonStyle(LooprButtonStyle(accent: .movement))
                        .accessibilityIdentifier("program-draft-accept")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("program-draft-banner")
    }

    // MARK: Hero

    private func hero(_ request: String) -> some View {
        LooprSurface(emphasis: .hero(.movement)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                StatusChip("Built from your request", symbol: "sparkles", accent: .movement)
                LooprText("\"\(request)\"", style: .settingsRow)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Built from your request. \(request)")
        .accessibilityIdentifier("program-hero")
    }

    // MARK: Weeks

    private var weeksSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader(model.weeksTitle, detail: model.lighterCaption, identifier: "program-weeks-header")
            ProgramWeeksGrid(model: model, identifier: "program-grid")
            if let note = model.hardDayNote {
                LooprText(note, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("program-hard-day-note")
            }
        }
    }

    // MARK: Rules

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Rules")
            LooprCard(density: .flush) {
                VStack(spacing: LooprSpacing.none) {
                    LooprToggleRow(title: model.earlyLight.title, subtitle: model.earlyLight.subtitle, accent: .movement,
                                   identifier: "program-rule-early-light",
                                   isOn: Binding(get: { model.earlyLightOn }, set: { actions.setEarlyLightWeek($0) }))
                    hairline
                    missedRow
                    hairline
                    LooprToggleRow(title: model.calendarTitle, accent: .movement, identifier: "program-rule-calendar",
                                   isOn: Binding(get: { model.calendarOn }, set: { actions.setCalendarExport($0) }))
                        .disabled(model.calendarLocked)
                }
            }
            if let note = model.calendarNote {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprText(note, style: .body, color: model.calendarDenied ? .critical : .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, LooprSpacing.xs)
                        .accessibilityIdentifier(model.calendarDenied ? "program-calendar-denied" : "program-calendar-note")
                    if model.calendarDenied {
                        Button("Open Settings") { actions.openSettings() }
                            .buttonStyle(LooprButtonStyle(prominent: false, accent: .movement))
                            .accessibilityIdentifier("program-calendar-settings")
                    }
                }
            }
        }
    }

    private var missedRow: some View {
        let summary = "\(model.missed.title), \(model.missed.subtitle ?? "")"
        return Button { showsMissed = true } label: {
            HStack(spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(model.missed.title, style: .settingsRow)
                    if let subtitle = model.missed.subtitle {
                        LooprText(subtitle, style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LooprChevron()
            }
            .padding(.horizontal, LooprSpacing.formCardPadding)
            .padding(.vertical, LooprSpacing.formRowVerticalPadding)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
        .accessibilityHint("Choose what happens to a missed session")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("program-rule-missed")
    }

    // MARK: So far

    private func soFarSection(_ soFar: ProgramScreenModel.SoFar) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("So far")
            LooprCard {
                VStack(spacing: LooprSpacing.none) {
                    HairlineMetricRow(id: "program-sessions-done", title: "Sessions done", value: soFar.sessionsValue,
                                      valueStyle: .settingsRow)
                    if let title = soFar.liftTitle, let value = soFar.liftValue {
                        hairline
                        HairlineMetricRow(id: "program-lift", title: title, value: value, valueStyle: .settingsRow)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("program-so-far")
        }
    }

    private var changesSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Changes")
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    ForEach(Array(model.changes.enumerated()), id: \.offset) { _, line in
                        LooprText(line, style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("program-changes")
        }
    }

    private var hairline: some View {
        Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline)
            .padding(.horizontal, LooprSpacing.cardHorizontal).accessibilityHidden(true)
    }
}

/// What happens when a planned session is missed. Two choices, one tap each.
struct ProgramMissedRuleSheet: View {
    let selection: MissedSessionRule
    let choose: @MainActor (MissedSessionRule) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprText("Choose what Loopr does when you miss a planned session.", style: .prose, color: .inkSecondary)
                        .padding(.horizontal, LooprSpacing.xxs)
                    LooprCard(density: .flush) {
                        VStack(spacing: LooprSpacing.none) {
                            option(.moveBack, title: "Move it back", identifier: "program-missed-move-back")
                            Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline)
                                .padding(.horizontal, LooprSpacing.cardHorizontal).accessibilityHidden(true)
                            option(.skip, title: "Skip it", identifier: "program-missed-skip")
                        }
                    }
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.md)
            }
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle("Missed session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("program-missed-cancel")
                }
            }
        }
        .tint(Color.loopr(.movement))
        .presentationDetents([.medium])
        .accessibilityIdentifier("program-missed-sheet")
    }

    private func option(_ rule: MissedSessionRule, title: String, identifier: String) -> some View {
        Button { choose(rule) } label: {
            HStack(spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(title, style: .settingsRow)
                    LooprText(ProgramScreenModel.missedText(rule), style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if rule == selection {
                    Image(systemName: "checkmark").foregroundStyle(Color.loopr(.movement)).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, LooprSpacing.formCardPadding)
            .padding(.vertical, LooprSpacing.formRowVerticalPadding)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(ProgramScreenModel.missedText(rule))")
        .accessibilityAddTraits(rule == selection ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }
}
