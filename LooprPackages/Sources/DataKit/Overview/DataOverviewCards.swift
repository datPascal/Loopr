import DesignSystem
import SwiftUI

// LV-08b step 1: the cards under the age ruler on the Data tab. Everything here is still: the ruler is the tab's one
// animated object (DESIGN_LANGUAGE premium check 6).

extension DataTrend {
    public var accent: LooprColorToken {
        switch self {
        case .improving: .brand
        case .steady: .inkSecondary
        case .watch: .warning
        // A lab marker that moved has a neutral colour of its own, neither good nor bad (DEC-12.6). Plain ink beside
        // steady's grey read as the same dot (ICP R2-OPT-28).
        case .changed: .sleep
        }
    }
}

// MARK: - Loopr Age, locked

/// Loopr Age sits frosted behind a lock until it passes validation (DEC-02.12). It shows words only, never a number.
public struct DataLooprAgeLockedTile: View {
    private let open: () -> Void

    public init(open: @escaping () -> Void) { self.open = open }

    public var body: some View {
        Button(action: open) {
            HStack(spacing: LooprSpacing.md) {
                Image(systemName: "lock")
                    .looprTypography(.rowTitle)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .frame(width: 42, height: 42)
                    .background(Color.loopr(.divider), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(DataLooprAgeTile.title, style: .rowTitle)
                    LooprText(DataLooprAgeTile.line, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: LooprSpacing.xs)
                Image(systemName: "chevron.right")
                    .looprTypography(.metricUnit)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, LooprSpacing.md + 2)
            .padding(.vertical, LooprSpacing.md)
            .frame(minHeight: 72)
            .background { DataFrostedStripes() }
            .looprGlass(in: RoundedRectangle(cornerRadius: LooprRadius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DataLooprAgeTile.spokenLabel)
        .accessibilityHint(DataLooprAgeTile.hint)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(DataLooprAgeTile.identifier)
    }
}

/// The contract's frosted stripes behind the locked tile.
struct DataFrostedStripes: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var offset: CGFloat = -size.height
            while offset < size.width {
                path.move(to: CGPoint(x: offset, y: size.height))
                path.addLine(to: CGPoint(x: offset + size.height, y: 0))
                offset += 10
            }
            context.stroke(path, with: .color(Color.loopr(.divider).opacity(0.7)), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: LooprRadius.card, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// What Loopr Age would be and why it is locked, for a person (ICP R2-LAB-15). It opens on the phone, with no network
/// request.
public struct DataLooprAgePlanPage: View {
    public init() {}

    public var body: some View {
        LooprDetailScaffold(spacing: LooprSpacing.lg) {
            LooprCard(style: .hero(.brand)) {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    StatusChip("Locked", symbol: "lock", accent: .brand)
                    LooprText(DataLooprAgePlan.intro, style: .prose)
                        .fixedSize(horizontal: false, vertical: true)
                    LooprText(DataLooprAgePlan.whyLocked, style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader(DataLooprAgePlan.stagesHeader)
                LooprCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        ForEach(Array(DataLooprAgePlan.stages.enumerated()), id: \.element.id) { index, stage in
                            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                                Text(verbatim: "\(index + 1)")
                                    .looprTypography(.rowTitle)
                                    .foregroundStyle(Color.loopr(.brand))
                                    .accessibilityHidden(true)
                                LooprText(stage.step, style: .prose, color: .ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("data-loopr-age-stage-\(stage.letter.lowercased())")
                        }
                    }
                }
            }
            LooprText(DataLooprAgePlan.otherAges, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            LooprText(DataAgeRuler.notAMedicalDevice, style: .caption, color: .inkSecondary)
        }
        .navigationTitle(DataLooprAgeTile.title)
        .toolbarTitleDisplayMode(.inline)
        .accessibilityIdentifier(DataLooprAgePlan.identifier)
    }
}

// MARK: - This year against last

public struct DataYearSlopesSection: View {
    private let comparison: DataYearComparison
    private let openAll: () -> Void
    private let openRow: ((DataYearSlope) -> Void)?

    /// - Parameter openRow: opens one row's history, a metric page or the blood tests (Data ICP R2-VET-01, R2-DES-08).
    public init(comparison: DataYearComparison, openAll: @escaping () -> Void, openRow: ((DataYearSlope) -> Void)? = nil) {
        self.comparison = comparison
        self.openAll = openAll
        self.openRow = openRow
    }

    public var body: some View {
        let rows = comparison.rows
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("This year against last",
                               detail: rows.isEmpty ? nil : "Last 90 days against the same days a year ago",
                               actionTitle: rows.isEmpty ? nil : "All metrics",
                               identifier: "data-year-slopes-header", actionIdentifier: "data-year-slopes-all",
                               action: rows.isEmpty ? nil : openAll)
            LooprCard(density: .flush) {
                VStack(spacing: 0) {
                    switch comparison {
                    case .rows(let rows):
                        ForEach(Array(rows.prefix(DataOverview.shownSlopes).enumerated()), id: \.element.id) { index, row in
                            if index > 0 { LooprHairline() }
                            if let openRow {
                                Button { openRow(row) } label: { DataYearSlopeRow(slope: row, opens: true) }
                                    .buttonStyle(.looprPressableRow)
                            } else {
                                DataYearSlopeRow(slope: row)
                            }
                        }
                    case .learning(let days):
                        DataSlopeMessage(title: "Opens in \(DataText.count(days, "day", "days"))",
                                         detail: "The comparison needs a year of data, so it opens a year after your first stored day.")
                    case .noData:
                        DataSlopeMessage(title: "No data yet",
                                         detail: "The comparison opens a year after your first stored day.")
                    case .notEnoughCoverage:
                        DataSlopeMessage(title: "Not enough days yet",
                                         detail: DataYearComparisonRule.ruleSentence)
                    }
                }
                .padding(.horizontal, LooprSpacing.formCardPadding)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("data-year-slopes")
    }
}

struct DataSlopeMessage: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: LooprSpacing.sm) {
            DataSlopeGlyph(trend: nil, direction: 0)
                .frame(width: 92, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(title, style: .rowTitle)
                LooprText(detail, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, LooprSpacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("data-year-slopes-message")
    }
}

struct DataYearSlopeRow: View {
    let slope: DataYearSlope
    var opens = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xs))
            : AnyLayout(HStackLayout(spacing: LooprSpacing.sm))
        layout {
            VStack(alignment: .leading, spacing: 1) {
                LooprText(slope.title, style: .rowTitle)
                // The window is named on the value, so 44.1 here and 47.5 on the tile read as two different things
                // (Data ICP R2-NEW-09, R2-VET-05).
                LooprText(slope.caption, style: .caption, color: .inkSecondary)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: LooprSpacing.xs) }
            HStack(spacing: LooprSpacing.sm) {
                DataSlopeGlyph(trend: slope.trend, direction: slope.direction)
                    .frame(width: 92, height: 30)
                Text(verbatim: slope.deltaText)
                    .looprTypography(.metricValue)
                    .monospacedDigit()
                    .foregroundStyle(Color.loopr(slope.trend.accent))
                    .frame(minWidth: 58, alignment: .trailing)
                if opens { LooprChevron() }
            }
        }
        .padding(.vertical, LooprSpacing.sm)
        .contentShape(Rectangle())
        .frame(minHeight: LooprRow<Image>.minimumTargetHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slope.spokenLabel)
        .accessibilityIdentifier("data-year-slope-\(slope.id)")
    }
}

/// Last year's median as a hollow dot on the left, this year's as a filled dot on the right, joined by a line that
/// rises when the value went up, falls when it went down and stays flat for steady. The colour carries the trend.
struct DataSlopeGlyph: View {
    let trend: DataTrend?
    /// 1 up, -1 down, 0 flat (`DataYearSlope.direction`).
    let direction: Int

    var body: some View {
        Canvas { context, size in
            let left = CGPoint(x: 8, y: size.height / 2)
            let endY: CGFloat = switch direction {
            case 1: 4
            case -1: size.height - 6
            default: size.height / 2
            }
            let right = CGPoint(x: size.width - 8, y: endY)
            let color = Color.loopr(trend?.accent ?? .inkMuted)
            var line = Path()
            line.move(to: left)
            line.addLine(to: right)
            context.stroke(line, with: .color(color.opacity(trend == nil ? 0.5 : 1)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: trend == nil ? [3, 3] : []))
            let hollow = Path(ellipseIn: CGRect(x: left.x - 3.4, y: left.y - 3.4, width: 6.8, height: 6.8))
            context.fill(hollow, with: .color(Color.loopr(.background)))
            context.stroke(hollow, with: .color(Color.loopr(.inkMuted)), lineWidth: 1.4)
            if trend != nil {
                context.fill(Path(ellipseIn: CGRect(x: right.x - 4.2, y: right.y - 4.2, width: 8.4, height: 8.4)), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Star map

public struct DataStarMapSection: View {
    private let map: DataStarMap
    private let addBloodTest: (() -> Void)?
    private let openStar: ((DataStar) -> Void)?
    @State private var opened: DataStarCluster?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameters:
    ///   - addBloodTest: opens the blood tests, from the card shown while no marker has a value.
    ///   - openStar: opens one marker's history from a system's sheet. Nil keeps the rows read-only.
    public init(map: DataStarMap, addBloodTest: (() -> Void)? = nil, openStar: ((DataStar) -> Void)? = nil) {
        self.map = map
        self.addBloodTest = addBloodTest
        self.openStar = openStar
    }

    public var body: some View {
        if map.measuredCount == 0 {
            emptyCard
        } else {
            filled
        }
    }

    /// With nothing measured, one calm card instead of 56 empty circles (ICP R1-NEW-9).
    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Your markers", identifier: "data-star-map-header")
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprText(DataStarMap.emptyTitle(map), style: .rowTitle)
                    LooprText(DataStarMap.emptyBody, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let addBloodTest {
                        LooprGlassButton("Add a blood test", symbol: "plus", prominent: true,
                                         identifier: "data-star-map-add", action: addBloodTest)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("data-star-map-empty")
    }

    private var filled: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("\(map.count) markers", detail: "By body system · \(map.measuredCount) measured",
                               identifier: "data-star-map-header")
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: LooprSpacing.xs),
                                             count: dynamicTypeSize.isAccessibilitySize ? 1 : 3),
                              spacing: LooprSpacing.sm) {
                        ForEach(map.clusters) { cluster in
                            Button { opened = cluster } label: { DataStarClusterView(cluster: cluster) }
                                .buttonStyle(.looprPressableRow)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(cluster.spokenLabel)
                                .accessibilityHint("Lists its markers.")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityIdentifier(cluster.system.identifier)
                        }
                    }
                    DataStarLegend()
                    LooprText(DataStarMap.changedNote + " " + DataStarMap.labNote, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("data-star-map")
        .sheet(item: $opened) { cluster in
            DataStarClusterSheet(cluster: cluster, openStar: openStar.map { open in
                { star in
                    opened = nil
                    open(star)
                }
            })
        }
    }
}

struct DataStarClusterView: View {
    let cluster: DataStarCluster

    var body: some View {
        VStack(spacing: LooprSpacing.xxs) {
            DataStarField(stars: cluster.stars)
                .frame(height: 76)
            Text(verbatim: "\(cluster.system.title) · \(cluster.stars.count)")
                .looprTypography(.caption)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 104)
        .contentShape(Rectangle())
    }
}

/// One cluster's stars on a sunflower spiral, joined by faint lines. Brightness is recency; colour is the trend; an
/// unmeasured marker is a dim outline.
struct DataStarField: View {
    let stars: [DataStar]

    var body: some View {
        Canvas { context, size in
            let points = DataStarMapRule.positions(count: stars.count)
            let reach = min(size.width / 2, size.height / 2 / 0.8) - 7
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let placed = points.map { CGPoint(x: center.x + $0.x * reach, y: center.y + $0.y * reach) }
            var links = Path()
            for index in placed.indices.dropFirst() {
                links.move(to: placed[max(0, index - 2)])
                links.addLine(to: placed[index])
            }
            // Lines and outlines in muted ink, not the divider, so they still read on the dark background.
            context.stroke(links, with: .color(Color.loopr(.inkMuted).opacity(0.55)), lineWidth: 0.8)
            for (index, star) in stars.enumerated() {
                let radius: CGFloat = index == 0 ? 5.4 : 3.9
                let rect = CGRect(x: placed[index].x - radius, y: placed[index].y - radius, width: radius * 2, height: radius * 2)
                if star.isAbsent {
                    context.stroke(Path(ellipseIn: rect.insetBy(dx: 0.6, dy: 0.6)), with: .color(Color.loopr(.inkSecondary).opacity(0.7)),
                                   lineWidth: 1)
                    continue
                }
                let color = Color.loopr(star.trend?.accent ?? .inkMuted)
                // Only a judged move glows; a lab marker that changed is a plain ink star.
                if star.trend == .improving || star.trend == .watch {
                    context.fill(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(color.opacity(0.22 * star.brightness)))
                }
                context.fill(Path(ellipseIn: star.trend == nil ? rect.insetBy(dx: 1, dy: 1) : rect),
                             with: .color(color.opacity(star.brightness)))
            }
        }
        .accessibilityHidden(true)
    }
}

struct DataStarLegend: View {
    var body: some View {
        let items: [(String, LooprColorToken, Bool)] = [
            ("improving", .brand, false), ("steady", .inkSecondary, false), ("watch", .warning, false),
            ("changed", .sleep, false),
            ("no comparison yet", .inkMuted, false), ("not measured", .inkMuted, true)
        ]
        DataFlowLayout(spacing: LooprSpacing.sm) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: LooprSpacing.xxs) {
                    Group {
                        if item.2 {
                            Circle().strokeBorder(Color.loopr(item.1), lineWidth: 1)
                        } else {
                            Circle().fill(Color.loopr(item.1))
                        }
                    }
                    .frame(width: 8, height: 8)
                    LooprText(item.0, style: .caption, color: .inkSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("data-star-legend")
    }
}

/// Wraps its children onto as many lines as they need. Sizing and placing break lines with one rule at one width, so
/// the height it reports is the height it draws. They used to differ: the star map legend reported two lines and drew
/// three, and "not measured" sat on the paragraph under it (ICP R2-UPG-19).
struct DataFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = Self.lines(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, width: proposal.width ?? .infinity, spacing: spacing)
        let widest = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, max(widest, 0)) } ?? widest,
                      height: lines.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        // The width the size was measured at, not the bounds, which can come back narrower by a rounding step.
        let lines = Self.lines(sizes: sizes, width: proposal.width ?? bounds.width, spacing: spacing)
        for line in lines {
            var x = bounds.minX
            for index in line.indices {
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + line.y), proposal: ProposedViewSize(sizes[index]))
                x += sizes[index].width + spacing
            }
        }
    }

