import AIKit
import DesignSystem
import SwiftUI

// Shared pieces of the coach settings screens: AI providers and coach
// preferences. Both follow the settings idiom (detail scaffold, form cards,
// inline messages) and share the copy for failures.

// MARK: - Copy

/// Readable text for everything that can go wrong on the coach settings
/// screens, and the time formats the morning briefing section shows.
nonisolated enum CoachSettingsCopy {
    static let genericFailure = "Something went wrong. Try again."

    /// One sentence a person can act on. Never an OSStatus code.
    static func message(for error: Error, provider: CoachProvider? = nil) -> String {
        let name = provider?.name ?? "The provider"
        switch error {
        case let error as CoachProviderError:
            switch error {
            case .missingKey: return "Enter an API key to continue."
            case .invalidKey: return "\(name) rejected this key. Check that you copied all of it."
            case .permission: return "This key cannot use that model. Pick another model or check the key's permissions."
            case .modelUnavailable: return "Your account cannot use that model. Pick another one."
            case .quota: return "This \(name) account has no credit left. Check billing with \(name)."
            case .rateLimited: return "\(name) is limiting this key right now. Wait a minute and try again."
            case .configurationChanged: return "Your provider settings changed. Review them and try again."
            default: return error.errorDescription ?? genericFailure
            }
        case let error as CoachSettingsError:
            return error.errorDescription ?? genericFailure
        case let error as NSError where error.domain == NSOSStatusErrorDomain:
            return "Loopr could not use this iPhone's Keychain. Unlock your iPhone and try again."
        case let error as LocalizedError:
            return error.errorDescription ?? genericFailure
        default:
            return genericFailure
        }
    }

    /// "7 AM" or "07:00", whichever the locale uses for a time of day.
    static func hourLabel(_ hour: Int, locale: Locale = .current, calendar: Calendar = .current) -> String {
        guard let date = calendar.date(from: DateComponents(hour: hour, minute: 0)) else { return "\(hour):00" }
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }

    /// The saved day key ("2026-10-09") as "Today", "Yesterday" or a short date.
    static func dayText(_ key: String, now: Date = Date(), locale: Locale = .current, calendar: Calendar = .current) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: key) else { return key }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }

    /// When the next briefing is due: "Tomorrow at 7:00 AM".
    static func nextBriefingText(hour: Int, now: Date = Date(), locale: Locale = .current, calendar: Calendar = .current) -> String {
        guard let next = calendar.nextDate(after: now, matching: DateComponents(hour: hour), matchingPolicy: .nextTime) else {
            return hourLabel(hour, locale: locale, calendar: calendar)
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: next)
    }
}

// MARK: - Feedback

/// A result shown next to the action that caused it.
struct CoachFeedback: Equatable {
    let text: String
    let tone: ChipTone
    private let token = UUID()

    static func success(_ text: String) -> CoachFeedback { CoachFeedback(text: text, tone: .positive) }
    static func failure(_ text: String) -> CoachFeedback { CoachFeedback(text: text, tone: .critical) }
    static func note(_ text: String) -> CoachFeedback { CoachFeedback(text: text, tone: .neutral) }

    var haptic: LooprHaptic? {
        switch tone {
        case .positive: .success
        case .critical: .error
        default: nil
        }
    }
}

// MARK: - Buttons

/// The quiet partner of `LooprPrimaryButtonStyle`: a brand-tinted outline for
/// actions that check or refresh and change nothing.
struct CoachSecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let reduces = LooprMotion.reducesMotion(reduceMotion)
        configuration.label
            .looprTypography(.label)
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.loopr(isEnabled ? .brandInk : .inkMuted))
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.formButtonHeight)
            .background(
                Color.loopr(.brand).opacity(isEnabled ? 0.10 : 0.04),
                in: RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous)
                    .strokeBorder(Color.loopr(.brand).opacity(isEnabled ? 0.30 : 0.12), lineWidth: LooprSpacing.hairline)
                    .allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed && !reduces ? 0.98 : 1)
            .animation(reduces ? .linear(duration: 0) : LooprMotion.stateChange, value: configuration.isPressed)
    }
}

/// A button label that swaps its text for a spinner and a progress word while
/// the action runs.
struct CoachActionLabel: View {
    let title: String
    let progressTitle: String
    let isRunning: Bool

    var body: some View {
        HStack(spacing: LooprSpacing.xs) {
            if isRunning { ProgressView().controlSize(.small) }
            Text(isRunning ? progressTitle : title)
        }
        .padding(.horizontal, LooprSpacing.sm)
    }
}

// MARK: - Fields

/// A labelled field in a recessed well, so the label stays visible once the
/// field has text in it.
struct CoachFieldWell<Field: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var field: Field
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprText(title, style: .rowTitle)
                .accessibilityHidden(true)
            HStack(spacing: LooprSpacing.xs) {
                field
                    .looprTypography(.settingsRow)
                    .foregroundStyle(Color.loopr(.ink))
                    .tint(Color.loopr(.brand))
                    .frame(maxWidth: .infinity, minHeight: LooprSpacing.formButtonHeight, alignment: .leading)
                trailing
            }
            .padding(.horizontal, LooprSpacing.compactCardHorizontal)
            .padding(.vertical, LooprSpacing.xxs)
            .looprCardBackground(.sunk, density: .flush)
        }
    }
}

// MARK: - Provider card

/// One provider: connected or not, the model in use, and whether it is the
/// provider the coach talks to. Selecting it picks which provider the form
/// below edits.
struct CoachProviderCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let provider: CoachProvider
    let configuration: CoachProviderConfiguration?
    let isActive: Bool
    let isEditing: Bool
    let action: () -> Void

    private var isConnected: Bool { configuration != nil }

    var body: some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) { title; chips }
                } else {
                    HStack(alignment: .center, spacing: LooprSpacing.sm) {
                        title.layoutPriority(1)
                        Spacer(minLength: LooprSpacing.xs)
                        chips
                    }
                }
            }
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .padding(.vertical, LooprSpacing.sm)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .looprCardBackground()
            .overlay {
                if isEditing {
                    RoundedRectangle(cornerRadius: LooprRadius.card, style: .continuous)
                        .strokeBorder(Color.loopr(.brand), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableCard)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(provider.name)
        .accessibilityValue(spokenValue)
        .accessibilityAddTraits(isEditing ? .isSelected : [])
        .looprAccessibilityHint("Shows the settings for \(provider.name).")
        .accessibilityIdentifier("coach-provider-\(provider.rawValue)")
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            LooprText(provider.name, style: .cardTitle)
            if let configuration {
                LooprText(configuration.model, style: .metricUnit, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LooprText("No key saved", style: .prose, color: .inkSecondary)
            }
        }
    }

    private var chips: some View {
        HStack(spacing: LooprSpacing.xs) {
            if isActive { StatusChip("In use", symbol: "sparkles", tone: .brand) }
            if isConnected {
                StatusChip("Connected", symbol: "checkmark.circle.fill", tone: .positive)
            } else {
                StatusChip("Not connected", symbol: "circle.dashed", tone: .neutral)
            }
        }
    }

    private var spokenValue: String {
        var parts = [isConnected ? "Connected" : "Not connected"]
        if let configuration { parts.append("model \(configuration.model)") }
        if isActive { parts.append("in use") }
        return parts.joined(separator: ", ")
    }
}
