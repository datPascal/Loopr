import DesignSystem
import Foundation

/// One meal as the eating-window rail draws it.
public struct FoodRailMeal: Equatable, Sendable, Identifiable {
    public let id: UUID
    /// Minutes after local midnight of the day.
    public let minute: Int
    /// Known kilocalories. Nil when no item reported energy.
    public let energy: Double?
    public let slot: FoodMealSlot
    /// The first letter of the first item, upper case, for the drawn sticker. Nil when the name has no letter.
    public let initial: String?
    /// The meal's first photo. A meal without one gets a drawn sticker.
    public let photoID: UUID?
    /// The item names, for VoiceOver.
    public let title: String

    public init(id: UUID, minute: Int, energy: Double?, slot: FoodMealSlot, initial: String?, photoID: UUID?, title: String) {
        self.id = id; self.minute = minute; self.energy = energy; self.slot = slot
        self.initial = initial; self.photoID = photoID; self.title = title
    }

    /// The meal at its time of day in `calendar`'s time zone.
    public init(_ meal: FoodMeal, calendar: Calendar) {
        let parts = calendar.dateComponents([.hour, .minute], from: meal.occurredAt)
        let first = meal.items.first?.name.first(where: \.isLetter).map { String($0).uppercased() }
        self.init(id: meal.id, minute: (parts.hour ?? 0) * 60 + (parts.minute ?? 0),
                  energy: FoodNutrientTotal(.energy, items: meal.items).knownValue, slot: meal.slot, initial: first,
                  photoID: meal.photos.first?.id, title: meal.items.map(\.name).joined(separator: ", "))
    }
}

/// The empty sticker for the next meal on today's rail. Tapping it opens the camera.
public struct FoodRailGhost: Equatable, Sendable {
    public let slot: FoodMealSlot
    public let minute: Int
    public init(slot: FoodMealSlot, minute: Int) { self.slot = slot; self.minute = minute }
}

/// Where one sticker sits on the track, in points from the track's leading edge.
public struct FoodRailPlacement: Equatable, Sendable, Identifiable {
    /// The meal's id, or nil for the ghost.
    public let mealID: UUID?
    /// The sticker's centre.
    public let x: Double
    /// Where its time is on the track. A sticker in a stack sits off its time.
    public let timeX: Double
    /// The stack it belongs to, left to right. The ghost has its own.
    public let stack: Int
    /// Its place in the stack. Later meals draw on top.
    public let order: Int
    public var id: String { mealID?.uuidString ?? "ghost" }
}

/// Meals that share one place on the rail, with the one label under them.
public struct FoodRailStack: Equatable, Sendable, Identifiable {
    public let index: Int
    public let meals: [FoodRailMeal]
    /// The centre of the stack's stickers.
    public let centre: Double
    public var id: Int { index }
}

/// The eating-window rail (contract p-food): a time track from 06:00 to 21:00, widened in three-hour steps to hold
/// every meal, the kitchen's closing time and now. The window runs from the first meal to the closing time, or to the
/// last meal without a kitchen-closes rule. Today adds a "now" marker and a ghost sticker for the next meal.
///
/// Overlap rule: stickers whose times sit closer than one sticker width form a stack. A stack fans out with its
/// stickers 0.55 widths apart (less when the track is too short to hold them), centred on the mean of their times and
/// kept inside the track, later meals on top. Two stacks that would then overlap merge into one. The ghost never
/// stacks: it sits at least one width and 4 pt after the last sticker.
public struct FoodWindowRail: Equatable, Sendable {
    public static let defaultStartMinute = 6 * 60
    public static let defaultEndMinute = 21 * 60
    public static let tickStep = 3 * 60
    /// Stickers in a stack sit this many sticker widths apart.
    public static let stackSpacing = 0.55
    /// The gap between the ghost and the sticker before it, in points, on top of one width.
    public static let ghostGap = 4.0

    public let startMinute: Int
    public let endMinute: Int
    /// Sorted by time.
    public let meals: [FoodRailMeal]
    public let closesMinute: Int?
    /// Nil on any day but today.
    public let nowMinute: Int?
    public let ghost: FoodRailGhost?