    struct Line: Equatable {
        var indices: [Int]
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
    }

    /// Children in order, a new line whenever the next one would pass `width`. Half a point of slack absorbs rounding.
    static func lines(sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> [Line] {
        var lines: [Line] = []
        for (index, size) in sizes.enumerated() {
            if var line = lines.last, line.width + spacing + size.width <= width + 0.5 {
                line.indices.append(index)
                line.width += spacing + size.width
                line.height = max(line.height, size.height)
                lines[lines.count - 1] = line
            } else {
                let y = lines.last.map { $0.y + $0.height + spacing / 2 } ?? 0
                lines.append(Line(indices: [index], y: y, width: size.width, height: size.height))
            }
        }
        return lines
    }
}

struct DataStarClusterSheet: View {
    let cluster: DataStarCluster
    var openStar: ((DataStar) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LooprDetailScaffold(spacing: LooprSpacing.md) {
                DataStarField(stars: cluster.stars)
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                LooprCard(density: .flush) {
                    VStack(spacing: 0) {
                        ForEach(Array(cluster.stars.enumerated()), id: \.element.id) { index, star in
                            if index > 0 { LooprHairline() }
                            if let openStar, !star.isAbsent, DataStarMapRule.labMarkerKey(star) != nil {
                                Button { openStar(star) } label: {
                                    HStack(spacing: LooprSpacing.xs) {
                                        DataStarRow(star: star)
                                        LooprChevron()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.looprPressableRow)
                            } else {
                                DataStarRow(star: star)
                            }
                        }
                    }
                    .padding(.horizontal, LooprSpacing.formCardPadding)
                }
                if cluster.stars.contains(where: { $0.source == .lab }) {
                    LooprText(DataStarMap.labNote, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LooprText(DataAgeRuler.notAMedicalDevice, style: .caption, color: .inkSecondary)
            }
            .navigationTitle(cluster.system.title)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("data-star-cluster-done")
                }
            }
        }
        .accessibilityIdentifier("data-star-cluster-sheet")
    }
}

struct DataStarRow: View {
    let star: DataStar

