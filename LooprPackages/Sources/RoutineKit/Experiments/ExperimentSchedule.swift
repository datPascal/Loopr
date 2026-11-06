import DomainKit
import Foundation

/// One scheduled night: its 1-based number, the local day it starts on and what it is.
public struct ScheduledNight: Equatable, Sendable {
    public let number: Int
    public let day: DayIdentity
    public let role: ExperimentNightRole
}

/// Says, for any local day, whether it is an on night, an off night, a washout night or outside the experiment.
///
/// Night `n` starts on `startDay + (n - 1)` in civil days. A schedule is made of segments: one night each for
/// alternating days, `length` nights for blocks, and an off segment of `baselineNights` followed by one on segment for
/// before and after. The first segment is never a washout, because nothing switched before it. After every switch the
/// first `washout` nights of the new segment are washout nights: they keep the segment's arm but leave the result.
public struct ExperimentSchedule: Equatable, Sendable {
    public let design: ExperimentDesign
    public let washout: Int
    public let plannedNights: Int
    public let startDay: DayIdentity
    /// The last night that counts, when the experiment stopped early. Nights after it are outside.
    public let endDay: DayIdentity?

    public init(design: ExperimentDesign, washout: Int, plannedNights: Int, startDay: DayIdentity, endDay: DayIdentity? = nil) {
        self.design = design; self.washout = washout; self.plannedNights = plannedNights
        self.startDay = startDay; self.endDay = endDay
    }

    /// The role of the night that starts on `day`.
    public func role(on day: DayIdentity) -> ExperimentNightRole {
        guard let index = startDay.days(until: day), index >= 0, index < plannedNights else { return .outside }
        if let endDay, let last = startDay.days(until: endDay), index > last { return .outside }
        return Self.role(atIndex: index, design: design, washout: washout)
    }

    /// The 1-based number of the night that starts on `day`, or nil outside the experiment.
    public func nightNumber(on day: DayIdentity) -> Int? {
        role(on: day) == .outside ? nil : (startDay.days(until: day) ?? 0) + 1
    }

    /// Every night inside the experiment, in order.
    public var nights: [ScheduledNight] {
        (0..<plannedNights).compactMap { index in
            guard let day = startDay.adding(days: index) else { return nil }
            let role = role(on: day)
            return role == .outside ? nil : ScheduledNight(number: index + 1, day: day, role: role)
        }
    }

    /// Nights per arm that count toward the result (washout nights left out).
    public func includedNightCount(for arm: ExperimentArm) -> Int {
        nights.filter { $0.role == (arm == .on ? .on : .off) }.count
    }

    static func role(atIndex index: Int, design: ExperimentDesign, washout: Int) -> ExperimentNightRole {
        let segment: Int
        let position: Int
        let arm: ExperimentArm
        switch design {
        case .alternatingDays:
            segment = index; position = 0
            arm = index % 2 == 0 ? .on : .off
        case .blocks(let length):
            let length = max(length, 1)
            segment = index / length; position = index % length
            arm = segment % 2 == 0 ? .on : .off
        case .beforeAndAfter(let baselineNights):
            let baseline = max(baselineNights, 1)
            if index < baseline { segment = 0; position = index; arm = .off } else { segment = 1; position = index - baseline; arm = .on }
        }
        if segment >= 1, position < washout { return .washout(arm) }
        return arm == .on ? .on : .off
    }

    /// Refuses a plan that cannot work: a washout that swallows a block, or dates that leave an arm below the minimum.
    static func validate(design: ExperimentDesign, washout: Int, plannedNights: Int, minimumNightsPerArm: Int) throws {
        guard plannedNights >= 2 else { throw ExperimentError.plannedNightsTooLow }
        guard washout >= 0 else { throw ExperimentError.invalidWashout }
        let segmentLength: Int
        switch design {
        case .alternatingDays:
            segmentLength = 1
        case .blocks(let length):
            guard length >= 1 else { throw ExperimentError.invalidDesign }
            segmentLength = length
        case .beforeAndAfter(let baselineNights):
            guard baselineNights >= 1 else { throw ExperimentError.invalidDesign }
            guard baselineNights < plannedNights else { throw ExperimentError.invalidDesign }
            // Only the intervention segment follows a switch, so only it has to outlast the washout.
            segmentLength = plannedNights - baselineNights
        }
        guard washout < segmentLength else { throw ExperimentError.invalidWashout }
        var counts: [ExperimentArm: Int] = [.on: 0, .off: 0]
        for index in 0..<plannedNights {
            switch role(atIndex: index, design: design, washout: washout) {
            case .on: counts[.on, default: 0] += 1
            case .off: counts[.off, default: 0] += 1
            case .washout, .outside: break
            }
        }
        for arm in ExperimentArm.allCases where counts[arm, default: 0] < minimumNightsPerArm {
            throw ExperimentError.planCannotReachMinimum(arm)
        }
    }
}
