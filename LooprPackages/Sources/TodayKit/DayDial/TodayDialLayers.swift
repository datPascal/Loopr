import DesignSystem
import Foundation

/// Morning or evening. Evening starts at 18:00 wall-clock time in the dial's zone and lasts to midnight; from then
/// the centre is the bedtime countdown and tonight's sleep window replaces last night's hypnogram. A past day always
/// reads as morning: it shows the night that opened it, and there is no bedtime left to count down to.
public enum TodayDialMode: String, Equatable, Sendable {
    case morning
    case evening

    /// 18:00, in minutes after midnight.
    public static let eveningStartMinute = 18 * 60
}

/// The layers that can be missing. Rules are not one of them: a protocol without timed rules is not missing data.
public enum TodayDialLayerID: String, CaseIterable, Equatable, Sendable {
    case sleep, eating, training, daylight
}

/// Why a layer, the centre or a readout has nothing to show, in a sentence that says how it fills in.
public struct TodayDialAbsence: Equatable, Sendable {
    public let gap: TodayDialGap
    public let message: String

    public init(gap: TodayDialGap, message: String) {
        self.gap = gap
        self.message = message
    }
}

/// A layer that is drawn, or the reason it is not.
public enum TodayDialLayer<Value: Equatable & Sendable>: Equatable, Sendable {
    case present(Value)
    case absent(TodayDialAbsence)

    public var value: Value? {
        if case .present(let value) = self { value } else { nil }
    }

    public var absence: TodayDialAbsence? {
        if case .absent(let absence) = self { absence } else { nil }
    }
}

// MARK: - Sleep

/// One stage span of the hypnogram: an arc on `sleepRadius` with the stage's width.
public struct TodayDialStageSpan: Equatable, Sendable, Identifiable {
    public let id: Int
    public let stage: SleepStage
    public let arc: TodayDialArc
    public let radius: Double
    public let width: Double

    public var innerRadius: Double { radius - width / 2 }
    public var outerRadius: Double { radius + width / 2 }
}

/// Last night as a radial hypnogram at the bottom of the dial.
public struct TodayDialHypnogram: Equatable, Sendable {
    public let night: TodayDialArc
    public let spans: [TodayDialStageSpan]
    public let asleepMinutes: Double?
    public let isPartial: Bool
    public let provenance: TodayDialProvenance
}

/// Where tonight's bedtime came from.
public enum TodayDialBedtimeSource: Equatable, Sendable {
    /// The protocol's in-bed or asleep-by rule, with its key and today's state.
    case rule(key: String, state: TodayDialRuleState)
    /// Sleep's plan for tonight.
    case sleepPlan
}

/// Tonight's bedtime, drawn as a gem on the sleep ring in both modes.
public struct TodayDialBedtime: Equatable, Sendable {
    public let at: Date
    public let angle: Double
    public let source: TodayDialBedtimeSource
    public let provenance: TodayDialProvenance
    /// "Your protocol" or "Sleep plan", for the chip's qualifier.
    public let qualifier: String
}

/// Tonight's sleep window, lit ahead of the hand in the evening.
public struct TodayDialTonight: Equatable, Sendable {
    public let bedtime: TodayDialBedtime
    /// Bedtime to the wake time. Nil when there is no wake time to end it.
    public let window: TodayDialArc?
    /// Where the wake time came from, when there is a window.
    public let wakeSource: TodayDialWakeSource?
    /// The last evening rule before bed (such as screens off) to bedtime.
    public let windDown: TodayDialArc?
    /// Where the "tonight" label sits on the eating ring.
    public let labelAngle: Double
}

public enum TodayDialWakeSource: String, Equatable, Sendable {
    case alarm, sleepPlan
}

/// The sleep layer shows last night in the morning and tonight in the evening.
public enum TodayDialSleep: Equatable, Sendable {
    case lastNight(TodayDialHypnogram)
    case tonight(TodayDialTonight)
}

// MARK: - Eating

public struct TodayDialMeal: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let at: Date
    public let angle: Double
    public let radius: Double
    public let sticker: TodayDialSticker?
    public let provenance: TodayDialProvenance
    public var nutrition: TodayDialMealNutrition? = nil
}

/// The eating window: first meal to last meal, with the meal stickers on it.
public struct TodayDialEating: Equatable, Sendable {
    public let meals: [TodayDialMeal]
    /// First to last meal. A single meal gives an arc with no sweep.
    public let window: TodayDialArc
    /// First meal to the kitchen-closes time, drawn faint under the window. Nil without that rule, or when the kitchen
    /// closes before the first meal.
    public let planned: TodayDialArc?
}

// MARK: - Training

public struct TodayDialTrainingBlock: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let arc: TodayDialArc
    /// Planned and not done yet: drawn dashed.
    public let isPlanned: Bool
    /// Still going: the arc ends at now.
    public let isOngoing: Bool
    /// For a block a protocol rule planned, that rule's state.
    public let ruleState: TodayDialRuleState?
    public let provenance: TodayDialProvenance
}

// MARK: - Daylight

/// How the daylight dots are placed.
public enum TodayDialDaylightPlacement: String, Equatable, Sendable {
    /// At the times the daylight happened, one dot per 1.5 minutes.
    case atTimes
    /// From a daily total: one dot per 5 minutes, spread evenly over the daytime rim from 06:00 to now (or 18:00).
    /// The dots show how much, not when.
    case spreadAcrossDay
}

public struct TodayDialDaylight: Equatable, Sendable {
    public let minutes: Double
    public let placement: TodayDialDaylightPlacement
    /// The angle of each dot on `rimRadius`.
    public let dotAngles: [Double]
    public let provenance: TodayDialProvenance
}

// MARK: - Beads

public enum TodayDialBeadKind: String, Equatable, Sendable {
    /// The last-meal rule, a hollow bead on the eating ring.
    case kitchenCloses
    /// Any other timed rule, a filled bead on the rim.
    case routine
}

/// A timed rule at its time. In-bed rules become the bedtime gem and training rules become planned blocks, so neither
/// appears here.
public struct TodayDialBead: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let kind: TodayDialBeadKind
    public let minuteOfDay: Int
    public let angle: Double
    public let radius: Double
    public let size: Double
    public let state: TodayDialRuleState
    public let isEvening: Bool
    /// How the rule is checked. Only a manual rule can be ticked from the dial.
    public var source: TodayDialRuleSource = .manual
}

/// The wake alarm that rings next, as a bead where tonight's window ends.
public struct TodayDialAlarmBead: Equatable, Sendable {
    public let wake: Date
    public let angle: Double
    public let radius: Double
    /// The smart window before the wake time, when there is one.
    public let smartWindow: TodayDialArc?
    /// True when the alarm shown is tomorrow morning's.
    public let isTomorrow: Bool
}

/// The clock hand. Only on today's dial.
public struct TodayDialHand: Equatable, Sendable {
    public let date: Date
    public let angle: Double
}

/// What the dial as a whole is showing.
public struct TodayDialRenderState: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// Nothing recorded: no nights in the window, nothing today, no rules. The first-day dial.
        case empty
        /// Fewer than `nightsNeeded` nights, so there is no usual and no regularity yet.
        case learning
        /// Some layers have nothing to draw.
        case partial
        case complete
    }

    /// Usual ranges and regularity need this many measured nights, as Sleep's usual ranges do
    /// (`SleepUsualRange.minimumNights`).
    public static let nightsNeeded = 5

    public let kind: Kind
    public let absentLayers: [TodayDialLayerID]
    public let nightsMeasured: Int
    /// The sentence for the empty and learning dials. Nil otherwise: each absent layer carries its own.
    public let message: String?
}