    var body: some View {
        HStack(alignment: .top, spacing: LooprSpacing.sm) {
            Group {
                if star.isAbsent {
                    Circle().strokeBorder(Color.loopr(.inkMuted), lineWidth: 1)
                } else {
                    Circle().fill(Color.loopr(star.trend?.accent ?? .inkMuted).opacity(max(star.brightness, 0.3)))
                }
            }
            .frame(width: 10, height: 10)
            .padding(.top, 5)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(star.title, style: .rowTitle)
                LooprText(detail, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                LooprText(star.note, style: .caption, color: .inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: LooprSpacing.xs)
            if let trend = star.trend {
                LooprText(trend.title, style: .caption, color: trend.accent)
            }
        }
        .padding(.vertical, LooprSpacing.sm)
        .frame(minHeight: LooprRow<Image>.minimumTargetHeight)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("data-star-\(star.id)")
    }

    private var detail: String {
        guard let text = star.latestText, let date = star.latestDate else { return "Not measured" }
        let source = switch star.source {
        case .band: "band"
        case .appleHealth: "Apple Health"
        case .lab: "lab report"
        }
        return "\(text) · \(date.formatted(.dateTime.day().month(.abbreviated).year())) · \(source)"
    }
}

// MARK: - Vault

/// What the vault says about copies that leave the iPhone.
public enum DataVaultCopy {
    public static let backupLine = "Weekly backup, once you turn it on, copies everything, blood tests too, to the Files folder you pick. The copy is a ZIP that Loopr does not encrypt, and a folder in iCloud Drive syncs it to iCloud."
}

public struct DataVaultSection: View {
    private let card: DataVaultCard?
    private let isLoading: Bool
    private let rows: [DataSourceRow]
    private let export: () -> Void
    private let backup: () -> Void
    private let publish: () -> Void
    private let openSource: (DataSourceKind) -> Void

