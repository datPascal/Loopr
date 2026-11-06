import AnalyticsKit
import Combine
import DataKit
import DesignSystem
import PhotosUI
import ProfileKit
import SwiftUI

/// Lab mode's screen over the camera (contract phone p-lab). The report lifts out of the photo like the food
/// sticker, a light sweeps its rows, and each value flies out as a chip. A value Loopr is unsure of glows amber and
/// waits. Saving writes the report to the lab store on this iPhone. Nothing is uploaded.
///
/// Lab mode wears Data's accent, the tab where blood tests live, not Food's.
///
/// The caller installs the dot flight over it with `looprDotFlightHost()`.
struct FoodLabView: View {
    @ObservedObject var lab: FoodLabModel
    let size: CGSize
    let insets: UIEdgeInsets
    let retake: @MainActor @Sendable () -> Void
    let done: @MainActor @Sendable () -> Void
    /// Reads a photo of the report from the library, as the camera's library button does.
    var importPhoto: (@MainActor (PhotosPickerItem) -> Void)?
    /// Opens the file picker for a PDF of the report. The camera screen owns the picker.
    var choosePDF: (@MainActor () -> Void)?
    @EnvironmentObject private var repositories: ProductRepositoryContainer
    @Environment(\.looprDotFlight) private var flight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.looprEntranceStore) private var entrance
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.looprOpenLabReport) private var openLabReport
    @State private var lifted = false
    @State private var sweep: CGFloat = 0
    @State private var sweeping = false
    @State private var flightStarted = false
    @State private var haptic: LooprHaptic?
    @State private var keyboard: CGFloat = 0
    @State private var editText = ""
    @State private var editUnit: String?
    @State private var editMessage: String?
    @State private var library: PhotosPickerItem?

    /// Lab mode's accent.
    private static let accent: LooprColorToken = .brand

    private var reduces: Bool { LooprMotion.reducesMotion(reduceMotion) }
    /// Reduce Motion and the final-state launch argument show the read at once, without the sweep or the flight.
    private var still: Bool { reduces || entrance.forcesFinalState }
    private var editingIndex: Int? {
        guard lab.stage == .review, let index = lab.editing, lab.values.indices.contains(index) else { return nil }
        return index
    }

    var body: some View {
        ZStack {
            background
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                        reportCard.frame(maxWidth: .infinity)
                        switch lab.stage {
                        case .reading: readingStatus
                        case .review, .saving: reviewContent
                        case .saved: savedContent
                        case .problem: problemContent
                        case .live: EmptyView()
                        }
                    }
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.md)
                    .padding(.bottom, LooprSpacing.lg)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: lab.editing) { _, index in
                    guard index != nil else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(320))
                        withAnimation(.snappy(duration: 0.3)) { scroller.scrollTo("food-lab-edit", anchor: .bottom) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            // The read scrolls below the header and the close button, never under them, and fades out at its top edge.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: LooprSpacing.md)
                    Color.black
                }
            }
            .padding(.top, insets.top + 62)
        }
        .frame(width: size.width, height: size.height)
        .onChange(of: lab.stage, initial: true) { _, stage in changed(to: stage) }
        .onChange(of: library) { _, item in
            guard let item else { return }
            importPhoto?(item)
            library = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboard = max(0, size.height - frame.minY)
        }
        .looprHaptic(haptic)
    }

    // MARK: Background

    private var background: some View {
        ZStack {
            Color.black
            if let backdrop = lab.report?.backdrop {
                Image(uiImage: backdrop).resizable().scaledToFill()
                    .blur(radius: 30).overlay(Color.black.opacity(0.62))
                    .transition(.opacity)
            }
            RadialGradient(colors: [Color.loopr(Self.accent).opacity(0.22), .clear], center: UnitPoint(x: 0.5, y: 0.32),
                           startRadius: 0, endRadius: max(size.height * 0.45, 1))
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityHidden(true)
    }

    // MARK: Report

    private func cardSize(aspect: CGFloat) -> CGSize {
        let share: CGFloat = lab.stage == .reading ? 0.5 : (typeSize.isAccessibilitySize ? 0.22 : 0.34)
        var height = size.height * share
        var width = height * aspect
        let widest = size.width - 2 * LooprSpacing.screenGutter - 60
        if width > widest { width = widest; height = width / max(aspect, 0.1) }
        return CGSize(width: max(width, 1), height: max(height, 1))
    }

    private var showsSweep: Bool { !still && (lab.stage == .reading || sweeping) }

    private var reportLabel: String {
        switch lab.stage {
        case .review, .saving, .saved: "Your lab report. \(lab.spokenSummary)"
        default: "Your lab report"
        }
    }

    private var reportCard: some View {
        let card = cardSize(aspect: lab.report?.aspect ?? 0.72)
        let settled = lifted || still
        return ZStack(alignment: .topLeading) {
            Group {
                if let image = lab.report?.image {
                    Image(uiImage: image).resizable().interpolation(.high)
                } else {
                    Color(red: 0.984, green: 0.972, blue: 0.949)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(reportLabel)
            rowMarks(card)
            if showsSweep {
                FoodLabSweep(loops: lab.stage == .reading, progress: sweep)
                    .accessibilityElement()
                    .accessibilityLabel("Reading the rows")
                    .accessibilityIdentifier("food-lab-sweep")
            }
        }
        .frame(width: card.width, height: card.height)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .looprDotFlightSource("food-lab-report")
        // The white edge and the lift of the food sticker, on the report rectangle.
        .padding(5)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.6), radius: 26, y: 18)
        .scaleEffect(settled ? 1 : 1.25)
        .opacity(settled ? 1 : 0.2)
        .blur(radius: settled ? 0 : 4)
        .looprPressTilt(maxDegrees: 4, resting: LooprTilt(degrees: still ? 0 : 4, axis: (1, -0.4)), isEnabled: !still)
        .animation(.snappy(duration: 0.4), value: lab.stage)
        .onAppear { lift() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("food-lab-report")
    }

    /// The rows read so far, marked on the page: teal for a value read, amber for one that needs a look.
    private func rowMarks(_ card: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(lab.rows.enumerated()), id: \.offset) { index, row in
                if let row, lab.landed.contains(index), lab.values.indices.contains(index) {
                    let review = lab.values[index].needsReview
                    let tone = Color.loopr(review ? .warning : .brand)
                    let height = max(card.height * 0.024, 6)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(tone.opacity(review ? 0.3 : 0.16))
                        .overlay(alignment: .leading) { Rectangle().fill(tone).frame(width: 2) }
                        .frame(width: card.width, height: height)
                        .offset(y: card.height * CGFloat(row) - height / 2)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: card.width, height: card.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func lift() {
        guard !lifted else { return }
        if still { lifted = true; return }
        withAnimation(.spring(response: 0.9, dampingFraction: 0.72)) { lifted = true }
    }

    private var readingStatus: some View {
        HStack(spacing: LooprSpacing.sm) {
            ProgressView().tint(Color.loopr(.ink))
            LooprText("Reading the rows", style: .title)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("food-lab-status")
    }

    // MARK: Review

    @ViewBuilder private var reviewContent: some View {
        chips
        if let index = editingIndex {
            FoodLabEditRow(value: lab.values[index], choices: lab.unitChoices(at: index), reasons: lab.reasons(at: index),
                           printedName: lab.printedName(at: index), text: $editText, unit: $editUnit, message: editMessage,
                           reassign: { subject in reassign(index, to: subject) },
                           remove: { remove(index) })
                .id("food-lab-edit")
                .transition(.opacity)
        }
        panel
    }

    private var chips: some View {
        AgentFlowLayout(horizontalSpacing: LooprSpacing.xs, verticalSpacing: LooprSpacing.xs) {
            ForEach(Array(lab.values.enumerated()), id: \.offset) { index, value in
                FoodLabChip(name: value.assay ?? value.subject.displayName,
                            value: (value.comparator?.symbol ?? "") + FoodLabModel.localised(value.displayValue, locale: LooprUnitFormatter.displayLocale),
                            unit: value.unit, flag: value.flagText, review: value.needsReview,
                            shown: lab.flightFinished || lab.landed.contains(index),
                            still: still, selected: lab.editing == index) { open(index) }
                    .looprDotFlightTarget("food-lab-chip-\(index)")
                    .accessibilityIdentifier(value.needsReview ? "food-lab-chip-review-\(index)" : "food-lab-chip-\(index)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            summary
            if lab.bloodAgeReady {
                Label {
                    LooprText("Blood age can be calculated", style: .label, color: .brand)
                } icon: {
                    Image(systemName: "checkmark.seal").foregroundStyle(Color.loopr(.brand))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("food-lab-blood-age-ready")
            }
            if let skipped = lab.skippedLine {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    Label {
                        LooprText("\(skipped). Type \(lab.skippedRows.count == 1 ? "it" : "them") in from the report after saving.",
                                  style: .caption, color: .warning)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.loopr(.warning))
                    }
                    ForEach(Array(lab.skippedRows.prefix(8).enumerated()), id: \.offset) { _, row in
                        Text(verbatim: row)
                            .looprTypography(.caption)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .lineLimit(2)
                            .padding(.leading, LooprSpacing.lg)
                    }
                    if lab.skippedRows.count > 8 {
                        LooprText("and \(lab.skippedRows.count - 8) more", style: .caption, color: .inkSecondary)
                            .padding(.leading, LooprSpacing.lg)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("food-lab-skipped")
            }
            if let line = lab.sessionLine {
                Label {
                    LooprText(line, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: lab.addsToSession ? "doc.on.doc" : "doc.badge.plus").foregroundStyle(Color.loopr(Self.accent))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("food-lab-session")
            }
            date
            // The chip holds one line, so it names the lab alone; where the reading happened is said under it.
            ProvenanceChip(.lab(name: lab.labName ?? ""), identifier: "food-lab-source")
            LooprText("Read on this iPhone. Units and ranges stay as your lab printed them. \(LooprMedicalLine.text)",
                      style: .caption, color: .inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(LooprSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.loopr(.surfaceElevated).opacity(0.92), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color.loopr(.surfaceEdge), lineWidth: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("food-lab-panel")
    }

    private var summary: some View {
        let count = lab.values.count
        let landed = lab.flightFinished ? count : min(lab.landed.count, count)
        return HStack(alignment: .center, spacing: LooprSpacing.md) {
            LooprHeroNumber(Double(count), style: .heroNumeralLarge,
                            countUp: still ? nil : LooprCountUp(from: 0, to: Double(count), total: count, landed: landed))
            VStack(alignment: .leading, spacing: 2) {
                LooprText(count == 1 ? "value read" : "values read", style: .title)
                LooprText(lab.reviewLine, style: .body, color: lab.needsReviewCount > 0 ? .warning : .inkSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lab.summary.replacingOccurrences(of: " · ", with: ", "))
        .accessibilityIdentifier("food-lab-summary")
    }

    @ViewBuilder private var date: some View {
        if lab.dateMissing {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprText(lab.dateFromSession
                          ? "No collection date on this page. It takes the date of the page you saved before it."
                          : "No collection date on this page. The photo's date stands in until you change it.",
                          style: .caption, color: .inkSecondary)
                    .accessibilityIdentifier("food-lab-date-missing")
                DatePicker("Collected", selection: $lab.collectedAt, in: ...latestDate, displayedComponents: .date)
                    .looprTypography(.rowTitle)
                    .tint(Color.loopr(Self.accent))
                    .environment(\.timeZone, lab.timeZone)
                    .frame(minHeight: LooprSpacing.interactiveRowHeight)
                    .accessibilityIdentifier("food-lab-date")
            }
        } else {
            LooprText("Collected \(lab.collectedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: lab.timeZone)))",
                      style: .caption, color: .inkSecondary)
                .accessibilityIdentifier("food-lab-date")
        }
    }

    private var latestDate: Date { max(lab.capturedAt ?? Date(), Date()) }

    // MARK: Saved and problems

    private var savedContent: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.loopr(Self.accent)).accessibilityHidden(true)
                LooprText(lab.savedTitle, style: .cardTitle)
                if let place = lab.savedPlaceLine {
                    LooprText(place, style: .body, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LooprText("Stored on this iPhone. Nothing was uploaded.", style: .body, color: .inkSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("food-lab-saved")
            if let outcome = lab.outcome, outcome.bloodAgeLine != nil || outcome.firstValuesLine != nil {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    if let line = outcome.bloodAgeLine {
                        Label {
                            LooprText(line, style: .body, color: .ink)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Circle().fill(Color.loopr(Self.accent)).frame(width: 8, height: 8)
                                .shadow(color: Color.loopr(Self.accent).opacity(0.7), radius: 4)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("food-lab-saved-blood-age")
                    }
                    if let line = outcome.firstValuesLine {
                        LooprText(line, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("food-lab-saved-new")
                    }
                }
            }
            if let openLabReport, let reportID = lab.savedReportID {
                // Its own element, so it stays a button for VoiceOver and for the UI tests.
                Button("See it in blood tests") {
                    // The camera closes first, then Data opens the report.
                    done()
                    openLabReport.open(reportID)
                }
                .buttonStyle(LooprButtonStyle(prominent: false, accent: Self.accent))
                .accessibilityIdentifier("food-lab-see-report")
            }
        }
        .padding(LooprSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.loopr(.surfaceElevated).opacity(0.92), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    @ViewBuilder private var problemContent: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            switch lab.problem {
            case .empty(let skipped)?:
                LooprText("No lab values found on this page", style: .cardTitle)
                LooprText(Self.emptyMessage(skipped: skipped), style: .body, color: .inkSecondary)
            case .unreadable?, nil:
                LooprText("Couldn't read this page", style: .cardTitle)
                LooprText("Try again, or choose a photo of the report.", style: .body, color: .inkSecondary)
            }
        }
        .padding(LooprSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.loopr(.surfaceElevated).opacity(0.92), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(lab.problem == .unreadable ? "food-lab-problem" : "food-lab-empty")
        otherRoutes
    }

    /// Other ways in when a page will not read: a photo or a PDF from the lab's portal, or typing the values.
    private var otherRoutes: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            if importPhoto != nil {
                PhotosPicker(selection: $library, matching: .images, preferredItemEncoding: .current) {
                    Label("Choose a photo or screenshot", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(LooprButtonStyle(prominent: false, accent: Self.accent))
                .accessibilityIdentifier("food-lab-choose-photo")
            }
            if let choosePDF {
                Button { choosePDF() } label: {
                    Label("Choose a PDF", systemImage: "doc.text")
                }
                .buttonStyle(LooprButtonStyle(prominent: false, accent: Self.accent))
                .accessibilityIdentifier("food-lab-choose-pdf")
            }
            if let openLabReport, openLabReport.openEntry != nil {
                Button { typeInstead(openLabReport) } label: {
                    Label("Type it in instead", systemImage: "square.and.pencil")
                }
                .buttonStyle(LooprButtonStyle(prominent: false, accent: Self.accent, quiet: true))
                .accessibilityIdentifier("food-lab-type-instead")
            }
        }
    }

    private func typeInstead(_ link: LabReportLink) {
        done()
        link.openEntry?()
    }

    static func emptyMessage(skipped: Int) -> String {
        let hint = "Hold the phone so one page fills the frame and the numbers are sharp."
        switch skipped {
        case 0: return hint
        case 1: return "1 row looked like a result but could not be read. \(hint)"
        default: return "\(skipped) rows looked like results but could not be read. \(hint)"
        }
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        if lab.stage != .reading, lab.stage != .live {
            VStack(spacing: LooprSpacing.xs) {
                if let error = lab.saveError {
                    LooprText(error, style: .caption, color: .critical)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("food-lab-error")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LooprSpacing.sm) { actionButtons }
                    VStack(spacing: LooprSpacing.xs) { actionButtons }
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.sm)
            .padding(.bottom, max(keyboard, insets.bottom, LooprSpacing.md) + LooprSpacing.xs)
            // Opaque, so nothing in the read shows through the buttons.
            .background(alignment: .top) {
                Color.black.overlay(alignment: .top) { Rectangle().fill(Color.loopr(.divider)).frame(height: 0.5) }
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var actionButtons: some View {
        if let index = editingIndex {
            Button("Cancel") { withAnimation(.snappy(duration: 0.3)) { lab.editing = nil } }
                .buttonStyle(LooprButtonStyle(prominent: false, accent: Self.accent))
                .accessibilityIdentifier("food-lab-edit-cancel")
            // "Save" is the whole report's word; this one keeps a single value.
            Button("Use this value") { confirm(index) }
                .buttonStyle(LooprButtonStyle(accent: Self.accent))
                .accessibilityIdentifier("food-lab-edit-confirm")
        } else {
            switch lab.stage {
            case .review, .saving:
                Button("Retake") { retake() }
                    .buttonStyle(LooprButtonStyle(prominent: false, accent: Self.accent))
                    .disabled(lab.stage == .saving)
                    .accessibilityIdentifier("food-lab-retake")
                Button(lab.stage == .saving ? "Saving" : "Save") { Task { await lab.save(to: store(), birthYear: birthYear()) } }
                    .buttonStyle(LooprButtonStyle(accent: Self.accent))
                    .disabled(lab.stage == .saving)
                    .accessibilityIdentifier("food-lab-save")
            case .saved:
                if let page = lab.pdfPage, !lab.queuedPages.isEmpty {
                    Button("Read page \(page.index + 1) of \(page.count)") { lab.readNextPage() }
                        .buttonStyle(LooprButtonStyle(prominent: false, accent: Self.accent))
                        .accessibilityIdentifier("food-lab-next-page")
                } else {
                    Button("Read another page") { retake() }
                        .buttonStyle(LooprButtonStyle(prominent: false, accent: Self.accent))
                        .accessibilityIdentifier("food-lab-retake")
                }
                Button("Done") { done() }
                    .buttonStyle(LooprButtonStyle(accent: Self.accent))
                    .accessibilityIdentifier("food-lab-done")
            case .problem:
                Button("Retake") { retake() }
                    .buttonStyle(LooprButtonStyle(accent: Self.accent))
                    .accessibilityIdentifier("food-lab-retake")
            case .live, .reading:
                EmptyView()
            }
        }
    }

    /// The profile's birth year, read when Save is tapped, so the saved card can say whether blood age came out.
    private func birthYear() -> @Sendable () async -> Int? {
        guard let profile = repositories.persistent?.profile else { return { nil } }
        return { try? await profile.readProfile()?.birthYear }
    }

    /// The store on the app's one database. Fixture launches have none, so they write to a temporary one.
    private func store() -> LabStore? {
        if let database = repositories.persistent?.database { return LabStore(database: database) }
        #if DEBUG
        if repositories.isFixtureComposition, let database = try? FoodLabFixture.database() { return LabStore(database: database) }
        #endif
        return nil
    }

    // MARK: Editing

    private func open(_ index: Int) {
        guard lab.stage == .review else { return }
        if lab.editing == index {
            withAnimation(.snappy(duration: 0.3)) { lab.editing = nil }
            return
        }
        editText = lab.valueText(at: index)
        editUnit = lab.unitSymbol(at: index)
        editMessage = nil
        withAnimation(.snappy(duration: 0.3)) { lab.editing = index }
    }

    private func confirm(_ index: Int) {
        let outcome = withAnimation(.snappy(duration: 0.3)) { lab.confirm(index, value: editText, unit: editUnit) }
        switch outcome {
        case .confirmed:
            editMessage = nil
            haptic = LooprHaptic(.impact(weight: .light))
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            AccessibilityNotification.Announcement("Value kept. \(lab.reviewLine).").post()
        case .invalidNumber:
            editMessage = "Type the number as it is printed, like \(FoodLabModel.localised("4.6", locale: LooprUnitFormatter.displayLocale)), or pick a sign for a limit such as <0.3."
            haptic = .error
        case .unitNeeded:
            editMessage = "Pick the unit printed on your report."
            haptic = .error
        case .unitNotListed:
            editMessage = "Pick one of the units listed."
            haptic = .error
        }
    }

    private func remove(_ index: Int) {
        withAnimation(.snappy(duration: 0.3)) { lab.remove(index) }
        editMessage = nil
        haptic = LooprHaptic(.impact(weight: .light))
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        AccessibilityNotification.Announcement("Value removed. \(lab.readLine).").post()
    }

    private func reassign(_ index: Int, to subject: LabValueSubject) {
        withAnimation(.snappy(duration: 0.3)) { lab.reassign(index, to: subject) }
        editUnit = lab.unitSymbol(at: index)
        editMessage = nil
    }

    // MARK: Flight

    private func changed(to stage: FoodLabModel.Stage) {
        switch stage {
        case .review: startFlight()
        case .saved:
            haptic = .success
            let extra = lab.outcome?.bloodAgeLine.map { " \($0)" } ?? ""
            AccessibilityNotification.Announcement("\(lab.savedTitle).\(extra)").post()
        case .problem: haptic = .error
        case .live, .reading: flightStarted = false; sweeping = false; sweep = 0
        case .saving: break
        }
    }

    /// The light passes the page once and each value's dots fly to its chip. It plays once per read.
    private func startFlight() {
        guard !lab.flightFinished, !flightStarted else { return }
        flightStarted = true
        guard !still else {
            lab.finishFlight()
            AccessibilityNotification.Announcement(lab.spokenSummary).post()
            return
        }
        Task { @MainActor in
            // The flight reads the frames the host resolved once the chips are laid out.
            try? await Task.sleep(for: .milliseconds(420))
            guard lab.stage == .review || lab.stage == .saving, !lab.flightFinished else { return }
            let duration = FoodLabFlight.sweepDuration(values: lab.values.count)
            var chips: [Int: CGRect] = [:]
            for index in lab.values.indices {
                if let frame = flight?.targets["food-lab-chip-\(index)"] { chips[index] = frame }
            }
            guard let flight, let page = flight.sources["food-lab-report"],
                  let plan = FoodLabFlight.plan(rows: lab.rows, review: lab.values.map(\.needsReview), page: page, chips: chips,
                                                sweep: duration, read: UIColor(Color.loopr(.brand)),
                                                uncertain: UIColor(Color.loopr(.warning))) else {
                lab.finishFlight()
                AccessibilityNotification.Announcement(lab.spokenSummary).post()
                return
            }
            sweeping = true
            withAnimation(.linear(duration: duration)) { sweep = 1 }
            let order = plan.request.landingOrder, owners = plan.owners, model = lab
            flight.play(plan.request, onLanding: { rank, _ in
                MainActor.assumeIsolated {
                    guard order.indices.contains(rank), owners.indices.contains(order[rank]) else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.62)) { model.land(owners[order[rank]]) }
                }
            }, completion: {
                MainActor.assumeIsolated {
                    withAnimation(.easeOut(duration: 0.25)) { model.finishFlight() }
                    AccessibilityNotification.Announcement(model.spokenSummary).post()
                }
            })
            try? await Task.sleep(for: .seconds(duration + 0.2))
            sweeping = false
        }
    }
}

// MARK: Pieces

/// One value read off the report: its name, number and unit, and the lab's own flag when it printed one. A scan error
/// that matters is often the unit, so the unit is always on the chip. An uncertain one glows amber and waits for a look.
private struct FoodLabChip: View {
    let name: String
    let value: String
    let unit: String?
    let flag: String?
    let review: Bool
    let shown: Bool
    let still: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let tone: LooprColorToken = review ? .warning : .brand
        Button(action: action) {
            HStack(spacing: 6) {
                Text(name).looprTypography(.label)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).looprTypography(.label).monospacedDigit().fontWeight(.semibold)
                    Text(unit ?? "no unit").looprTypography(.caption).opacity(unit == nil ? 0.6 : 0.8)
                }
                if let flag, !flag.isEmpty {
                    Text(verbatim: flag)
                        .looprTypography(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay { Capsule().strokeBorder(Color.loopr(tone).opacity(0.8), lineWidth: 1) }
                        .accessibilityHidden(true)
                }
                if review {
                    Image(systemName: "questionmark.circle.fill").font(.footnote.weight(.semibold)).accessibilityHidden(true)
                }
            }
            .foregroundStyle(Color.loopr(tone))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(Color.loopr(tone).opacity(review ? 0.22 : 0.16), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.loopr(tone).opacity(selected ? 0.95 : review ? 0.55 : 0.2), lineWidth: selected ? 1.5 : 0.5)
            }
            .shadow(color: review ? Color.loopr(.warning).opacity(0.55) : .clear, radius: review ? 10 : 0)
        }
        .buttonStyle(.looprPressableCard)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown || still ? 1 : 0.6)
        .accessibilityLabel(spoken)
        .accessibilityHint(review ? "Check the value and unit against your report" : "Correct the value")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var spoken: String {
        var text = "\(name), \(value)"
        text += unit.map { " \($0)" } ?? ", no unit printed"
        if let flag, !flag.isEmpty { text += ", lab flag \(flag)" }
        if review { text += ", needs a look" }
        return text
    }
}

/// The edit row for one value: why it needs a look, the lab's own range and flag, the number as printed with its sign,
/// the unit, which test it is, and a way to drop it. "Use this value" and Cancel sit in the bar under it, above the
/// keyboard; Save stays the whole report's word.
private struct FoodLabEditRow: View {
    let value: LabValue
    /// The marker's units. Empty for a test Loopr has no entry for, whose unit stays as printed.
    let choices: [String]
    let reasons: [LabReviewReason]
    /// The name as printed on the page, when it differs from the name shown.
    let printedName: String?
    @Binding var text: String
    @Binding var unit: String?
    let message: String?
    let reassign: (LabValueSubject) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(value.assay ?? value.subject.displayName, style: .cardTitle)
                if let printedName {
                    LooprText("Printed as \"\(printedName)\"", style: .caption, color: .inkSecondary)
                        .accessibilityIdentifier("food-lab-edit-printed-name")
                }
            }
            if !reasons.isEmpty {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    ForEach(reasons, id: \.self) { reason in
                        Label {
                            LooprText(FoodLabModel.sentence(for: reason), style: .caption, color: .warning)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "questionmark.circle").foregroundStyle(Color.loopr(.warning))
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("food-lab-edit-reason")
            }
            LooprText(Self.rangeText(value, locale: LooprUnitFormatter.displayLocale), style: .caption, color: .inkSecondary)
            if let flag = value.flagText {
                LooprText("Flag on your report: \(flag)", style: .caption, color: .inkSecondary)
            }
            HStack(spacing: LooprSpacing.sm) {
                LooprText("Value", style: .rowTitle)
                Spacer(minLength: LooprSpacing.sm)
                signMenu
                TextField("As printed", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .looprTypography(.metricValue)
                    .foregroundStyle(Color.loopr(.ink))
                    .accessibilityLabel("Value")
                    .accessibilityIdentifier("food-lab-edit-value")
            }
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            Divider().overlay(Color.loopr(.divider))
            HStack(spacing: LooprSpacing.sm) {
                LooprText("Unit", style: .rowTitle)
                Spacer(minLength: LooprSpacing.sm)
                if choices.isEmpty {
                    LooprText(value.unit ?? "Not printed", style: .body, color: .inkSecondary)
                        .accessibilityLabel(value.unit.map { "Unit as printed, \($0)" } ?? "No unit printed")
                        .accessibilityIdentifier("food-lab-edit-unit")
                } else {
                    Picker("Unit", selection: $unit) {
                        Text("Not printed").tag(String?.none)
                        ForEach(choices, id: \.self) { choice in Text(choice).tag(Optional(choice)) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(Color.loopr(.brand))
                    .accessibilityIdentifier("food-lab-edit-unit")
                }
            }
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            Divider().overlay(Color.loopr(.divider))
            HStack(spacing: LooprSpacing.sm) {
                LooprText("Test", style: .rowTitle)
                Spacer(minLength: LooprSpacing.sm)
                markerMenu
            }
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            if let message {
                LooprText(message, style: .caption, color: .critical).accessibilityIdentifier("food-lab-edit-error")
            }
            Button(role: .destructive, action: remove) {
                Label("Remove this value", systemImage: "minus.circle")
            }
            .buttonStyle(LooprButtonStyle(prominent: false, accent: .critical, quiet: true))
            .accessibilityHint("Leaves it out of the report")
            .accessibilityIdentifier("food-lab-edit-remove")
        }
        .padding(LooprSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.loopr(.surfaceElevated), in: RoundedRectangle(cornerRadius: LooprRadius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("food-lab-edit")
    }

    /// The decimal pad has no "<" or ">": a result printed as a limit gets its sign here.
    private var signMenu: some View {
        let current = LabValueComparator.split(text)
        return Menu {
            Button("A number") { text = current.rest }
            ForEach(LabValueComparator.allCases, id: \.self) { sign in
                Button(sign.symbol) { text = sign.symbol + current.rest }
            }
        } label: {
            Text(verbatim: current.comparator?.symbol ?? "=")
                .looprTypography(.metricValue)
                .foregroundStyle(Color.loopr(current.comparator == nil ? .inkSecondary : .ink))
                .frame(minWidth: 32, minHeight: 32)
                .background(Color.loopr(.surfaceSunk), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .accessibilityLabel(current.comparator.map { "Printed as a limit, \($0.symbol)" } ?? "Printed as a number")
        .accessibilityHint("Pick a sign when the report prints a limit, such as less than 0.3")
        .accessibilityIdentifier("food-lab-edit-sign")
    }

    /// Which test the value is. The name match can be wrong ("Hemoglobin" is not HbA1c), so every catalog marker is on
    /// offer, by body system, and the lab's own name can stay as another test.
    private var markerMenu: some View {
        Menu {
            ForEach(LabBodySystem.allCases, id: \.self) { system in
                Section(system.displayName) {
                    ForEach(LabMarkerCatalog.markers.filter { $0.bodySystem == system }, id: \.key) { marker in
                        Button(marker.displayName) { reassign(.marker(marker.key)) }
                    }
                }
            }
            if let printedName, value.subject.markerKey != nil {
                Section {
                    Button("Keep as \"\(printedName)\", another test") { reassign(.other(name: printedName)) }
                }
            }
        } label: {
            HStack(spacing: LooprSpacing.xxs) {
                Text(value.subject.displayName).looprTypography(.body).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .foregroundStyle(Color.loopr(.brand))
        }
        .accessibilityLabel("Test, \(value.subject.displayName)")
        .accessibilityHint("Pick another test when the name was matched to the wrong one")
        .accessibilityIdentifier("food-lab-edit-marker")
    }

    /// The lab's own range as printed. Loopr never compares the value with it.
    static func rangeText(_ value: LabValue, locale: Locale) -> String {
        let range = value.referenceRange
        func number(_ decimal: Decimal) -> String { FoodLabModel.localised(decimal.description, locale: locale) }
        if let text = range.text { return "Range on your report: \(text)" }
        if let low = range.low, let high = range.high { return "Range on your report: \(number(low)) to \(number(high))" }
        if let low = range.low { return "Range on your report: from \(number(low))" }
        if let high = range.high { return "Range on your report: up to \(number(high))" }
        return "No range printed for this value"
    }
}

/// The band of light that runs down the report: round and round while the page is read, then once more, at
/// `progress`, as the values fly out.
private struct FoodLabSweep: View {
    let loops: Bool
    let progress: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let band = max(proxy.size.height * 0.16, 36)
            if loops {
                TimelineView(.animation) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6
                    light(band).offset(y: -band + CGFloat(phase) * (proxy.size.height + band))
                }
            } else {
                light(band).offset(y: -band + progress * (proxy.size.height + band))
            }
        }
        .allowsHitTesting(false)
    }

    private func light(_ band: CGFloat) -> some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: Color.loopr(.brand).opacity(0.55), location: 0.85),
            .init(color: .white.opacity(0.9), location: 1)
        ], startPoint: .top, endPoint: .bottom)
        .frame(height: band)
        .blendMode(.multiply)
    }
}
