import DesignSystem
import DomainKit
import Foundation

/// The morning note. It leads with last night against the person's usual, then names the strongest factor that
/// applies to last night and has enough nights on both sides. It says how the outcome differed on nights like last
/// night and counts those nights. It never says why.
enum MorningNoteWriter {
    private struct Comparison {
        let factor: NightFactor
        let like: NoteReceiptGroup
        let other: NoteReceiptGroup
        /// The group labels as the text writes them, with any time in the locale's clock.
        let likePhrase: String
        let otherPhrase: String
        let likeGroup: NoteFactorGroup
        let otherGroup: NoteFactorGroup
        /// Mean on nights like last night minus mean on the other nights, unrounded.
        let difference: Double
        /// The size of the difference as the text states it.
        let size: NoteNumber
    }

    static func write(_ input: MorningNoteInput, context: NoteContext) -> CoachNote? {
        guard let outcome = input.lastNight, outcome.value.isFinite, outcome.value >= 0 else { return nil }
        let formatter = NoteFormatter(context: context)
        guard let value = formatter.number(outcome.value, unit: outcome.unit) else { return nil }

        var builder = NoteBuilder(context: context)
        var supporting: [NoteNumber] = []
        builder.text("\(outcome.kind.title) was ")
        builder.number(value, highlighted: true)
        builder.text(" last night")

        let thresholds = context.thresholds
        var usualNights: NoteNumber?
        if let usual = input.usual, usual.median.isFinite, usual.median >= 0, usual.nights >= thresholds.minimumUsualNights {
            let nights = formatter.count(usual.nights, noun: "night", unit: .nights)
            usualNights = nights
            let delta = outcome.value - usual.median
            if let size = formatter.number(abs(delta), unit: outcome.unit), size.value > 0 {
                builder.text(", ")
                builder.number(size)
                // "the previous 28 nights": the usual leaves last night out, which is why "All 29 nights" counts one
                // more (R1-OPT-20).
                builder.text(delta < 0 ? " below your usual over the previous " : " above your usual over the previous ")
            } else {
                builder.text(", in line with your usual over the previous ")
            }
            builder.number(nights)
            builder.text(".")
        } else {
            let needed = formatter.count(thresholds.minimumUsualNights, noun: "night", unit: .nights)
            builder.text(". Loopr needs ")
            builder.number(needed)
            builder.text(" of data to learn your usual")
            if let have = input.usual?.nights, have > 0 {
                builder.text(" and has ")
                builder.number(formatter.count(have, noun: "night", unit: .nights))
                builder.text(" so far")
            }
            builder.text(".")
        }

        var receipt: NoteReceiptChart?
        var comparisonGroup: String?
        var chips = [NoteChip(action: .explainOutcome, label: "Why \(formatter.bare(value))?")]
        var comparedNights: NoteNumber?

        if let comparison = strongestComparison(input.factors, outcome: outcome, formatter: formatter) {
            let nightsLike = formatter.count(comparison.like.nightCount, noun: "night", unit: .nights)
            let nightsOther = formatter.count(comparison.other.nightCount, noun: "night", unit: .nights)
            let size = comparison.size
            builder.text(" ")
            appendStatement(comparison.factor, formatter: formatter, to: &builder)
            builder.text(" On the ")
            builder.number(nightsLike)
            builder.text(" with ")
            builder.text(comparison.likeGroup.label, protected: true)
            builder.text(", \(outcome.kind.phrase) averaged ")
            builder.number(size)
            builder.text(" \(outcome.kind.direction(higher: comparison.difference > 0)) than on the ")
            builder.number(nightsOther)
            builder.text(" with ")
            builder.text(comparison.otherGroup.label, protected: true)
            builder.text(".")

            receipt = NoteReceiptChart(outcome: outcome.kind, unit: outcome.unit,
                                       groups: [comparison.like, comparison.other], lastNightValue: value.value)
            comparisonGroup = "\(nightsLike.displayed) with \(comparison.likePhrase), against \(nightsOther.displayed) with \(comparison.otherPhrase)"
            let total = formatter.count(comparison.like.nightCount + comparison.other.nightCount, noun: "night", unit: .nights)
            comparedNights = total
            supporting.append(total)
            chips.append(NoteChip(action: .showNights, label: "All \(total.displayed)"))
        } else if let usualNights {
            comparisonGroup = "Your usual over \(usualNights.displayed)"
        }

        var days = "Last night"
        if let day = outcome.day, let weekday = context.weekday(of: day) { days += ", the night into \(weekday)" }
        days += "."
        if let usualNights { days += " Your usual covers \(usualNights.displayed)." }
        if let comparedNights { days += " The comparison covers \(comparedNights.displayed)." }

        let note = CoachNote(kind: .morning, runs: builder.runs, receipt: receipt, daysCovered: days,
                             comparisonGroup: comparisonGroup, chips: chips, supportingNumbers: supporting)
        return NoteGuard.isClean(note.text) ? note : nil
    }