    /// - Parameters:
    ///   - card: nil while the databases are read (`isLoading`) or when they could not be read.
    ///   - publish: opens Make a report file (once called Publish a page).
    ///   - openSource: opens a source's screen. The labs row opens the blood tests.
    public init(card: DataVaultCard?, isLoading: Bool = false, rows: [DataSourceRow], export: @escaping () -> Void,
                backup: @escaping () -> Void, publish: @escaping () -> Void, openSource: @escaping (DataSourceKind) -> Void) {
        self.card = card
        self.isLoading = isLoading
        self.rows = rows
        self.export = export
        self.backup = backup
        self.publish = publish
        self.openSource = openSource
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Your vault", detail: "On this iPhone until you export or back up", identifier: "data-vault-header")
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    file
                    // Say where the copies go: the backup holds every table, blood tests too, and is not encrypted.
                    LooprText(DataVaultCopy.backupLine, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("data-vault-backup-note")
                    DataFlowLayout(spacing: LooprSpacing.xs) {
                        LooprGlassButton("Export", symbol: "square.and.arrow.up", prominent: true, identifier: "data-vault-export", action: export)
                        LooprGlassButton("Back up to Files", symbol: "folder", identifier: "data-vault-backup", action: backup)
                        LooprGlassButton("Make a report file", symbol: "doc.richtext", identifier: "data-vault-publish", action: publish)
                    }
                    VStack(spacing: 0) {
                        ForEach(rows) { row in sourceRow(row) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("data-vault")
    }

    private var file: some View {
        HStack(spacing: LooprSpacing.md) {
            DataSQLiteDocument()
                .frame(width: 54, height: 66)
                .looprPressTilt()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                Text(verbatim: card?.fileName ?? "Your data")
                    .looprTypography(.rowTitle)
                    .monospaced()
                    .foregroundStyle(Color.loopr(.ink))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                LooprText(card?.detail ?? (isLoading ? "Reading its size on this iPhone."
                    : "Loopr could not read the database size. Open Data again to retry."),
                          style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card?.spokenLabel ?? (isLoading ? "Your data, reading its size." : "Your data. Its size could not be read."))
        .accessibilityIdentifier("data-vault-file")
    }

    @ViewBuilder
    private func sourceRow(_ row: DataSourceRow) -> some View {
        let content = HStack(spacing: LooprSpacing.sm) {
            Circle()
                .fill(Color.loopr(row.kind.accent))
                .frame(width: 7, height: 7)
                .shadow(color: Color.loopr(row.kind.accent).opacity(0.7), radius: 4)
                .accessibilityHidden(true)
            LooprText(row.text, style: .body, color: .ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: LooprSpacing.xs)
            Image(systemName: "chevron.right")
                .looprTypography(.metricUnit)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .accessibilityHidden(true)
        }
        .frame(minHeight: LooprRow<Image>.minimumTargetHeight)
        .contentShape(Rectangle())
        Button { openSource(row.kind) } label: { content }
            .buttonStyle(.looprPressableRow)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(row.kind.identifier)
    }
}

/// The file you can hold: a paper sheet with a folded corner and "Loopr" in the brand ink.
struct DataSQLiteDocument: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 1), Color(red: 0.914, green: 0.890, blue: 0.847)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 8)
            Text(verbatim: "Loopr")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(red: 0.055, green: 0.455, blue: 0.392))
                .padding(.bottom, 7)
        }
        .overlay(alignment: .topTrailing) {
            Canvas { context, size in
                var fold = Path()
                fold.move(to: CGPoint(x: 0, y: 0))
                fold.addLine(to: CGPoint(x: size.width, y: size.height))
                fold.addLine(to: CGPoint(x: 0, y: size.height))
                fold.closeSubpath()
                context.fill(fold, with: .color(Color(red: 0.839, green: 0.812, blue: 0.761)))
                var page = Path()
                page.move(to: .zero)
                page.addLine(to: CGPoint(x: size.width, y: 0))
                page.addLine(to: CGPoint(x: size.width, y: size.height))
                page.closeSubpath()
                context.fill(page, with: .color(Color.loopr(.background)))
            }
            .frame(width: 16, height: 16)
        }
    }
}
