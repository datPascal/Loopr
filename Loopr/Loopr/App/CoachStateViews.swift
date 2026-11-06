import AIKit
import DesignSystem
import SwiftUI

/// The label colour for text and glyphs on a brand fill. `LooprColorToken.background` is dark on
/// the dark set (10.8:1 on the brand teal) but light on the light set (2.6:1), so the light set
/// uses `ink` (6.1:1).
func coachOnBrandColor(isDark: Bool) -> Color {
    Color.loopr(isDark ? .background : .ink)
}

/// A compact action for cards. `prominent` fills with the brand colour; the other style is a soft tint.
struct CoachCardButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let isDark = LooprAppearance.isDark(colorScheme)
        let reduces = LooprMotion.reducesMotion(reduceMotion)
        configuration.label
            .looprTypography(.label)
            .foregroundStyle(prominent && isEnabled ? coachOnBrandColor(isDark: isDark) : Color.loopr(isEnabled ? .brandInk : .inkMuted))
            .padding(.horizontal, LooprSpacing.md)
            .frame(minHeight: LooprSpacing.formButtonHeight)
            .background(
                prominent ? Color.loopr(.brand).opacity(isEnabled ? 1 : 0.10) : Color.loopr(.brandSoft),
                in: RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && !reduces ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(LooprMotion.press, value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous))
    }
}

/// An amber outline over the plain card surface. `LooprCard(style: .warning)` also tints the fill,
/// and on the dark set that tint turns the blue card grey, so the coach draws the outline itself.
private struct CoachWarningOutline: ViewModifier {
    let compact: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isDark = LooprAppearance.isDark(colorScheme)
        let radius = compact ? LooprRadius.compactCard : LooprRadius.surface(isDark: isDark)
        content.overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.loopr(.caution).opacity(isDark ? 0.45 : 0.32), lineWidth: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    fileprivate func coachWarningOutline(compact: Bool) -> some View {
        modifier(CoachWarningOutline(compact: compact))
    }
}

