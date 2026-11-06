import Foundation

/// Where the dots of one dose row sit: left to right, row by row, each `diameter` wide with `gap`
/// between them. The view draws from it and the dot flight lands on it, so a flying dot lands exactly
/// where its dot is drawn.
public struct FitnessDotLayout: Equatable, Sendable {
    /// Zone 2 dots, as the contract's 12 pt.
    public static let standardDiameter: CGFloat = 12
    /// Hard minutes are rarer, so their dots are larger.
    public static let hardDiameter: CGFloat = 24
    public static let gap: CGFloat = 5

    public let count: Int
    public let diameter: CGFloat
    public let gap: CGFloat
    /// Dots per row, at least one.
    public let columns: Int

    /// Rows a dose row keeps before its dots shrink. Three keeps the whole dose card on one screen (R2-DES-08).
    public static let maximumRows = 3

    /// The dot size a row starts from: smaller past 30 dots and again past 60, so a long target such as 315 Zone 2
    /// minutes (63 dots) reads as a block, not a wall (R2-DES-08).
    public static func diameter(forCount count: Int, standard: CGFloat) -> CGFloat {
        count > 60 ? min(standard, 8) : count > 30 ? min(standard, 10) : standard
    }
    /// The smallest a dot gets. Past this the rows grow again, and the count beside the row still says the minutes.
    public static let minimumDiameter: CGFloat = 7

    /// A layout whose dots shrink, a point at a time from `diameter` down to `minimumDiameter`, until `count` dots fit
    /// in `maximumRows`. A long week past 100 minutes of hard work or 300 of Zone 2 stays a block you can read at a
    /// glance instead of a wall. The view and the flight both build it this way, so dots still land where drawn.
    public static func fitting(count: Int, width: CGFloat, diameter: CGFloat, gap: CGFloat = FitnessDotLayout.gap)
        -> FitnessDotLayout {
        var size = diameter
        var layout = FitnessDotLayout(count: count, width: width, diameter: size, gap: gap)
        while layout.rows > maximumRows, size - 1 >= minimumDiameter {
            size -= 1
            layout = FitnessDotLayout(count: count, width: width, diameter: size, gap: min(gap, max(size / 2.4, 3)))
        }
        return layout
    }

    public init(count: Int, width: CGFloat, diameter: CGFloat, gap: CGFloat = FitnessDotLayout.gap) {
        self.count = max(count, 0)
        self.diameter = max(diameter, 1)
        self.gap = max(gap, 0)
        let usable = width.isFinite ? max(width, 0) : 0
        columns = max(Int(((usable + self.gap) / (self.diameter + self.gap)).rounded(.down)), 1)
    }

    public var rows: Int { count == 0 ? 0 : (count + columns - 1) / columns }

    /// The height the dots need.
    public var height: CGFloat {
        rows == 0 ? 0 : CGFloat(rows) * diameter + CGFloat(rows - 1) * gap
    }

    /// The centre of dot `index`, in the row's own coordinates.
    public func center(of index: Int) -> CGPoint {
        let column = index % columns, row = index / columns
        let step = diameter + gap
        return CGPoint(x: CGFloat(column) * step + diameter / 2, y: CGFloat(row) * step + diameter / 2)
    }

    /// The square dot `index` is drawn in.
    public func frame(of index: Int) -> CGRect {
        let center = center(of: index)
        return CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
    }
}

/// How one row of dots reads: which are filled, which are still to go, and which are held back
/// because they are in flight.
public struct FitnessDotFill: Equatable, Sendable {
    public enum Dot: Equatable, Sendable {
        /// Minutes measured.
        case filled
        /// Measured but still flying in. Drawn as an empty slot until its dot lands.
        case arriving
        /// Still to go before the target.
        case empty
    }

    public let filled: Int
    /// Nil without a target: only the measured dots are drawn.
    public let total: Int?
    /// The last `arriving` of the filled dots are still in flight.
    public let arriving: Int

    public init(filled: Int, total: Int?, arriving: Int = 0) {
        self.filled = max(filled, 0)
        self.total = total.map { max($0, 0) }
        self.arriving = min(max(arriving, 0), max(filled, 0))
    }

    public init(_ dots: DoseDots, arriving: Int = 0) {
        self.init(filled: dots.filled, total: dots.total, arriving: arriving)
    }

    /// Every dot drawn: the filled ones, and with a target the empty ones up to it. A week past its
    /// target keeps every filled dot.
    public var count: Int { max(filled, total ?? 0) }

    public func dot(at index: Int) -> Dot {
        if index < filled - arriving { return .filled }
        if index < filled { return .arriving }
        return .empty
    }
}
