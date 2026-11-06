import DesignSystem
import SwiftUI

/// The recording card at the top of a live session: a chip that says the workout is being
/// recorded, the elapsed time, heart rate with its zone, and strain.
///
/// `WorkoutLiveScreen` keeps its own larger card with the zone bar and the alert target. This
/// compact one is for screens that put their own controls below it, such as the strength session.
/// It keeps the `workout-live-heart-rate` identifier so one test finds the heart rate on either.
///
/// It reads a `WorkoutLiveMetrics` the caller built with the clock it wants, so a frozen clock
/// gives a frozen card.
public struct WorkoutRecordingHero: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let metrics: WorkoutLiveMetrics
    private let isPaused: Bool
    private let expectedStrain: Double?
    private let identifier: String
    private let style: Style

    /// `card` is the full recording card. `strip` is one line, for a screen whose own controls need the room.
    public enum Style: Sendable { case card, strip }

    /// - Parameters:
    ///   - expectedStrain: What the same session usually scores. It shows as "of about 11" under the strain.
    public init(metrics: WorkoutLiveMetrics, isPaused: Bool = false, expectedStrain: Double? = nil,
                identifier: String = "workout-recording-hero", style: Style = .card) {
        self.style = style
        self.metrics = metrics
        self.isPaused = isPaused
        self.expectedStrain = expectedStrain
        self.identifier = identifier
    }

    /// "24:10", or "1:02:05" from the first hour. A missing time shows "--:--".
    public static func elapsedText(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "--:--" }
        let whole = Int(max(0, seconds))
        let hours = whole / 3_600, minutes = whole / 60 % 60, rest = whole % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// "7.9". Strain has one decimal.
    public static func strainText(_ strain: Double) -> String {
        strain.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US")))
    }

    /// "of about 11". Nil when there is no history to compare with.
    public static func expectedText(_ expected: Double?) -> String? {
        guard let expected, expected.isFinite, expected > 0 else { return nil }
        return "of about \(Int(expected.rounded()))"
    }

    public var body: some View {
        if style == .strip && !dynamicTypeSize.isAccessibilitySize { strip } else { card }
    }

    /// One line: recording dot and time, heart rate with its zone, strain.
    private var strip: some View {
        HStack(spacing: LooprSpacing.sm) {
            HStack(spacing: LooprSpacing.xs) {
                Circle()
                    .fill(Color.loopr(isPaused ? .warning : .heart))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(Self.elapsedText(metrics.elapsed))
                    .looprTypography(.metricValue)
                    .monospacedDigit()
                    .foregroundStyle(Color.loopr(.ink))
                    .accessibilityLabel(isPaused ? "Paused at \(Self.elapsedText(metrics.elapsed))" : "Recording, \(Self.elapsedText(metrics.elapsed))")
                    .accessibilityIdentifier("workout-recording-elapsed")
            }
            Spacer(minLength: LooprSpacing.xs)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.loopr(metrics.zone.map { LooprZonePalette.token(for: $0.number) } ?? .heart))
                Text(metrics.heartRate.map(String.init) ?? "--")
                    .looprTypography(.metricValue)
                    .monospacedDigit()
                    .foregroundStyle(Color.loopr(.ink))
                    .contentTransition(.numericText(value: Double(metrics.heartRate ?? 0)))
                Text(metrics.zone.map { "bpm · Z\($0.number)" } ?? "bpm")
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(metrics.heartRate.map { "Heart rate, \($0) beats per minute" + (metrics.zone.map { ", zone \($0.number)" } ?? "") } ?? "No heart rate")
            .accessibilityIdentifier("workout-live-heart-rate")
            Spacer(minLength: LooprSpacing.xs)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Strain")
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                Text(metrics.strain.map(Self.strainText) ?? "--")
                    .looprTypography(.metricValue)
                    .monospacedDigit()
                    .foregroundStyle(Color.loopr(.ink))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(metrics.strain.map { "Strain \(Self.strainText($0))" } ?? "No strain yet")
            .accessibilityIdentifier("workout-recording-strain")
        }
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .frame(minHeight: 52)
        .looprCardBackground(.hero(.workoutAccent), density: .compact)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var card: some View {
        LooprSurface(emphasis: .hero(.workoutAccent)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                HStack(alignment: .center, spacing: LooprSpacing.sm) {
                    StatusChip(isPaused ? "Paused" : "Recording locally",
                               symbol: isPaused ? "pause.circle" : "checkmark.circle",
                               tone: isPaused ? .warning : .positive)
                    Spacer(minLength: LooprSpacing.xs)
                    Text(Self.elapsedText(metrics.elapsed))
                        .looprTypography(.metricValue)
                        .monospacedDigit()
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .accessibilityLabel("Elapsed \(Self.elapsedText(metrics.elapsed))")
                        .accessibilityIdentifier("workout-recording-elapsed")
                }
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.md))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: LooprSpacing.md))
                layout {
                    heartRate
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: LooprSpacing.sm) }
                    strain
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func label(_ text: String) -> some View {
        Text(text.looprLabelCased)
            .looprTypography(.sectionLabel)
            .foregroundStyle(Color.loopr(.inkSecondary))
            .accessibilityHidden(true)
    }

    private var heartRate: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            label("Heart rate")
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xxs) {
                Text(metrics.heartRate.map(String.init) ?? "--")
                    .looprTypography(.lensValue)
                    .monospacedDigit()
                    .foregroundStyle(Color.loopr(.ink))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText(value: Double(metrics.heartRate ?? 0)))
                Text("bpm")
                    .looprTypography(.body)
                    .foregroundStyle(Color.loopr(.inkSecondary))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(metrics.heartRate.map { "Heart rate, \($0) beats per minute" } ?? "No heart rate")
            .accessibilityIdentifier("workout-live-heart-rate")
            if let zone = metrics.zone {
                StatusChip("Zone \(zone.number)", symbol: nil, accent: LooprZonePalette.token(for: zone.number))
                    .accessibilityLabel("Zone \(zone.number), \(zone.name)")
            } else {
                LooprText(metrics.heartRate == nil ? "No heart rate" : "Zone unavailable", style: .caption, color: .inkSecondary)
            }
        }
    }

    private var strain: some View {
        VStack(alignment: .trailing, spacing: LooprSpacing.xs) {
            label("Strain")
            Text(metrics.strain.map(Self.strainText) ?? "--")
                .looprTypography(.metric)
                .monospacedDigit()
                .foregroundStyle(Color.loopr(.ink))
                .lineLimit(1)
                .accessibilityLabel(metrics.strain.map { "Strain \(Self.strainText($0))" } ?? "No strain yet")
                .accessibilityIdentifier("workout-recording-strain")
            if metrics.strain != nil, let expected = Self.expectedText(expectedStrain) {
                LooprText(expected, style: .body, color: .inkSecondary)
            } else if metrics.strain == nil {
                LooprText("No reading yet", style: .caption, color: .inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
    }
}
