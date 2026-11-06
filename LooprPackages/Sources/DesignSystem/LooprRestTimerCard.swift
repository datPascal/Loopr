import SwiftUI

/// The rest countdown between sets: a small draining ring, a mono countdown,
/// a caption and a "+30 s" button. Pass `onDone` to add a quiet "Skip rest"
/// button under them, inside the card.
///
/// The card keeps no clock. The caller passes the end date and the current
/// date, so a `TimelineView(.periodic(from: .now, by: 1))` drives it on
/// screen and a fixed `now` drives it in tests and captures.
///
/// ```swift
/// TimelineView(.periodic(from: .now, by: 1)) { context in
///     LooprRestTimerCard(endDate: restEnd, now: context.date, totalSeconds: 150,
///                        caption: "Rest · the band buzzes at zero",
///                        identifier: "train-rest-timer", addIdentifier: "train-rest-add") { extendRest(30) }
/// }
/// ```
public struct LooprRestTimerCard: View {
    public static let ringDiameter: CGFloat = 52
    public static let minimumTargetHeight: CGFloat = LooprSpacing.interactiveRowHeight

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let endDate: Date
    private let now: Date
    private let totalSeconds: TimeInterval
    private let caption: String
    private let addSeconds: Int
    private let accent: LooprColorToken
    private let identifier: String
    private let addIdentifier: String
    private let doneIdentifier: String?
    private let doneTitle: String
    private let onAdd: () -> Void
    private let onDone: (() -> Void)?

    /// - Parameters:
    ///   - totalSeconds: The rest length the ring drains from. Include added time.
    ///   - addSeconds: What the button adds. It reads "+30 s" for 30.
    ///   - doneIdentifier: The identifier of the done button. Used only when `onDone` is set.
    ///   - doneTitle: The done button's title.
    ///   - onDone: Ends the rest early. Nil leaves the card without a done button.
    public init(endDate: Date, now: Date, totalSeconds: TimeInterval, caption: String,
                addSeconds: Int = 30, accent: LooprColorToken = .movement,
                identifier: String, addIdentifier: String,
                doneIdentifier: String? = nil, doneTitle: String = "Skip rest",
                onAdd: @escaping () -> Void, onDone: (() -> Void)? = nil) {
        self.endDate = endDate
        self.now = now
        self.totalSeconds = totalSeconds
        self.caption = caption
        self.addSeconds = addSeconds
        self.accent = accent
        self.identifier = identifier
        self.addIdentifier = addIdentifier
        self.doneIdentifier = doneIdentifier
        self.doneTitle = doneTitle
        self.onAdd = onAdd
        self.onDone = onDone
    }

    /// Whole seconds left, rounded up so the card reads 0:01 until the end
    /// date passes and never goes below zero.
    public static func remainingSeconds(endDate: Date, now: Date) -> Int {
        let remaining = endDate.timeIntervalSince(now)
        guard remaining.isFinite, remaining > 0 else { return 0 }
        return Int(remaining.rounded(.up))
    }

    /// Minutes and seconds as `m:ss`: 105 becomes "1:45", 0 becomes "0:00".
    public static func countdownText(seconds: Int) -> String {
        let seconds = max(0, seconds)
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    /// The countdown for VoiceOver: "1 minute 45 seconds".
    public static func spokenCountdown(seconds: Int) -> String {
        let seconds = max(0, seconds)
        let minutes = seconds / 60
        let rest = seconds % 60
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")") }
        if rest > 0 || parts.isEmpty { parts.append("\(rest) \(rest == 1 ? "second" : "seconds")") }
        return parts.joined(separator: " ")
    }

    /// What the ring shows, 0 to 1: the share of `totalSeconds` still left.
    public static func remainingFraction(remainingSeconds: Int, totalSeconds: TimeInterval) -> Double {
        guard totalSeconds.isFinite, totalSeconds > 0 else { return 0 }
        return min(max(Double(remainingSeconds) / totalSeconds, 0), 1)
    }

    private var remaining: Int { Self.remainingSeconds(endDate: endDate, now: now) }

    public var body: some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                timerRow
                if let onDone { doneButton(onDone) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var timerRow: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.md))
            : AnyLayout(HStackLayout(spacing: LooprSpacing.md))
        return layout {
                HStack(spacing: LooprSpacing.md) {
                    LooprProgressRing(value: Double(remaining), scale: LooprRingScale(fullValue: max(totalSeconds, 1)),
                                      text: "", accent: accent, diameter: Self.ringDiameter, animates: false)
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        Text(Self.countdownText(seconds: remaining))
                            .looprTypography(.metricCompact)
                            .monospacedDigit()
                            .foregroundStyle(Color.loopr(.ink))
                            .lineLimit(1)
                        Text(caption)
                            .looprTypography(.caption)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rest timer")
                .accessibilityValue("\(Self.spokenCountdown(seconds: remaining)) left. \(caption)")
                .accessibilityAddTraits(.updatesFrequently)
                addButton
        }
    }

    private func doneButton(_ action: @escaping () -> Void) -> some View {
        Button(doneTitle, action: action)
            .buttonStyle(LooprButtonStyle(prominent: false, accent: accent, quiet: true))
            .modifier(LooprOptionalIdentifier(doneIdentifier))
    }

    private var addButton: some View {
        Button(action: onAdd) {
            Text("+\(addSeconds) s")
                .padding(.horizontal, LooprSpacing.md)
        }
        .buttonStyle(LooprButtonStyle(prominent: false, accent: accent))
        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
        .accessibilityLabel("Add \(addSeconds) seconds")
        .accessibilityIdentifier(addIdentifier)
    }
}

#Preview("Rest timer") {
    LooprRestTimerCard(endDate: Date(timeIntervalSince1970: 1_700_000_105), now: Date(timeIntervalSince1970: 1_700_000_000),
                       totalSeconds: 150, caption: "Rest · the band buzzes at zero",
                       identifier: "preview-rest", addIdentifier: "preview-rest-add") {}
        .padding(LooprSpacing.screenGutter)
        .background(Color.loopr(.background))
}