    /// "You stopped eating {value} before bed." The value is highlighted. A statement without a placeholder is used as it is.
    private static func appendStatement(_ factor: NightFactor, formatter: NoteFormatter, to builder: inout NoteBuilder) {
        let statement = factor.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = statement.components(separatedBy: "{value}")
        if parts.count == 2, let value = factor.lastNightValue.flatMap({ formatter.factorValue($0) }) {
            builder.text(parts[0])
            builder.number(value, highlighted: true)
            builder.text(parts[1])
        } else {
            builder.text(statement.replacingOccurrences(of: "{value}", with: ""))
        }
        if let last = statement.last, !".?".contains(last) { builder.text(".") }
    }

    private static func strongestComparison(_ factors: [NightFactor], outcome: NightOutcome,
                                            formatter: NoteFormatter) -> Comparison? {
        let minimum = formatter.context.thresholds.minimumNightsPerGroup
        let candidates = factors.compactMap { comparison(for: $0, outcome: outcome, formatter: formatter, minimum: minimum) }
        return candidates.min { lhs, rhs in
            let left = abs(lhs.difference), right = abs(rhs.difference)
            if left != right { return left > right }
            let leftSmall = min(lhs.like.nightCount, lhs.other.nightCount)
            let rightSmall = min(rhs.like.nightCount, rhs.other.nightCount)
            if leftSmall != rightSmall { return leftSmall > rightSmall }
            return lhs.factor.id < rhs.factor.id
        }
    }

    private static func comparison(for factor: NightFactor, outcome: NightOutcome, formatter: NoteFormatter,
                                   minimum: Int) -> Comparison? {
        guard factor.groups.count == 2, factor.groups[0].id != factor.groups[1].id,
              let lastGroupID = factor.lastNightGroupID,
              let likeGroup = factor.groups.first(where: { $0.id == lastGroupID }),
              let otherGroup = factor.groups.first(where: { $0.id != lastGroupID }),
              let lastValue = factor.lastNightValue,
              NoteGuard.isClean(factor.statement), NoteGuard.isClean(likeGroup.label), NoteGuard.isClean(otherGroup.label),
              !likeGroup.label.isEmpty, !otherGroup.label.isEmpty else { return nil }
        // A value the statement asks for has to be one the writer can state.
        if factor.statement.contains("{value}"), formatter.factorValue(lastValue) == nil { return nil }

        func nights(in group: NoteFactorGroup) -> [NoteReceiptNight] {
            factor.history.compactMap { night in
                guard night.groupID == group.id, let value = night.outcome, value.isFinite else { return nil }
                return NoteReceiptNight(day: night.day, value: value)
            }
        }
        let likeNights = nights(in: likeGroup), otherNights = nights(in: otherGroup)
        guard likeNights.count >= minimum, otherNights.count >= minimum else { return nil }

        let likeMean = likeNights.map(\.value).reduce(0, +) / Double(likeNights.count)
        let otherMean = otherNights.map(\.value).reduce(0, +) / Double(otherNights.count)
        let difference = likeMean - otherMean
        // A difference that rounds to nothing is not named. It would state a number the person cannot read as a gap.
        guard let size = formatter.number(abs(difference), unit: outcome.unit), size.value > 0 else { return nil }

        let likePhrase = formatter.context.localizingClock(likeGroup.label)
        let otherPhrase = formatter.context.localizingClock(otherGroup.label)
        let likeLabel = "\(formatter.count(likeNights.count, noun: "night", unit: .nights).displayed), \(likePhrase)"
        let otherLabel = "\(formatter.count(otherNights.count, noun: "night", unit: .nights).displayed), \(otherPhrase)"
        return Comparison(
            factor: factor,
            like: NoteReceiptGroup(id: likeGroup.id, label: likeLabel, nightCount: likeNights.count, mean: likeMean,
                                   nights: likeNights, isLikeLastNight: true),
            other: NoteReceiptGroup(id: otherGroup.id, label: otherLabel, nightCount: otherNights.count, mean: otherMean,
                                    nights: otherNights, isLikeLastNight: false),
            likePhrase: likePhrase, otherPhrase: otherPhrase,
            likeGroup: likeGroup, otherGroup: otherGroup, difference: difference, size: size)
    }
}
