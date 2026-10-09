#if os(iOS)
import DesignSystem
import ProfileKit
import SwiftUI
import UIKit
#if canImport(DataKit)
import DataKit
#endif

/// Everything the onboarding screen can ask the app to do. The app owns the
/// controller, Bluetooth and the permission prompts; the package only draws.
public struct OnboardingActions {
    public var advance: () -> Void = {}
    public var back: () -> Void = {}
    public var requestPairing: () -> Void = {}
    public var confirmPairingSheet: () -> Void = {}
    public var deferPairing: () -> Void = {}
    public var setExperimentalSupport: (Bool) -> Void = { _ in }
    public var completeProfile: (ProfileDraft) -> Void = { _ in }
    public var requestPermission: (OnboardingPermission) -> Void = { _ in }
    public var skipPermission: (OnboardingPermission) -> Void = { _ in }
    public var saveSleepGoal: (Double) -> Void = { _ in }
    public var skipSleepGoal: () -> Void = {}
    public var finish: () -> Void = {}
    public var openDataControls: () -> Void = {}

    public init() {}
}

/// The onboarding flow, laid out the way the tabs are: a header with the
/// screen title and a mono meta line, the screen's colour washed in behind
/// everything, one hero, then sections. The step's actions stay pinned to
/// the bottom. Driven entirely by the controller's durable snapshot, so a
/// relaunch lands on the same step.
public struct OnboardingScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public let snapshot: OnboardingSnapshot
    public let pairingPhase: OnboardingPairingPhase
    public let health: OnboardingHealthRequest
    public let sharedLinkHint: Bool
    public let backgroundRefreshOff: Bool
    /// A band was chosen but its link is not up yet.
    public let bandStillConnecting: Bool
    public let errorMessage: String?
    public let isBusy: Bool
    public let actions: OnboardingActions
    private let now: Date
    private let timeZone: TimeZone

    @State private var profileForm = OnboardingProfileForm()
    @State private var profileFormLoaded = false
    @State private var sleepNeed: Double?
    @State private var movingBack = false
    @State private var headerIsScrolled = false

    public init(
        snapshot: OnboardingSnapshot,
        pairingPhase: OnboardingPairingPhase = .idle,
        health: OnboardingHealthRequest = .freshInstall,
        sharedLinkHint: Bool = false,
        backgroundRefreshOff: Bool = false,
        bandStillConnecting: Bool = false,
        errorMessage: String? = nil,
        isBusy: Bool = false,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        actions: OnboardingActions
    ) {
        self.snapshot = snapshot
        self.pairingPhase = pairingPhase
        self.health = health
        self.sharedLinkHint = sharedLinkHint
        self.backgroundRefreshOff = backgroundRefreshOff
        self.bandStillConnecting = bandStillConnecting
        self.errorMessage = errorMessage
        self.isBusy = isBusy
        self.now = now
        self.timeZone = timeZone
        self.actions = actions
    }

    public var body: some View {
        VStack(spacing: LooprSpacing.none) {
            header
                .zIndex(1)
            // Old and new steps overlap during the transition, so they share
            // a ZStack instead of splitting the height between them.
            ZStack(alignment: .top) {
                ScrollView {
                    stepContent
                        .padding(.horizontal, LooprSpacing.screenGutter)
                        .padding(.top, LooprSpacing.md)
                        // Clears the fade above the action bar, so the last
                        // row can scroll fully into view.
                        .padding(.bottom, Self.actionBarFade + LooprSpacing.sm)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > LooprSpacing.xxs
                } action: { _, scrolled in
                    headerIsScrolled = scrolled
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(stepIdentifier)
                .id(snapshot.stage)
                .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: LooprSpacing.none) {
            actionBar
        }
        // One wash for the whole screen, behind the header too, so there is
        // no seam where the header ends and the content begins.
        .background { LooprAmbientBackground(tint: accent) }
        .animation(motion.animation(LooprMotion.navigation), value: snapshot.stage)
        .onAppear {
            loadProfileFormIfNeeded()
            sleepNeed = snapshot.sleepGoalHours ?? OnboardingFacts.defaultSleepNeedHours
        }
        .onChange(of: snapshot.stage) { old, new in
            movingBack = (new.stepNumber ?? 0) < (old.stepNumber ?? 0)
            headerIsScrolled = false
            if new == .profileSetup { loadProfileFormIfNeeded() }
            // A new step is a new screen to VoiceOver: move focus to its top
            // instead of leaving it on the button that was just tapped.
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
        .toolbar(.hidden, for: .navigationBar)
        .tint(Color.loopr(accent))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-screen")
    }

    private var motion: OnboardingMotion { OnboardingMotion(systemReduceMotion: reduceMotion) }

    /// Height of the fade between the scrolling step and the action bar.
    private static let actionBarFade: CGFloat = 28

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }

    private var stepTransition: AnyTransition {
        if motion.isReduced { return .opacity }
        return .asymmetric(
            insertion: .move(edge: movingBack ? .leading : .trailing).combined(with: .opacity),
            removal: .opacity
        )
    }

    /// One accent per screen, matched to the step's domain as the tabs match
    /// theirs: crimson for the body and Apple Health, amber for alerts,
    /// violet for sleep, teal for the band and everything neutral. A pairing
    /// problem turns the pairing screen amber, buttons included.
    private var accent: LooprColorToken {
        switch snapshot.stage {
        case .profileSetup, .appleHealth: .heart
        case .notifications: .strain
        case .sleepGoal: .sleep
        case .pairing where pairingPhase.isProblem: .strain
        default: .brand
        }
    }

    private var stepIdentifier: String {
        switch snapshot.stage {
        case .launching, .mainShell: "onboarding-preparing"
        case .profileSetup: "profile-setup-screen"
        default: "onboarding-step-\(snapshot.stage.rawValue)"
        }
    }

    // MARK: Header

    /// The tabs' sticky header: title and mono meta, glass controls, and a
    /// material only once the content scrolls under it. The progress track
    /// sits where the header's hairline would.
    private var header: some View {
        VStack(spacing: LooprSpacing.xs) {
            if dynamicTypeSize.isAccessibilitySize {
                HStack {
                    backControl
                    Spacer()
                    dataControlsControl
                }
                headerCopy
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: LooprSpacing.sm) {
                    backControl
                    headerCopy
                        .frame(maxWidth: .infinity, alignment: .leading)
                    dataControlsControl
                }
            }
            if let step = snapshot.stage.stepNumber {
                OnboardingProgressTrack(step: step, total: OnboardingStage.stepCount, accent: accent)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(OnboardingCopy.Chrome.progress(step: step, of: OnboardingStage.stepCount))
                    .accessibilityIdentifier("onboarding-progress")
            }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .padding(.top, LooprSpacing.xs)
        .padding(.bottom, LooprSpacing.sm)
        .background {
            if headerIsScrolled {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.loopr(.background).opacity(isDark ? 0.78 : 0.86))
                    .ignoresSafeArea(edges: .top)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: LooprMotion.fast), value: headerIsScrolled)
    }

    @ViewBuilder
    private var backControl: some View {
        if snapshot.stage.previous != nil {
            glassButton(
                symbol: "chevron.left",
                label: OnboardingCopy.Chrome.back,
                identifier: "onboarding-back",
                action: actions.back
            )
            .disabled(isBusy)
        }
    }

    private var dataControlsControl: some View {
        glassButton(
            symbol: "ellipsis",
            label: OnboardingCopy.Chrome.dataControls,
            identifier: "open-onboarding-data-controls",
            action: actions.openDataControls
        )
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
            Text(OnboardingCopy.Chrome.headerTitle(for: snapshot.stage))
                .looprTypography(.screenTitle)
                .foregroundStyle(Color.loopr(.ink))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(0.7)
            if let step = snapshot.stage.stepNumber {
                Text(OnboardingCopy.Chrome.meta(
                    step: step,
                    of: OnboardingStage.stepCount,
                    optional: snapshot.stage.isOptional
                ))
                .looprTypography(.headerMeta)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(0.7)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .contentTransition(.opacity)
    }

    /// The same glass circle as the avatar button on the tabs.
    private func glassButton(symbol: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .looprTypography(.rowTitle)
                .foregroundStyle(Color.loopr(.ink))
                .frame(width: LooprSpacing.formButtonHeight, height: LooprSpacing.formButtonHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        switch snapshot.stage {
        case .launching, .mainShell:
            OnboardingPreparingStep()
        case .welcomeDisclosures:
            OnboardingWelcomeStep(accent: accent)
        case .whoopHandover:
            OnboardingHandoverStep(accent: accent)
        case .prepareBand:
            OnboardingPrepareStep(accent: accent)
        case .pairing:
            OnboardingPairingStep(
                phase: pairingPhase,
                pairingRequested: snapshot.pairingRequested,
                sharedLinkHint: sharedLinkHint,
                experimentalSupportEnabled: snapshot.betaConsent.isGranted,
                setExperimentalSupport: actions.setExperimentalSupport,
                accent: accent
            )
        case .profileSetup:
            OnboardingProfileStep(form: $profileForm, timeZone: timeZone, now: now, accent: accent)
        case .appleHealth:
            OnboardingHealthStep(request: health, accent: accent)
        case .notifications:
            OnboardingNotificationsStep(accent: accent)
        case .sleepGoal:
            OnboardingSleepNeedStep(selection: $sleepNeed, accent: accent)
        case .finish:
            OnboardingFinishStep(
                pairingDeferred: !snapshot.pairingRequested,
                bandStillConnecting: snapshot.pairingRequested && bandStillConnecting,
                backgroundRefreshOff: backgroundRefreshOff,
                accent: accent
            )
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actionBar: some View {
        if snapshot.stage != .launching && snapshot.stage != .mainShell {
            VStack(spacing: LooprSpacing.xxs) {
                if let errorMessage {
                    LooprInlineMessage(errorMessage, tone: .critical)
                        .accessibilityIdentifier("onboarding-error")
                        .padding(.bottom, LooprSpacing.xs)
                }
                actionButtons
            }
            .padding(.horizontal, LooprSpacing.screenGutter + LooprSpacing.xxs)
            .padding(.top, LooprSpacing.lg)
            .padding(.bottom, LooprSpacing.xxs)
            // The bar is solid page background, so nothing scrolled under it
            // reads through the buttons. A short fade above it lets the
            // content thin out before it meets Continue instead of being cut.
            .background(alignment: .top) {
                Color.loopr(.background)
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [Color.loopr(.background).opacity(0), Color.loopr(.background)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: Self.actionBarFade)
                        .offset(y: -Self.actionBarFade)
                        .allowsHitTesting(false)
                    }
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch snapshot.stage {
        case .launching, .mainShell:
            EmptyView()
        case .welcomeDisclosures:
            primary(OnboardingCopy.Welcome.action, id: "onboarding-continue", action: actions.advance)
        case .whoopHandover:
            primary(OnboardingCopy.Handover.action, id: "onboarding-handover-continue", action: actions.advance)
            secondary(OnboardingCopy.Handover.later, id: "onboarding-handover-later", action: actions.deferPairing)
        case .prepareBand:
            primary(OnboardingCopy.Prepare.action, id: "onboarding-prepare-continue", action: actions.advance)
            secondary(OnboardingCopy.Prepare.later, id: "onboarding-prepare-later", action: actions.deferPairing)
        case .pairing:
            pairingButtons
        case .profileSetup:
            primary(
                OnboardingCopy.Profile.action,
                id: "profile-save",
                enabled: profileForm.canSubmit
            ) {
                actions.completeProfile(profileForm.draft(
                    currentYear: ProfileEstimates.currentYear(for: now),
                    timeZone: timeZone
                ))
            }
        case .appleHealth:
            primary(OnboardingCopy.Health.allow, id: "onboarding-health-allow") {
                actions.requestPermission(.appleHealth)
            }
            secondary(OnboardingCopy.Health.skip, id: "onboarding-health-skip") {
                actions.skipPermission(.appleHealth)
            }
        case .notifications:
            primary(OnboardingCopy.Notifications.allow, id: "onboarding-notifications-allow") {
                actions.requestPermission(.notifications)
            }
            secondary(OnboardingCopy.Notifications.skip, id: "onboarding-notifications-skip") {
                actions.skipPermission(.notifications)
            }
        case .sleepGoal:
            primary(OnboardingCopy.SleepNeedStep.save, id: "onboarding-sleep-goal-save", enabled: sleepNeed != nil) {
                if let sleepNeed { actions.saveSleepGoal(sleepNeed) }
            }
            secondary(OnboardingCopy.SleepNeedStep.skip, id: "onboarding-sleep-goal-skip", action: actions.skipSleepGoal)
        case .finish:
            primary(OnboardingCopy.Finish.action, id: "onboarding-finish", action: actions.finish)
        }
    }

    @ViewBuilder
    private var pairingButtons: some View {
        if snapshot.pairingRequested && !pairingPhase.isProblem {
            primary(OnboardingCopy.Pairing.continueAction, id: "onboarding-pair-next", action: actions.advance)
        } else {
            switch pairingPhase {
            case .confirmReady:
                primary(OnboardingCopy.Pairing.showSheet, id: "onboarding-pair-continue", action: actions.confirmPairingSheet)
            case .choosing, .connecting:
                // The label stays the action; the spinner says it is under
                // way. A status in a button label reads as broken.
                primary(OnboardingCopy.Pairing.connect, id: "onboarding-pair", working: true, action: {})
            case .connected:
                primary(OnboardingCopy.Pairing.continueAction, id: "onboarding-pair-next", action: actions.advance)
            case .idle:
                primary(OnboardingCopy.Pairing.connect, id: "onboarding-pair", action: actions.requestPairing)
            case .bluetoothOff, .cancelled, .notFound, .bondRepair, .failed:
                primary(OnboardingCopy.Pairing.tryAgain, id: "onboarding-pair", action: actions.requestPairing)
            }
            if snapshot.pairingRequested {
                secondary(OnboardingCopy.Pairing.continueAction, id: "onboarding-pair-next", action: actions.advance)
            } else {
                // Without this, anyone whose band is flat, out of range, or
                // not yet delivered cannot get past onboarding at all.
                secondary(OnboardingCopy.Pairing.later, id: "onboarding-pair-later", action: actions.deferPairing)
            }
        }
    }

    private func primary(
        _ title: String,
        id: String,
        enabled: Bool = true,
        working: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        OnboardingPrimaryButton(
            title: title,
            accent: accent,
            isWorking: working || (isBusy && enabled),
            action: action
        )
        .disabled(!enabled || (isBusy && !working))
        .allowsHitTesting(!working)
        .accessibilityIdentifier(id)
    }

    private func secondary(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        OnboardingSecondaryButton(title: title, accent: accent, action: action)
            .disabled(isBusy)
            .accessibilityIdentifier(id)
    }

    private func loadProfileFormIfNeeded() {
        guard !profileFormLoaded else { return }
        profileFormLoaded = true
        if let draft = snapshot.profileDraft {
            profileForm = OnboardingProfileForm(draft: draft, currentYear: ProfileEstimates.currentYear(for: now))
        }
    }
}

// MARK: - Buttons

/// Onboarding's primary action and the band intro's Get started: the
/// design system's primary button in the screen's accent, at the 56 pt
/// height of `LooprButtonStyle`, with a spinner while it works.
public struct OnboardingPrimaryButton: View {
    private let title: String
    private let accent: LooprColorToken
    private let isWorking: Bool
    private let action: () -> Void

    public init(title: String, accent: LooprColorToken = .brand, isWorking: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.accent = accent
        self.isWorking = isWorking
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: LooprSpacing.xs) {
                if isWorking {
                    ProgressView()
                        .tint(Color.loopr(.background))
                        .accessibilityHidden(true)
                }
                Text(title)
            }
            .frame(maxWidth: .infinity, minHeight: LooprButtonStyle.minimumTargetHeight)
            .contentShape(RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous))
        }
        .buttonStyle(LooprPrimaryButtonStyle(accent: accent))
        .accessibilityValue(isWorking ? Text("In progress") : Text(""))
    }
}

/// The quiet second choice: a text button in the accent's text ink.
struct OnboardingSecondaryButton: View {
    let title: String
    let accent: LooprColorToken
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .looprTypography(.label)
                .foregroundStyle(Color.loopr(accent.textInk))
                .frame(maxWidth: .infinity, minHeight: LooprSpacing.formButtonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step layout

/// The body of one step: a hero, a centred headline and sentence under it
/// (as the tabs put a verdict under their ring), then the sections.
struct OnboardingStepLayout<Hero: View, Content: View>: View {
    let title: String?
    let detail: String?
    let hero: Hero
    let content: Content

    init(
        title: String?,
        detail: String?,
        @ViewBuilder hero: () -> Hero,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.hero = hero()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xl) {
            hero
                .frame(maxWidth: .infinity)
            if title != nil || detail != nil {
                VStack(spacing: LooprSpacing.xs) {
                    if let title {
                        LooprText(title, style: .title)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("onboarding-step-title")
                    }
                    if let detail {
                        LooprText(detail, style: .prose, color: .inkSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, LooprSpacing.xs)
            }
            content
        }
    }
}

/// A section: the tabs' grey mono eyebrow over its content.
struct OnboardingSection<Content: View>: View {
    let title: String
    let detail: String?
    let content: Content

    init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader(title, detail: detail)
            content
        }
    }
}

// MARK: - Destructive actions

@available(macOS 13.0, iOS 17.0, *)
public struct OnboardingDestructiveActionsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingResetProfileConfirmation = false
    @State private var showingForgetBandConfirmation = false
    @State private var showingDeleteAllDataConfirmation = false

    public let onConfirm: (OnboardingDestructiveAction) -> Void

    public init(onConfirm: @escaping (OnboardingDestructiveAction) -> Void) {
        self.onConfirm = onConfirm
    }

    public var body: some View {
        LooprDetailScaffold {
            VStack(alignment: .leading, spacing: LooprSpacing.xl) {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprText("Data controls", style: .titleLarge)
                        .accessibilityAddTraits(.isHeader)
                    LooprText(
                        OnboardingCopy.DataControls.detail,
                        style: .prose,
                        color: .inkSecondary
                    )
                }

                LooprSectionGroup(title: "Destructive actions") {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        destructiveActionCard(
                            title: "Reset profile",
                            consequence: resetProfileConsequence,
                            identifier: "onboarding-reset-profile"
                        ) {
                            showingResetProfileConfirmation = true
                        }
                        .confirmationDialog(
                            "Reset only your profile?",
                            isPresented: $showingResetProfileConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("Reset profile", role: .destructive) { onConfirm(.resetProfile) }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(resetProfileConsequence)
                        }

                        destructiveActionCard(
                            title: "Forget band",
                            consequence: forgetBandConsequence,
                            identifier: "onboarding-forget-band"
                        ) {
                            showingForgetBandConfirmation = true
                        }
                        .confirmationDialog(
                            "Forget only this band?",
                            isPresented: $showingForgetBandConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("Forget band", role: .destructive) { onConfirm(.forgetBand) }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(forgetBandConsequence)
                        }

                        destructiveActionCard(
                            title: "Delete all data",
                            consequence: deleteAllDataConsequence,
                            identifier: "onboarding-delete-all-data"
                        ) {
                            showingDeleteAllDataConfirmation = true
                        }
                        .confirmationDialog(
                            "Delete all Loopr data?",
                            isPresented: $showingDeleteAllDataConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("Delete all data", role: .destructive) { onConfirm(.deleteAllData) }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(deleteAllDataConsequence)
                        }
                    }
                }
            }
        }
        .navigationTitle("Data controls")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("onboarding-destructive-actions-screen")
    }

    private func destructiveActionCard(
        title: String,
        consequence: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        LooprFormCard {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .looprTypography(.rowTitle)
                        .foregroundStyle(Color.loopr(.critical))
                        .accessibilityHidden(true)
                    LooprText(title, style: .cardTitle)
                }

                LooprText(consequence, style: .prose, color: .inkSecondary)

                Button(title, role: .destructive, action: action)
                    .buttonStyle(LooprDestructiveButtonStyle())
                    .accessibilityIdentifier(identifier)
            }
        }
    }

    private var resetProfileConsequence: String {
        "This clears your profile and goals but keeps device history."
    }

    private var forgetBandConsequence: String {
        "This removes the saved band and its pairing state. Your profile and history stay."
    }

    private var deleteAllDataConsequence: String {
#if canImport(DataKit)
        DataDisclosureCopy.deleteAllData
#else
        "This permanently removes every Loopr record on this iPhone: local records, files, snapshots, keychain items, notification data, live activities, re-analysis ledgers, your profile, and the paired strap. Loopr restarts at onboarding. HealthKit samples stay where they are."
#endif
    }
}
#endif