/// A problem with the chat. Every card carries the one action that fixes it, so a person never
/// has to look for Retry anywhere else. At accessibility sizes the screen puts it in the thread.
struct CoachProblemCard: View {
    let problem: CoachProblem
    let perform: (CoachProblem.Action) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var dismissible: Bool { problem.kind != .reconnect && !problem.actions.contains(.dismiss) }
    private var large: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        LooprCard(style: .standard, density: .compact) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                if large {
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                        symbol
                        title
                        Spacer(minLength: 0)
                        dismissButton
                    }
                    message
                } else {
                    HStack(alignment: .top, spacing: LooprSpacing.sm) {
                        symbol
                        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                            title
                            message
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        dismissButton
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LooprSpacing.xs) { buttons }
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) { buttons }
                }
            }
        }
        .coachWarningOutline(compact: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach-error")
    }

    private var symbol: some View {
        Image(systemName: problem.symbol)
            .looprTypography(.rowTitle)
            .foregroundStyle(Color.loopr(.warning))
            .frame(width: LooprSpacing.lg, height: LooprSpacing.lg)
            .accessibilityHidden(true)
    }

    private var title: some View {
        Text(problem.title)
            .looprTypography(.rowTitle)
            .foregroundStyle(Color.loopr(.ink))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private var message: some View {
        Text(problem.message)
            .looprTypography(.prose)
            .foregroundStyle(Color.loopr(.inkSecondary))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var dismissButton: some View {
        if dismissible {
            Button { perform(.dismiss) } label: {
                Image(systemName: "xmark")
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, -LooprSpacing.sm).padding(.vertical, -LooprSpacing.sm)
            .accessibilityLabel("Dismiss")
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(Array(problem.actions.enumerated()), id: \.offset) { index, action in
            Button(action.title) { perform(action) }
                .buttonStyle(CoachCardButtonStyle(prominent: index == 0))
                .accessibilityIdentifier(action == .retry ? "coach-retry-reply" : "coach-problem-action-\(index)")
        }
    }
}

/// Retry for a reply the person stopped, where no failure card is showing.
struct CoachRetryRow: View {
    let retry: () -> Void

    var body: some View {
        Button(action: retry) {
            Label("Retry reply", systemImage: "arrow.clockwise")
        }
        .buttonStyle(CoachCardButtonStyle())
        .accessibilityIdentifier("coach-retry-reply")
    }
}

/// No key on this iPhone yet. A question tapped on a chip waits here and is asked once a provider is connected
/// (ICP R3-NEW-6).
struct CoachConnectCard: View {
    var question: String?
    let connect: () -> Void

    var body: some View {
        LooprCard(style: .hero(.brand)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Color.loopr(.brand))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    Text("Ask needs an AI provider")
                        .looprTypography(.cardTitle)
                        .foregroundStyle(Color.loopr(.ink))
                        .accessibilityAddTraits(.isHeader)
                    Text("Ask answers questions about your numbers using OpenAI or Claude. You need an account with one of them and a key from its website. A key is a long code that works like a password. The provider bills you for each question.")
                        .looprTypography(.settingsRow)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                    Text("Loopr sends nothing until you approve a summary of what it shares.")
                        .looprTypography(.settingsRow)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                }
                .fixedSize(horizontal: false, vertical: true)
                if let question {
                    Text("Your question, \"\(question)\", waits here. Loopr asks it once you connect.")
                        .looprTypography(.settingsRow)
                        .foregroundStyle(Color.loopr(.ink))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("coach-waiting-question")
                }
                Button("Connect an AI provider", action: connect)
                    .buttonStyle(LooprPrimaryButtonStyle())
                    .accessibilityIdentifier("coach-connect-provider")
                Text("Your key stays in this iPhone's Keychain.")
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .padding(.top, LooprSpacing.md)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach-needs-provider")
    }
}

/// Chats could not be opened. The only fix is to try again.
struct CoachLoadFailedCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        LooprCard(style: .standard) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                HStack(alignment: .top, spacing: LooprSpacing.sm) {
                    Image(systemName: "exclamationmark.bubble")
                        .looprTypography(.cardTitle)
                        .foregroundStyle(Color.loopr(.warning))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        Text("Ask could not open")
                            .looprTypography(.cardTitle)
                            .foregroundStyle(Color.loopr(.ink))
                            .accessibilityAddTraits(.isHeader)
                        Text(message)
                            .looprTypography(.settingsRow)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                Button("Try again", action: retry)
                    .buttonStyle(LooprPrimaryButtonStyle())
                    .accessibilityIdentifier("coach-load-retry")
            }
        }
        .coachWarningOutline(compact: false)
        .padding(.horizontal, LooprSpacing.screenGutter)
        .padding(.top, LooprSpacing.md)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach-load-failed")
    }
}

/// The empty chat: what Ask can do, and a few questions to start from.
/// A starter fills the composer. Nothing is sent until the person taps Send.
struct CoachIntroduction: View {
    /// The prompt chips. Each one only fills the message field.
    var prompts = AskPrompts.general
    let pick: (String) -> Void
    var showsStarters = true

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                Text("What do you want to know?")
                    .looprTypography(.cardTitle)
                    .foregroundStyle(Color.loopr(.ink))
                    .accessibilityAddTraits(.isHeader)
                Text("Ask reads your saved measurements to put your numbers in context. You review what it can see before your first message goes out.")
                    .looprTypography(.settingsRow)
                    .foregroundStyle(Color.loopr(.inkSecondary))
            }
            .fixedSize(horizontal: false, vertical: true)
            if showsStarters { VStack(spacing: LooprSpacing.xs) {
                ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
                    Button { pick(prompt) } label: {
                        HStack(spacing: LooprSpacing.sm) {
                            Text(prompt)
                                .looprTypography(.settingsRow)
                                .foregroundStyle(Color.loopr(.ink))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: LooprSpacing.xs)
                            Image(systemName: "arrow.up.left")
                                .looprTypography(.caption)
                                .foregroundStyle(Color.loopr(.brandInk))
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, LooprSpacing.compactCardHorizontal)
                        .padding(.vertical, LooprSpacing.xxs)
                        .looprCardBackground(.standard, density: .compact)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.looprPressableCard)
                    .looprAccessibilityHint("Adds this question to the message field.")
                    .accessibilityIdentifier("ask-prompt-\(index)")
                }
            } }
            Text("AI can be wrong. Treat replies as guidance, and talk to a clinician about health concerns.")
                .looprTypography(.caption)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, LooprSpacing.xs)
    }
}
