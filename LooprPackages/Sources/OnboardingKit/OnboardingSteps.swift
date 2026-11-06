#if os(iOS)
import DesignSystem
import ProfileKit
import SwiftUI
import UIKit

// The onboarding steps: nine with a band, six without. Each is a hero, a headline and the sections
// under it; `OnboardingScreen` supplies the header, the scroll view, the
// background and the buttons.

// MARK: - Preparing

struct OnboardingPreparingStep: View {
    var body: some View {
        VStack(spacing: LooprSpacing.xl) {
            OnboardingBrandMark(diameter: OnboardingMetrics.heroRing)
            StateMessage(.loading, compact: true)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, LooprSpacing.hero)
    }
}

// MARK: - Welcome

struct OnboardingWelcomeStep: View {
    let accent: LooprColorToken

    var body: some View {
        OnboardingStepLayout(
            title: OnboardingCopy.Welcome.title,
            detail: OnboardingCopy.Welcome.promise
        ) {
            OnboardingBrandMark()
                .padding(.vertical, LooprSpacing.sm)
        } content: {
            // What works without a band, said before the person picks a path.
            LooprText(OnboardingCopy.Welcome.noBandLine, style: .prose, color: .inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, LooprSpacing.xs)
                .accessibilityIdentifier("onboarding-welcome-no-band-line")
            OnboardingSection(OnboardingCopy.Welcome.sectionTitle) {
                OnboardingListCard {
                    OnboardingInfoRow(
                        symbol: "person.crop.circle.badge.xmark",
                        title: OnboardingCopy.Welcome.accountTitle,
                        detail: OnboardingCopy.Welcome.accountDetail,
                        accent: accent
                    )
                    LooprHairline()
                    OnboardingInfoRow(
                        symbol: "lock.shield",
                        title: OnboardingCopy.Welcome.privateTitle,
                        detail: OnboardingCopy.Welcome.privateDetail,
                        accent: accent
                    )
                    // Ask and its API key are explained in Settings, where they are turned on; on Welcome the key read as
                    // a chore before anything else (UX R1-NEW-02).
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("onboarding-privacy")
            }
            OnboardingSection(OnboardingCopy.Welcome.goodToKnowTitle) {
                OnboardingListCard {
                    OnboardingInfoRow(
                        symbol: "heart.text.clipboard",
                        title: OnboardingCopy.Welcome.wellnessTitle,
                        detail: OnboardingDisclosureCopy.healthBoundary,
                        accent: accent
                    )
                    LooprHairline()
                    OnboardingInfoRow(
                        symbol: "info.circle",
                        title: OnboardingCopy.Welcome.independentTitle,
                        detail: OnboardingDisclosureCopy.nonAffiliation,
                        accent: accent
                    )
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("onboarding-disclosures")
            }
        }
    }
}

// MARK: - WHOOP handover

/// Gets the WHOOP app off the band before Loopr pairs: Bluetooth access
/// off (it survives restarts), swipe the app away (drops today's link), and
/// the same on any other phone or iPad.
struct OnboardingHandoverStep: View {
    let accent: LooprColorToken

    var body: some View {
        OnboardingStepLayout(
            title: OnboardingCopy.Handover.title,
            detail: OnboardingCopy.Handover.detail
        ) {
            OnboardingSettingsMock(accent: accent)
                .padding(.top, LooprSpacing.xs)
        } content: {
            OnboardingSection(OnboardingCopy.Handover.sectionTitle) {
                VStack(spacing: LooprSpacing.sm) {
                    OnboardingStepCard(
                        number: 1,
                        title: OnboardingCopy.Handover.bluetoothTitle,
                        detail: OnboardingCopy.Handover.bluetoothDetail,
                        accent: accent
                    ) {
                        OnboardingSymbolTile(symbol: "switch.2", accent: accent)
                    } extra: {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            OnboardingSettingsButton(title: OnboardingCopy.Handover.openSettings, accent: accent)
                                .accessibilityIdentifier("onboarding-handover-open-settings")
                            LooprText(OnboardingCopy.Handover.openSettingsNote, style: .caption, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    OnboardingStepCard(
                        number: 2,
                        title: OnboardingCopy.Handover.swipeTitle,
                        detail: OnboardingCopy.Handover.swipeDetail,
                        accent: accent
                    ) {
                        OnboardingSymbolTile(symbol: "arrow.up.to.line", accent: accent)
                    }
                    OnboardingStepCard(
                        number: 3,
                        title: OnboardingCopy.Handover.otherDeviceTitle,
                        detail: OnboardingCopy.Handover.otherDeviceDetail,
                        accent: accent
                    ) {
                        OnboardingSymbolTile(symbol: "ipad.and.iphone", accent: accent)
                    }
                }
            }
            .accessibilityIdentifier("onboarding-handover-steps")
            LooprText(OnboardingCopy.Handover.reverseNote, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, LooprSpacing.xxs)
        }
    }
}

// MARK: - Pairing mode

/// "Get your band ready": the WHOOP app's Bluetooth off, then pairing mode, on one screen. These were two steps
/// before the UX simplification (UX R1-DES-02, R1-NEW-01).
struct OnboardingPrepareStep: View {
    let accent: LooprColorToken

    var body: some View {
        // The header already says "Your band"; the photo is a third of the screen so the steps show at once
        // (UX R2-DES-19).
        OnboardingStepLayout(
            title: nil,
            detail: OnboardingCopy.Prepare.detail
        ) {
            OnboardingBandArt(preferred: [.pairing, .product])
                .frame(maxWidth: OnboardingMetrics.bandWidth * 0.55)
        } content: {
            OnboardingSection(OnboardingCopy.Prepare.sectionTitle) {
                VStack(spacing: LooprSpacing.sm) {
                    OnboardingStepCard(
                        number: 1,
                        title: OnboardingCopy.Prepare.whoopTitle,
                        detail: OnboardingCopy.Prepare.whoopDetail,
                        accent: accent
                    ) {
                        OnboardingSymbolTile(symbol: "switch.2", accent: accent)
                    } extra: {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            OnboardingSettingsButton(title: OnboardingCopy.Handover.openSettings, accent: accent)
                                .accessibilityIdentifier("onboarding-handover-open-settings")
                            LooprText(OnboardingCopy.Handover.openSettingsNote, style: .caption, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    OnboardingStepCard(
                        number: 2,
                        title: OnboardingCopy.Prepare.tapTitle,
                        detail: OnboardingCopy.Prepare.tapDetail,
                        accent: accent
                    ) {
                        OnboardingBandTile(preferred: [.tap], fallbackSymbol: "hand.tap", accent: accent)
                    }
                }
            }
            .accessibilityIdentifier("onboarding-prepare-steps")
            // Not steps: a new band and a phone without the WHOOP app are exceptions, said once each (UX R2-NEW-03).
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprText(OnboardingCopy.Prepare.noWhoopNote, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                LooprText(OnboardingCopy.Prepare.newBandNote, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, LooprSpacing.xxs)
        }
    }
}

// MARK: - Pairing

struct OnboardingPairingStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showHelp = false

    let phase: OnboardingPairingPhase
    let pairingRequested: Bool
    let sharedLinkHint: Bool
    let experimentalSupportEnabled: Bool
    let setExperimentalSupport: (Bool) -> Void
    let accent: LooprColorToken

    /// noop's rule: give the sheet a calm beat before offering help.
    static let helpDelay: Duration = .seconds(12)

    var body: some View {
        OnboardingStepLayout(
            title: OnboardingCopy.Pairing.title(for: phase),
            detail: OnboardingCopy.Pairing.detail(for: phase)
        ) {
            OnboardingPairingHero(phase: phase, accent: accent)
        } content: {
            if phase == .connected, sharedLinkHint {
                sharedLinkCard
            }
            if phase == .bondRepair {
                bondRepairCard
            } else if showHelp, phase.offersFindHelp {
                helpCard
                    .transition(.opacity)
            }
            if phase == .idle || phase == .confirmReady {
                OnboardingSection(OnboardingCopy.Pairing.sectionTitle) {
                    OnboardingListCard {
                        OnboardingInfoRow(
                            symbol: "timer",
                            title: OnboardingCopy.Pairing.timingTitle,
                            detail: OnboardingCopy.Pairing.timingDetail,
                            accent: accent
                        )
                        LooprHairline()
                        OnboardingInfoRow(
                            symbol: "iphone.radiowaves.left.and.right",
                            title: OnboardingCopy.Pairing.nearbyTitle,
                            detail: OnboardingCopy.Pairing.nearbyDetail,
                            accent: accent
                        )
                    }
                }
            }
            if phase != .connected && phase != .connecting {
                OnboardingSection(OnboardingCopy.Pairing.supportedTitle) {
                    OnboardingListCard {
                        OnboardingInfoRow(
                            symbol: "checkmark.shield",
                            title: OnboardingCopy.Pairing.stableTitle,
                            detail: OnboardingCopy.Pairing.stableDetail,
                            accent: accent
                        )
                        LooprHairline()
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            OnboardingInfoRow(
                                symbol: "flask",
                                title: OnboardingCopy.Pairing.experimentalTitle,
                                detail: OnboardingCopy.Pairing.experimentalDetail,
                                accent: accent
                            )
                            Toggle(
                                OnboardingCopy.Pairing.experimentalSwitch,
                                isOn: Binding(
                                    get: { experimentalSupportEnabled },
                                    set: setExperimentalSupport
                                )
                            )
                            .tint(Color.loopr(accent))
                            .accessibilityIdentifier("onboarding-experimental-support")
                        }
                    }
                }
                .accessibilityIdentifier("onboarding-supported-band")
            }
        }
        .task(id: phaseKey) { await updateHelp() }
        // The band answering is the moment onboarding builds up to.
        .sensoryFeedback(.success, trigger: phase) { _, new in new == .connected }
    }

    private var phaseKey: String {
        switch phase {
        case .failed: "failed"
        default: String(describing: phase)
        }
    }

    private func updateHelp() async {
        guard phase.offersFindHelp else {
            showHelp = false
            return
        }
        guard phase.findHelpWaits else {
            showHelp = true
            return
        }
        showHelp = false
        try? await Task.sleep(for: Self.helpDelay)
        guard !Task.isCancelled else { return }
        if OnboardingMotion(systemReduceMotion: reduceMotion).isReduced {
            showHelp = true
        } else {
            withAnimation(.easeOut(duration: LooprMotion.standard)) { showHelp = true }
        }
    }

    private var helpCard: some View {
        LooprSurface(emphasis: .hero(accent)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText(OnboardingCopy.Pairing.helpTitle(for: phase), style: .cardTitle)
                LooprText(OnboardingCopy.Pairing.helpIntro, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    ForEach(OnboardingCopy.Pairing.helpItems, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                            Image(systemName: "circle")
                                .looprTypography(.metricUnit)
                                .foregroundStyle(Color.loopr(accent.spectralChipLabel))
                                .accessibilityHidden(true)
                            LooprText(item, style: .prose)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding-pairing-help")
    }

    /// Only after a bond error: Forget This Device is the one fix, and it
    /// has a cost the person should know first.
    private var bondRepairCard: some View {
        OnboardingSection(OnboardingCopy.Pairing.bondRepairSectionTitle) {
            LooprSurface(emphasis: .hero(accent)) {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    ForEach(Array(OnboardingCopy.Pairing.bondRepairSteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                            Text("\(index + 1)")
                                .looprTypography(.metricUnit)
                                .foregroundStyle(Color.loopr(accent.spectralChipLabel))
                                .frame(width: LooprSpacing.xl, height: LooprSpacing.xl)
                                .background(Color.loopr(accent).opacity(0.14), in: Circle())
                                .accessibilityHidden(true)
                            LooprText(step, style: .prose)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Step \(index + 1). \(step)")
                    }
                    LooprHairline()
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                        Image(systemName: "exclamationmark.triangle")
                            .looprTypography(.rowTitle)
                            .foregroundStyle(Color.loopr(.caution))
                            .accessibilityHidden(true)
                        LooprText(OnboardingCopy.Pairing.bondRepairWarning, style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-pairing-bond-repair")
    }

    /// A hint, not a verdict: iOS reported a link Loopr did not open, and
    /// cannot say which app holds it.
    private var sharedLinkCard: some View {
        LooprSurface(emphasis: .hero(accent)) {
            OnboardingInfoRow(
                symbol: "antenna.radiowaves.left.and.right",
                title: OnboardingCopy.Pairing.sharedLinkTitle,
                detail: OnboardingCopy.Pairing.sharedLinkDetail,
                accent: accent
            )
            .padding(.vertical, -LooprSpacing.sm)
        }
        .accessibilityIdentifier("onboarding-pairing-shared-link")
    }
}

// MARK: - Profile

struct OnboardingProfileStep: View {
    @Binding var form: OnboardingProfileForm
    /// True while a field has the keyboard. The action bar then shows Hide keyboard, and setting it false closes the keyboard.
    @Binding var editing: Bool
    let timeZone: TimeZone
    let now: Date
    let accent: LooprColorToken
    @FocusState private var focused: Field?
    /// "More about you" open. It starts open when the person already filled something in it.
    @State private var showsMore = false

    enum Field: Hashable { case name, birthYear, height, inches, weight }

    private var currentYear: Int { ProfileEstimates.currentYear(for: now) }

    var body: some View {
        // No max heart rate card above the form any more: a formula was the first thing a newcomer read (UX R1-NEW-03).
        // The zones page explains it where it is used.
        OnboardingStepLayout(title: nil, detail: OnboardingCopy.Profile.detail) {
            EmptyView()
        } content: {
            OnboardingSection(OnboardingCopy.Profile.youSection) {
                OnboardingListCard {
                    fieldRow(OnboardingCopy.Profile.birthYearTitle, placeholder: OnboardingCopy.Profile.birthYearPlaceholder,
                             text: $form.birthYear, field: .birthYear, keyboard: .numberPad,
                             unit: form.age(currentYear: currentYear).map { OnboardingCopy.Profile.ageCaption($0) },
                             id: "profile-birth-year")
                    LooprHairline()
                    chipsRow(OnboardingCopy.Profile.sexTitle) {
                        OnboardingChoiceChips(
                            title: OnboardingCopy.Profile.sexTitle,
                            options: OnboardingProfileForm.SexChoice.allCases,
                            label: \.title,
                            selection: $form.sex,
                            accent: accent,
                            identifier: { "profile-sex-\($0.rawValue)" }
                        )
                    }
                }
            }

            // Name, units, height and weight wait under one row: day one asks for two things (UX R2-NEW-04, R2-DES-20).
            LooprFoldSection(OnboardingCopy.Profile.moreTitle, summary: OnboardingCopy.Profile.moreSummary,
                             identifier: "profile-more", isOpen: $showsMore) {
              OnboardingListCard {
                  fieldRow(OnboardingCopy.Profile.nameTitle, placeholder: OnboardingCopy.Profile.namePlaceholder,
                           text: $form.name, field: .name, keyboard: .default, id: "profile-name")
              }
              OnboardingSection(OnboardingCopy.Profile.bodySection) {
                OnboardingListCard {
                    chipsRow(OnboardingCopy.Profile.unitsTitle) {
                        OnboardingChoiceChips(
                            title: OnboardingCopy.Profile.unitsTitle,
                            options: UnitSystem.allCases,
                            label: { $0 == .metric ? "Metric" : "Imperial" },
                            selection: Binding(
                                get: { Optional(form.unitSystem) },
                                set: { if let value = $0 { form.switchUnits(to: value) } }
                            ),
                            accent: accent,
                            allowsDeselect: false,
                            segmented: true,
                            identifier: { "profile-units-\($0.rawValue)" }
                        )
                    }
                    LooprHairline()
                    if form.unitSystem == .metric {
                        fieldRow(OnboardingCopy.Profile.heightTitle, placeholder: "", text: $form.heightPrimary,
                                 field: .height, keyboard: .decimalPad, unit: "cm", id: "profile-height")
                    } else {
                        imperialHeightRow
                    }
                    LooprHairline()
                    fieldRow(OnboardingCopy.Profile.weightTitle, placeholder: "", text: $form.weight,
                             field: .weight, keyboard: .decimalPad,
                             unit: form.unitSystem == .metric ? "kg" : "lb", id: "profile-weight")
                }
              }
            }

            ForEach(form.issues(currentYear: currentYear), id: \.message) { issue in
                LooprInlineMessage(issue.message, tone: .warning)
                    .accessibilityIdentifier("profile-issue")
            }

            LooprText(
                OnboardingCopy.Profile.timeZone(OnboardingFacts.timeZoneLabel(timeZone, at: now)),
                style: .caption,
                color: .inkSecondary
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, LooprSpacing.xxs)
            .accessibilityIdentifier("profile-time-zone")
        }
        // Hide keyboard lives in the action bar: a keyboard toolbar floats over Continue on iOS 27.
        .onAppear {
            if !form.name.isEmpty || !form.heightPrimary.isEmpty || !form.weight.isEmpty { showsMore = true }
        }
        .onChange(of: focused) { _, field in editing = field != nil }
        .onChange(of: editing) { _, value in if !value { focused = nil } }
    }

    private var imperialHeightRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
            LooprText(OnboardingCopy.Profile.heightTitle, style: .settingsRow)
            Spacer(minLength: LooprSpacing.sm)
            numberField(text: $form.heightPrimary, field: .height, keyboard: .numberPad, label: "Height, feet", id: "profile-height")
                .frame(maxWidth: LooprSpacing.formButtonHeight)
            LooprText("ft", style: .metricUnit, color: .inkSecondary)
            numberField(text: $form.heightInches, field: .inches, keyboard: .numberPad, label: "Height, inches", id: "profile-height-inches")
                .frame(maxWidth: LooprSpacing.formButtonHeight)
            LooprText("in", style: .metricUnit, color: .inkSecondary)
        }
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
    }

    private func fieldRow(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        field: Field,
        keyboard: UIKeyboardType,
        unit: String? = nil,
        id: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
            LooprText(title, style: .settingsRow)
                .layoutPriority(1)
            Spacer(minLength: LooprSpacing.sm)
            numberField(text: text, field: field, keyboard: keyboard, label: title, id: id, placeholder: placeholder)
            if let unit {
                LooprText(unit, style: .metricUnit, color: .inkSecondary)
            }
        }
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { focused = field }
    }

    private func numberField(
        text: Binding<String>,
        field: Field,
        keyboard: UIKeyboardType,
        label: String,
        id: String,
        placeholder: String = ""
    ) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .keyboardType(keyboard)
            .textContentType(field == .name ? .givenName : nil)
            .autocorrectionDisabled(field != .name)
            .looprTypography(field == .name ? .settingsRow : .metricValue)
            .foregroundStyle(Color.loopr(.ink))
            .multilineTextAlignment(.trailing)
            .focused($focused, equals: field)
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
    }

    private func chipsRow<Chips: View>(_ title: String, @ViewBuilder chips: () -> Chips) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprText(title, style: .settingsRow)
            chips()
        }
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Apple Health

/// States exactly what the one iOS sheet asks for: the types Loopr saves and
/// the types it reads, taken from the request itself.
struct OnboardingHealthStep: View {
    let request: OnboardingHealthRequest
    let accent: LooprColorToken

    var body: some View {
        OnboardingStepLayout(
            title: OnboardingCopy.Health.title(for: request),
            detail: OnboardingCopy.Health.detail(for: request)
        ) {
            // The two count rings ("8 Reads, 8 Saves") said nothing a person could use; the lists below say it
            // (UX R1-DES-23, R1-NEW-04).
            EmptyView()
        } content: {
            if request.importsHistory {
                typeList(OnboardingCopy.Health.readsTitle, request.orderedReads, id: "onboarding-health-reads")
            }
            typeList(OnboardingCopy.Health.savesTitle, request.orderedWrites, id: "onboarding-health-writes")
            LooprText(OnboardingCopy.Health.choiceNote, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, LooprSpacing.xxs)
        }
    }

    private func typeList(_ title: String, _ types: [OnboardingHealthType], id: String) -> some View {
        OnboardingSection(title) {
            LooprSurface {
                OnboardingFlowLayout(spacing: LooprSpacing.xs) {
                    ForEach(types) { type in
                        OnboardingTypeTag(type: type, accent: accent)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OnboardingCopy.Health.spokenList(title, types))
        .accessibilityIdentifier(id)
    }
}

// MARK: - Notifications

struct OnboardingNotificationsStep: View {
    let path: OnboardingPath
    let accent: LooprColorToken

    private var onGroups: [OnboardingNotificationGroup] { OnboardingCopy.Notifications.onGroups(on: path) }

    var body: some View {
        OnboardingStepLayout(
            title: OnboardingCopy.Notifications.title,
            detail: OnboardingCopy.Notifications.detail(on: path)
        ) {
            OnboardingNotificationMock(samples: OnboardingCopy.Notifications.sample(on: path))
                .padding(.top, LooprSpacing.sm)
        } content: {
            OnboardingSection(OnboardingCopy.Notifications.onSection) {
                OnboardingListCard {
                    ForEach(Array(onGroups.enumerated()), id: \.element) { index, group in
                        if index > 0 { LooprHairline() }
                        row(group)
                    }
                }
            }
            .accessibilityIdentifier("onboarding-notifications-on")
            if !OnboardingNotificationGroup.offUntilChosen.families.isEmpty {
                OnboardingSection(OnboardingCopy.Notifications.offSection) {
                    OnboardingListCard { row(.offUntilChosen) }
                }
                .accessibilityIdentifier("onboarding-notifications-off")
            }
        }
    }

    private func row(_ group: OnboardingNotificationGroup) -> some View {
        OnboardingInfoRow(
            symbol: OnboardingCopy.Notifications.symbol(for: group),
            title: OnboardingCopy.Notifications.title(for: group),
            detail: OnboardingCopy.Notifications.detail(for: group, on: path),
            accent: accent
        )
    }
}

// MARK: - Sleep need

struct OnboardingSleepNeedStep: View {
    @Binding var selection: Double?
    let accent: LooprColorToken

    var body: some View {
        OnboardingStepLayout(
            title: OnboardingCopy.SleepNeedStep.title,
            detail: OnboardingCopy.SleepNeedStep.detail
        ) {
            let hours = selection ?? OnboardingFacts.defaultSleepNeedHours
            LooprProgressRing(
                value: hours,
                scale: LooprRingScale(fullValue: hours),
                text: OnboardingCopy.SleepNeedStep.ringText(hours),
                caption: OnboardingCopy.SleepNeedStep.ringCaption,
                accent: accent,
                diameter: OnboardingMetrics.heroRing
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(OnboardingCopy.SleepNeedStep.ringCaption), \(OnboardingCopy.SleepNeedStep.label(hours)) hours")
            .accessibilityIdentifier("onboarding-sleep-need-value")
        } content: {
            OnboardingChoiceChips(
                    title: OnboardingCopy.SleepNeedStep.headerTitle,
                    options: OnboardingCopy.SleepNeedStep.options,
                    label: { OnboardingCopy.SleepNeedStep.ringText($0) },
                    selection: $selection,
                    accent: accent,
                    allowsDeselect: false,
                    segmented: true,
                    identifier: { "onboarding-sleep-goal-\(OnboardingCopy.SleepNeedStep.label($0))" }
                )
            LooprText(
                OnboardingCopy.SleepNeedStep.skipNote(defaultHours: OnboardingFacts.defaultSleepNeedHours),
                style: .caption,
                color: .inkSecondary
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, LooprSpacing.xxs)
        }
    }
}

// MARK: - Finish

struct OnboardingFinishStep: View {
    /// The person said they have no band: no nights to learn, nothing to
    /// wear or sync. The step says where to start instead.
    let withoutBand: Bool
    let pairingDeferred: Bool
    let bandStillConnecting: Bool
    let backgroundRefreshOff: Bool
    let accent: LooprColorToken

    private var nights: Int { OnboardingFacts.recoveryLearningNights }

    var body: some View {
        if withoutBand {
            noBandBody
        } else {
            bandBody
        }
    }

    private var noBandBody: some View {
        OnboardingStepLayout(title: OnboardingCopy.Finish.title, detail: nil) {
            OnboardingBrandMark()
                .padding(.vertical, LooprSpacing.sm)
        } content: {
            OnboardingSection(OnboardingCopy.Finish.noBandSectionTitle) {
                OnboardingListCard {
                    OnboardingInfoRow(
                        symbol: "fork.knife",
                        title: OnboardingCopy.Finish.mealTitle,
                        detail: OnboardingCopy.Finish.mealDetail,
                        accent: accent
                    )
                    LooprHairline()
                    OnboardingInfoRow(
                        symbol: "checklist",
                        title: OnboardingCopy.Finish.protocolTitle,
                        detail: OnboardingCopy.Finish.protocolDetail,
                        accent: accent
                    )
                    LooprHairline()
                    OnboardingInfoRow(
                        symbol: "antenna.radiowaves.left.and.right",
                        title: OnboardingCopy.Finish.addBandTitle,
                        detail: OnboardingCopy.Finish.addBandDetail,
                        accent: accent
                    )
                    .accessibilityIdentifier("onboarding-finish-add-band")
                }
            }
            .accessibilityIdentifier("onboarding-finish-no-band")
        }
    }

    private var bandBody: some View {
        OnboardingStepLayout(
            title: pairingDeferred ? OnboardingCopy.Finish.deferredTitle : OnboardingCopy.Finish.title,
            detail: nil
        ) {
            // A ring at "0/3" was the first thing a new person saw of their data: a score of nothing (UX R1-DES-02,
            // R1-NEW-05). The mark welcomes them instead; the rows say when recovery comes.
            OnboardingBrandMark()
                .padding(.vertical, LooprSpacing.sm)
        } content: {
            if backgroundRefreshOff {
                LooprSurface(emphasis: .hero(accent)) {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        OnboardingInfoRow(
                            symbol: "arrow.clockwise",
                            title: OnboardingCopy.Finish.refreshTitle,
                            detail: OnboardingCopy.Finish.refreshDetail,
                            accent: accent
                        )
                        OnboardingSettingsButton(title: OnboardingCopy.Finish.openSettings, accent: accent)
                            .accessibilityIdentifier("onboarding-finish-open-settings")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("onboarding-finish-background-refresh")
            }
            // What works today leads; the band rows follow, and a skipped band comes last instead of first
            // (UX R2-NEW-06, R2-DES-21).
            OnboardingSection(OnboardingCopy.Finish.sectionTitle) {
                OnboardingListCard {
                    OnboardingInfoRow(
                        symbol: "checklist",
                        title: OnboardingCopy.Finish.longevityTitle,
                        detail: OnboardingCopy.Finish.longevityDetail,
                        accent: accent
                    )
                    .accessibilityIdentifier("onboarding-finish-longevity")
                    LooprHairline()
                    if bandStillConnecting {
                        OnboardingInfoRow(
                            symbol: "antenna.radiowaves.left.and.right",
                            title: OnboardingCopy.Finish.connectingTitle,
                            detail: OnboardingCopy.Finish.connectingDetail,
                            accent: accent
                        )
                        .accessibilityIdentifier("onboarding-finish-connecting")
                        LooprHairline()
                    }
                    if !pairingDeferred {
                        OnboardingInfoRow(
                            symbol: "moon.zzz",
                            title: OnboardingCopy.Finish.wearTitle,
                            detail: OnboardingCopy.Finish.wearDetail + " " + OnboardingCopy.Finish.baselineDetail(nights: nights),
                            accent: accent
                        )
                    } else {
                        OnboardingInfoRow(
                            symbol: "antenna.radiowaves.left.and.right",
                            title: OnboardingCopy.Finish.laterTitle,
                            detail: OnboardingCopy.Finish.laterDetail,
                            accent: accent
                        )
                        .accessibilityIdentifier("onboarding-finish-later")
                    }
                }
            }
        }
    }
}

// MARK: - Settings link

/// Opens Loopr's own page in the Settings app, the one place a public API
/// can reach. Background App Refresh lives on that page; for the WHOOP
/// switch the person goes back one level.
struct OnboardingSettingsButton: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let accent: LooprColorToken

    var body: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        } label: {
            Label(title, systemImage: "gear")
                .looprTypography(.label)
                .foregroundStyle(Color.loopr(accent.textInk))
                .frame(maxWidth: .infinity, minHeight: LooprSpacing.formButtonHeight)
                .background(
                    Color.loopr(accent).opacity(isDark ? 0.13 : 0.10),
                    in: RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous)
                        .strokeBorder(Color.loopr(accent).opacity(0.25), lineWidth: LooprSpacing.hairline)
                }
                .contentShape(RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}
#endif