    /// - Parameters:
    ///   - now: the current time on today; nil on a past day, which has no "now" and no ghost.
    ///   - closesMinute: the kitchen-closes time from the protocol, minutes after midnight.
    public init(meals: [FoodMeal], calendar: Calendar, now: Date?, closesMinute: Int?) {
        let minute = now.map { date -> Int in
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        self.init(railMeals: meals.map { FoodRailMeal($0, calendar: calendar) }, nowMinute: minute, closesMinute: closesMinute)
    }

    public init(railMeals: [FoodRailMeal], nowMinute: Int?, closesMinute: Int?) {
        let sorted = railMeals.sorted { ($0.minute, $0.id.uuidString) < ($1.minute, $1.id.uuidString) }
        let closes = closesMinute.flatMap { (0..<1_440).contains($0) ? $0 : nil }
        let now = nowMinute.flatMap { (0..<1_440).contains($0) ? $0 : nil }
        let ghost = now.flatMap { Self.ghost(meals: sorted, nowMinute: $0, closesMinute: closes) }
        meals = sorted
        self.closesMinute = closes
        self.nowMinute = now
        self.ghost = ghost
        let marks = sorted.map(\.minute) + [closes, now, ghost?.minute].compactMap { $0 }
        let low = min(marks.min() ?? Self.defaultStartMinute, Self.defaultStartMinute)
        let high = max(marks.max() ?? Self.defaultEndMinute, Self.defaultEndMinute)
        startMinute = max(0, low / Self.tickStep * Self.tickStep)
        endMinute = min(1_440, (high + Self.tickStep - 1) / Self.tickStep * Self.tickStep)
    }

    public var isEmpty: Bool { meals.isEmpty }

    /// Every three hours from the start to the end.
    public var ticks: [Int] { Array(stride(from: startMinute, through: endMinute, by: Self.tickStep)) }

    /// From the first meal to the kitchen's closing time, or to the last meal when there is no closing time or it
    /// came before the first meal. Nil with no meals.
    public var window: ClosedRange<Int>? {
        guard let first = meals.first?.minute, let last = meals.last?.minute else { return nil }
        if let closesMinute, closesMinute > first { return first...closesMinute }
        return first...last
    }

    /// A minute's place on the track, 0 at the start and 1 at the end.
    public func fraction(of minute: Int) -> Double {
        let span = Double(max(endMinute - startMinute, 1))
        return min(max(Double(minute - startMinute) / span, 0), 1)
    }

    /// The meal the Log tiles, Speak and Manual start in (`FoodMealSlot.toLog`), so the ghost's camera opens on the
    /// same slot as every other way to log (ICP R2-UPG-20). Nil once that slot already holds a meal. It sits at the
    /// slot's usual time (08:00, 12:30, 15:30, 18:30), no earlier than 20 minutes from now, and half an hour before
    /// the kitchen closes when that is earlier.
    static func ghost(meals: [FoodRailMeal], nowMinute: Int, closesMinute: Int?) -> FoodRailGhost? {
        let logged = Set(meals.map(\.slot))
        let slot = FoodMealSlot.toLog(minuteOfDay: nowMinute, logged: logged).slot
        guard !logged.contains(slot) else { return nil }
        var minute = switch slot { case .breakfast: 480; case .lunch: 750; case .snack: 930; case .dinner: 1_110 }
        if let closesMinute, closesMinute - 30 > nowMinute { minute = min(minute, closesMinute - 30) }
        return FoodRailGhost(slot: slot, minute: min(max(minute, nowMinute + 20), 1_439))
    }

    // MARK: Layout

    /// Where each sticker sits on a track `trackWidth` points wide, meals first in time order, then the ghost.
    public func placements(trackWidth: Double, stickerWidth: Double) -> [FoodRailPlacement] {
        layout(trackWidth: trackWidth, stickerWidth: stickerWidth).placements
    }

    /// The stacks of meals, left to right, each with the centre its label sits under. The ghost is not a stack here.
    public func stacks(trackWidth: Double, stickerWidth: Double) -> [FoodRailStack] {
        layout(trackWidth: trackWidth, stickerWidth: stickerWidth).stacks
    }

    private func layout(trackWidth: Double, stickerWidth: Double) -> (placements: [FoodRailPlacement], stacks: [FoodRailStack]) {
        let width = max(trackWidth, 1), sticker = max(min(stickerWidth, width), 1)
        let timeX = meals.map { fraction(of: $0.minute) * width }
        var groups: [[Int]] = []
        for index in meals.indices {
            if let last = groups.last?.last, timeX[index] - timeX[last] < sticker { groups[groups.count - 1].append(index) }
            else { groups.append([index]) }
        }
        func positions(_ group: [Int]) -> [Double] {
            let count = group.count
            let spacing = count > 1 ? min(Self.stackSpacing * sticker, max(width - sticker, 0) / Double(count - 1)) : 0
            let span = spacing * Double(count - 1)
            let centre = group.map { timeX[$0] }.reduce(0, +) / Double(count)
            let first = min(max(centre - span / 2, sticker / 2), max(width - sticker / 2 - span, sticker / 2))
            return (0..<count).map { first + Double($0) * spacing }
        }
        var placed = groups.map(positions)
        var merged = true
        while merged {
            merged = false
            for index in placed.indices.dropFirst() where placed[index][0] - placed[index - 1][placed[index - 1].count - 1] < sticker {
                groups[index - 1] += groups[index]
                groups.remove(at: index)
                placed = groups.map(positions)
                merged = true
                break
            }
        }
        var result: [FoodRailPlacement] = []
        var stacks: [FoodRailStack] = []
        for (stack, group) in groups.enumerated() {
            for (order, index) in group.enumerated() {
                result.append(.init(mealID: meals[index].id, x: placed[stack][order], timeX: timeX[index], stack: stack, order: order))
            }
            let xs = placed[stack]
            stacks.append(.init(index: stack, meals: group.map { meals[$0] }, centre: (xs[0] + xs[xs.count - 1]) / 2))
        }
        if let ghost {
            let time = fraction(of: ghost.minute) * width
            var x = time
            if let last = placed.last?.last { x = max(x, last + sticker + Self.ghostGap) }
            x = min(max(x, sticker / 2), width - sticker / 2)
            result.append(.init(mealID: nil, x: x, timeX: time, stack: groups.count, order: 0))
        }
        return (result, stacks)
    }

    /// Label centres and rows for labels of the given widths, under the given centres. A label stays inside the
    /// track, takes the first row when it clears the label before it there by `gap`, and otherwise the second.
    public static func labelRows(centres: [Double], widths: [Double], trackWidth: Double, gap: Double = 8) -> [(x: Double, row: Int)] {
        var rightEdges = [-Double.infinity, -Double.infinity]
        return zip(centres, widths).map { centre, width in
            let half = min(width, trackWidth) / 2
            let x = min(max(centre, half), trackWidth - half)
            let left = x - half
            let row: Int
            if left >= rightEdges[0] + gap { row = 0 }
            else if left >= rightEdges[1] + gap { row = 1 }
            else { row = rightEdges[0] <= rightEdges[1] ? 0 : 1 }
            rightEdges[row] = x + half
            return (x, row)
        }
    }

    /// A lean between 2° and 6° either way, the same for a meal every time it is drawn.
    public static func rotation(for id: UUID) -> Double {
        var hash: UInt32 = 2_166_136_261
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        }
        let magnitude = 2 + Double((hash >> 1) % 4_001) / 1_000
        return hash & 1 == 0 ? -magnitude : magnitude
    }

