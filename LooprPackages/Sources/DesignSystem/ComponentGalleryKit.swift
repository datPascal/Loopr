import SwiftUI

/// The tabs-redesign components in the gallery, all drawn from
/// `LooprFixtureMetrics` so the numbers agree with the fixture tabs.
///
/// Open a section directly with
/// `--loopr-open-design-system --loopr-design-system-section=<name>` where
/// name is one of recovery, deltas, contributors, stages, ledger, paired,
/// scrub, rows.
struct LooprGalleryKitSections: View {
    @Binding var highlightedStage: SleepStage?
    @Binding var trendRange: LooprChartRange

    private static let today = Calendar.current.startOfDay(for: Date())

    var body: some View {
        recovery.galleryIdentifier("recovery")
        deltas.galleryIdentifier("deltas")
        contributors.galleryIdentifier("contributors")
        stages.galleryIdentifier("stages")
        ledger.galleryIdentifier("ledger")
        paired.galleryIdentifier("paired")
        scrub.galleryIdentifier("scrub")
        rows.galleryIdentifier("rows")
    }

    // MARK: Recovery

    private var recovery: some View {
        let score = LooprFixtureMetrics.today(LooprMetricLinkID.recovery) ?? 0
        let band = LooprRecoveryBand(score: score) ?? .middle
        let delta = LooprDelta.compare(score, usual: Self.band(LooprMetricLinkID.recovery), higherIsBetter: true, unit: "")
        return VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprSectionHeader("Recovery band", detail: "Green, yellow and red belong to recovery alone")
            LooprRingHero(value: score, scale: LooprRingScale(fullValue: 100), text: String(format: "%.0f", score),
                          format: .integer, caption: "Recovery", accent: band.token) {
                VStack(spacing: LooprSpacing.xxs) {
                    LooprText(band.verdict, style: .title)
                    if let delta { LooprDeltaCaption(delta, accent: .recovery) }
                    LooprText(band.guidance, style: .prose, color: .inkSecondary)
                }
            }
            HStack(spacing: LooprSpacing.md) {
                ForEach([88.0, 52, 21], id: \.self) { value in
                    let sample = LooprRecoveryBand(score: value) ?? .middle
                    VStack(spacing: LooprSpacing.xs) {
                        LooprProgressRing(value: value, scale: LooprRingScale(fullValue: 100),
                                          text: String(format: "%.0f", value), accent: sample.token, diameter: 84)
                        LooprRecoveryBandLabel(sample)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, LooprSpacing.sm)
        }
    }

    // MARK: Deltas

    private var deltas: some View {
        let rhrHigh = LooprBaselineBand(center: 54, lower: 52.5, upper: 55.5, measuredDays: 28)
        let samples: [(String, LooprDelta?, LooprColorToken)] = [
            ("HRV above usual", .compare(58, usual: Self.band(LooprMetricLinkID.rmssd), higherIsBetter: true, unit: "ms"), .heart),
            ("Resting HR below usual", .compare(51, usual: Self.band(LooprMetricLinkID.restingHeartRate), higherIsBetter: false, unit: "bpm"), .heart),
            ("Resting HR above usual", .compare(59, usual: rhrHigh, higherIsBetter: false, unit: "bpm"), .heart),
            ("HRV as a share", .compare(40, usual: Self.band(LooprMetricLinkID.rmssd), higherIsBetter: true, format: .percent), .heart),
            ("Breathing rate", .compare(14.6, usual: Self.band(LooprMetricLinkID.respiratoryRate), higherIsBetter: nil, unit: "br/min", format: .number(digits: 1)), .heart),
            ("Strain, no good direction", .compare(15.2, usual: Self.band(LooprMetricLinkID.strain), higherIsBetter: nil, format: .number(digits: 1)), .strain),
            ("Sleep, short night", .compare(372, usual: Self.band(LooprMetricLinkID.sleepDuration), higherIsBetter: true, format: .duration), .sleep),
            ("Learning", .learning(3, of: 14), .heart)
        ]
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Delta captions", detail: "Every number next to your usual")
            LooprSurface {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                        HStack(alignment: .firstTextBaseline) {
                            LooprText(sample.0, style: .caption, color: .inkSecondary)
                            Spacer(minLength: LooprSpacing.sm)
                            if let delta = sample.1 {
                                LooprDeltaCaption(delta, accent: sample.2)
                            }
                        }
                    }
                    LooprHairline()
                    HStack {
                        LooprText("Compact, under a ring", style: .caption, color: .inkSecondary)
                        Spacer()
                        LooprDeltaCaption(.learning(3, of: 14), accent: .heart, length: .compact)
                    }
                }
            }
        }
    }

    // MARK: Contributors

    private var contributors: some View {
        let hrvValue = LooprFixtureMetrics.today(LooprMetricLinkID.rmssd)
        let rhrValue = LooprFixtureMetrics.today(LooprMetricLinkID.restingHeartRate)
        let breathing = LooprFixtureMetrics.today(LooprMetricLinkID.respiratoryRate)
        let sleep = LooprFixtureMetrics.today(LooprMetricLinkID.sleepDuration)
        let hrvBand = Self.band(LooprMetricLinkID.rmssd)
        let rhrBand = Self.band(LooprMetricLinkID.restingHeartRate)
        let breathingBand = Self.band(LooprMetricLinkID.respiratoryRate)
        let sleepBand = Self.band(LooprMetricLinkID.sleepDuration)
        let impacts = LooprContributorImpact.scaled([6, 3, 1, -0.5])
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Contributors", detail: "What shaped today's recovery", actionTitle: "See all", accent: .recovery) {}
            LooprContributorList([
                LooprContributorRow(
                    title: "HRV", value: hrvValue.map { String(format: "%.0f", $0) }, unit: "ms",
                    delta: .compare(hrvValue, usual: hrvBand, higherIsBetter: true, unit: "ms", withinRange: .signed),
                    range: LooprContributorRange(value: hrvValue, band: hrvBand),
                    impact: impacts[0].map { LooprContributorImpact(share: $0, label: "+6 pts") },
                    accent: .recovery, identifier: "gallery-contributor-hrv") {},
                LooprContributorRow(
                    title: "Resting heart rate", value: rhrValue.map { String(format: "%.0f", $0) }, unit: "bpm",
                    delta: .compare(rhrValue, usual: rhrBand, higherIsBetter: false, unit: "bpm", withinRange: .signed),
                    range: LooprContributorRange(value: rhrValue, band: rhrBand),
                    impact: impacts[1].map { LooprContributorImpact(share: $0, label: "+3 pts") },
                    accent: .recovery) {},
                LooprContributorRow(
                    title: "Sleep", value: sleep.flatMap { LooprUnitFormatter.duration(minutes: $0) },
                    delta: .compare(sleep, usual: sleepBand, higherIsBetter: true, format: .duration, withinRange: .signed),
                    range: LooprContributorRange(value: sleep, band: sleepBand),
                    impact: impacts[2].map { LooprContributorImpact(share: $0, label: "+1 pt") },
                    accent: .recovery) {},
                LooprContributorRow(
                    title: "Breathing rate", value: breathing.map { String(format: "%.1f", $0) }, unit: "br/min",
                    delta: .compare(breathing, usual: breathingBand, higherIsBetter: nil, unit: "br/min", format: .number(digits: 1), withinRange: .signed),
                    range: LooprContributorRange(value: breathing, band: breathingBand),
                    impact: impacts[3].map { LooprContributorImpact(share: $0, label: "0 pts") },
                    accent: .recovery) {}
            ])
        }
    }

    // MARK: Stages

    private var stages: some View {
        // Wake at 06:50, so the night reads as a night.
        let bedtime = Calendar.current.date(byAdding: .minute, value: 410 - LooprSampleNight.timeInBedMinutes, to: Self.today) ?? Self.today
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Stage timeline", detail: "Hold and drag to read, tap a stage to highlight it")
            LooprSurface {
                LooprStageTimeline(segments: LooprSampleNight.segments, start: bedtime, highlightedStage: $highlightedStage,
                                   identifier: "gallery-stage-timeline")
            }
            LooprText("While a finger rests on 00:40", style: .caption, color: .inkSecondary)
                .padding(.leading, LooprSpacing.xxs)
            LooprSurface {
                LooprStageTimeline(segments: LooprSampleNight.segments, start: bedtime,
                                   selection: .constant(bedtime.addingTimeInterval(138 * 60)),
                                   identifier: "gallery-stage-timeline-scrubbed")
            }
            HStack(spacing: LooprSpacing.xs) {
                ForEach(LooprStageTimelineModel.laneOrder.reversed(), id: \.self) { stage in
                    Button(stage.title) { highlightedStage = highlightedStage == stage ? nil : stage }
                        .buttonStyle(.plain)
                        .looprTypography(.chip)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(Color.loopr(highlightedStage == stage ? .ink : .inkSecondary))
                        .padding(.horizontal, LooprSpacing.sm)
                        .frame(minHeight: 32)
                        .background(Color.loopr(stage.token).opacity(highlightedStage == stage ? 0.25 : 0.10), in: Capsule())
                }
            }
        }
    }

    // MARK: Ledger and paired bars

    private var ledger: some View {
        let bars = LooprSampleNight.debtLedger(endingOn: Self.today)
        let model = LooprDivergingBarsModel(bars: bars)
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Sleep debt", detail: "Slept minus need, last 14 nights")
            LooprSurface {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                        LooprText(LooprUnitFormatter.signedDuration(minutes: model.total) ?? "", style: .metricCompact)
                        LooprText("over 14 nights", style: .caption, color: .inkSecondary)
                    }
                    LooprDivergingBars(
                        bars: bars,
                        title: "Sleep vs need",
                        positiveAccent: .sleep,
                        valueFormat: { LooprUnitFormatter.signedDuration(minutes: $0) ?? "" },
                        axisFormat: { LooprUnitFormatter.signedDuration(minutes: $0) ?? "" },
                        minimumSpan: 60,
                        identifier: "gallery-diverging-bars"
                    )
                }
            }
        }
    }

    private var paired: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Strain and recovery", detail: "Each day's strain next to the next morning's recovery")
            LooprSurface {
                LooprPairedBars(days: LooprSampleNight.strainRecoveryWeek(endingOn: Self.today), first: .strain, second: .recovery,
                                title: "Strain and next-morning recovery", identifier: "gallery-paired-bars")
            }
            LooprText("The readout a scrubbed chart shows", style: .caption, color: .inkSecondary)
                .padding(.leading, LooprSpacing.xxs)
            LooprSurface {
                GeometryReader { proxy in
                    LooprScrubReadout(x: proxy.size.width * 0.8, title: "Tue 22 Sep",
                                      value: "Strain 12.4 · Recovery 71%", accent: .strain)
                }
                .frame(height: 96)
            }
        }
    }

    // MARK: Trend chart with hold-to-scrub

    private var scrub: some View {
        let points = LooprFixtureMetrics.history(LooprMetricLinkID.rmssd, days: 400, endingOn: Self.today)
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Trend chart", detail: "Hold for a moment, then drag. A quick swipe still scrolls the page.")
            LooprMetricTrendCard(
                title: "HRV",
                points: points,
                endingOn: Self.today,
                range: $trendRange,
                kind: .line,
                accent: .heart,
                unit: "ms",
                valueFormat: { String(format: "%.0f", $0) },
                baseline: LooprBaselineBand.trailing(points, before: Self.today),
                identifier: "gallery-trend"
            )
        }
    }

    // MARK: Rows after cleanup

    private var rows: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Metric rows", detail: "Raw derivation strings, shown after the cleanup rules")
            HairlineMetricList(rows: [
                HairlineMetricRow(id: "g-duration", title: "Duration", confidence: "High confidence", value: "7:42", unit: "hours", showsDisclosure: true),
                HairlineMetricRow(id: "g-deep", title: "Deep sleep", confidence: "Partial data", value: "82", unit: "minutes", showsDisclosure: true),
                HairlineMetricRow(id: "g-debt", title: "Sleep debt", value: "0.4", unit: "hours"),
                HairlineMetricRow(id: "g-score", title: "Sleep score", confidence: "6 of 7 nights", value: "84", unit: "points"),
                HairlineMetricRow(id: "g-steps", title: "Estimated steps", confidence: "Estimated from wrist motion and your walking pace", value: "8,240", unit: "steps", showsDisclosure: true),
                HairlineMetricRow(id: "g-energy", title: "Active energy", confidence: "Low confidence", value: "612", unit: "kcal"),
                HairlineMetricRow(id: "g-dip", title: "Heart rate dip", value: "Not measured"),
                HairlineMetricRow(id: "g-rem", title: "REM sleep", confidence: "Not measured", value: "")
            ])
        }
    }

    // MARK: Helpers

    static func band(_ id: String) -> LooprBaselineBand? {
        LooprBaselineBand.trailing(LooprFixtureMetrics.history(id, days: 40, endingOn: today), before: today)
    }
}

private extension View {
    func galleryIdentifier(_ section: String) -> some View {
        id("design-system-section-\(section)")
            .accessibilityIdentifier("design-system-section-\(section)")
    }
}
