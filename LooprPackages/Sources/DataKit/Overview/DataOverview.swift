import AnalyticsKit
import DesignSystem
import Foundation

// LV-08b step 1: the Data tab's root, as one value built from stored data: the age ruler, this year against last,
// the star map, the vault card, the source rows and the header meta.

public struct DataOverviewInput: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var birthYear: Int?
    public var referenceGroup: FriendReferenceGroup?
    /// Every stored report with its values. Nil when the lab store could not be read.
    public var labDraws: [DataLabDraw]?
    public var vo2Max: DataVO2MaxSource
    /// Band and Apple Health metrics, absent ones included. Lab markers are added from `labDraws`.
    public var series: [DataSeries]
    /// Nil when the databases could not be read.
    public var vault: DataVaultFacts?
    public var sources: DataSourceFacts

    public init(now: Date, calendar: Calendar, birthYear: Int? = nil, referenceGroup: FriendReferenceGroup? = nil,
                labDraws: [DataLabDraw]? = [], vo2Max: DataVO2MaxSource = .readings([]), series: [DataSeries] = [],
                vault: DataVaultFacts? = nil, sources: DataSourceFacts = DataSourceFacts()) {
        self.now = now
        self.calendar = calendar
        self.birthYear = birthYear
        self.referenceGroup = referenceGroup
        self.labDraws = labDraws
        self.vo2Max = vo2Max
        self.series = series
        self.vault = vault
        self.sources = sources
    }
}

public struct DataOverview: Equatable, Sendable {
    public let ruler: DataAgeRuler
    public let slopes: DataYearComparison
    public let starMap: DataStarMap
    public let vaultCard: DataVaultCard?
    public let sourceRows: [DataSourceRow]
    public let meta: String

    /// The year card shows this many rows; "All" opens All metrics.
    public static let shownSlopes = 6

    public init(ruler: DataAgeRuler, slopes: DataYearComparison, starMap: DataStarMap, vaultCard: DataVaultCard?,
                sourceRows: [DataSourceRow], meta: String) {
        self.ruler = ruler
        self.slopes = slopes
        self.starMap = starMap
        self.vaultCard = vaultCard
        self.sourceRows = sourceRows
        self.meta = meta
    }

    public static func make(_ input: DataOverviewInput,
                            calculate: DataBloodAgeBuilder.Calculate = DataBloodAgeBuilder.published) -> DataOverview {
        let ruler = DataAgeRuler.make(birthYear: input.birthYear, draws: input.labDraws, vo2Max: input.vo2Max,
                                      referenceGroup: input.referenceGroup, now: input.now, calendar: input.calendar,
                                      calculate: calculate)
        let series = input.series + DataLabSeries.series(input.labDraws ?? [])
        return DataOverview(
            ruler: ruler,
            slopes: DataYearComparisonRule.compare(series, now: input.now, calendar: input.calendar),
            starMap: DataStarMapRule.make(series, now: input.now, calendar: input.calendar),
            vaultCard: input.vault.map { DataVaultCard.make(facts: $0, now: input.now, calendar: input.calendar) },
            sourceRows: DataSourceRow.rows(input.sources, now: input.now),
            meta: DataVaultMeta.line(facts: input.vault, sources: input.sources))
    }
}

/// Every catalog marker as a series, oldest first, in the unit of its newest value (the marker's canonical unit when
/// that one cannot be converted). A value whose unit cannot be converted stays out of the comparison. A marker with
/// no value is still listed, so the star map draws it.
public enum DataLabSeries {
    public static func series(_ draws: [DataLabDraw]) -> [DataSeries] {
        var byMarker: [LabMarkerKey: [(date: Date, value: LabValue)]] = [:]
        for draw in draws {
            for value in draw.values {
                guard let key = value.subject.markerKey else { continue }
                byMarker[key, default: []].append((draw.report.collectedAt, value))
            }
        }
        return LabMarkerCatalog.markers.map { marker in
            let raw = (byMarker[marker.key] ?? []).sorted { $0.date < $1.date }
            let unit = raw.last.flatMap { newest in
                (try? LabUnitConverter.convert(newest.value, to: newest.value.unit ?? marker.canonicalUnit))?.unit
            } ?? marker.canonicalUnit
            let entries: [(date: Date, value: Double, printed: String)] = raw.compactMap { entry in
                guard let conversion = try? LabUnitConverter.convert(entry.value, to: unit) else { return nil }
                let number = NSDecimalNumber(decimal: conversion.value).doubleValue
                guard number.isFinite else { return nil }
                let printed = [entry.value.displayValue, entry.value.unit].compactMap { $0 }.joined(separator: " ")
                return (entry.date, number, printed)
            }
            return DataSeries(
                id: "lab-\(marker.key.rawValue)", title: marker.displayName, system: DataBodySystem(marker.bodySystem),
                source: .lab, cadence: .lab, higherIsBetter: nil,
                points: entries.map { DataPoint(date: $0.date, value: $0.value) },
                latestText: entries.last?.printed,
                valueText: { "\(number($0)) \(unit)" },
                deltaText: { delta($0) })
        }
    }

    /// Up to two decimals, as the locale writes them, with a typographic minus when negative.
    @Sendable static func number(_ value: Double) -> String {
        LooprSignedNumber.text(value, fractionLength: 0...2, plus: false)
    }

    /// A change against last year: `+0.5`, `−23`, or `±0` when it rounds to nothing.
    @Sendable static func delta(_ value: Double) -> String {
        let text = LooprSignedNumber.text(value, fractionLength: 0...2)
        return text.hasPrefix("+") || text.hasPrefix(LooprSignedNumber.minusSign) ? text : "±" + text
    }
}