    // MARK: Words

    /// "07:00 to 18:30", in the locale's clock. Nil with no meals.
    public func windowText(locale: Locale = .current) -> String? {
        window.map { "\(LooprClockFormat.text(minuteOfDay: $0.lowerBound, locale: locale)) to \(LooprClockFormat.text(minuteOfDay: $0.upperBound, locale: locale))" }
    }

    /// "07:05 · 470 kcal" for one meal, "12:40 · 2 meals · 900 kcal" for a stack. The kcal part shows only when every
    /// meal in it reported energy.
    public static func label(for meals: [FoodRailMeal], locale: Locale = .current) -> String {
        guard let first = meals.first else { return "" }
        var parts = [LooprClockFormat.text(minuteOfDay: first.minute, locale: locale)]
        if meals.count > 1 { parts.append("\(meals.count) meals") }
        let energies = meals.compactMap(\.energy)
        if energies.count == meals.count, let total = LooprUnitFormatter.number(energies.reduce(0, +), digits: 0) { parts.append("\(total) kcal") }
        return parts.joined(separator: " · ")
    }

    /// What VoiceOver reads for the whole rail.
    public func accessibilitySummary(locale: Locale = .current) -> String {
        func clock(_ minute: Int) -> String { LooprClockFormat.text(minuteOfDay: minute, locale: locale) }
        var sentences: [String] = []
        if let window = windowText(locale: locale) { sentences.append("Eating window \(window).") }
        if meals.isEmpty { sentences.append(nowMinute == nil ? "Nothing logged on this day." : "Nothing logged yet today.") }
        for meal in meals {
            let energy = meal.energy.flatMap { LooprUnitFormatter.number($0, digits: 0) }.map { ", \($0) kilocalories" } ?? ""
            sentences.append("\(meal.slot.title) at \(clock(meal.minute))\(energy).")
        }
        if let closesMinute { sentences.append("Kitchen closes at \(clock(closesMinute)).") }
        if let nowMinute { sentences.append("Now \(clock(nowMinute)).") }
        return sentences.joined(separator: " ")
    }
}
