import AIKit
import DesignSystem
import FoodKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The food camera, full screen. Point it at a plate or a barcode: a barcode is lifted out of the frame
/// and looked up, a photo becomes a sticker and is estimated. The result rises from the bottom to be
/// checked, and adding it breaks the picture into macro dots that fill the day's rings.
struct FoodLensView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model: FoodLensModel
    @State private var placement = Placement.origin
    @State private var editing = false
    @State private var typing = false
    @State private var typed = ""
    @State private var burst: FoodBurstRequest?
    @State private var saving = false
    @State private var error: String?
    @State private var expanded: UUID?
    @State private var library: PhotosPickerItem?
    @State private var choosingLabPDF = false
    @State private var flash = false
    @State private var haptic: LooprHaptic?
    @State private var size = CGSize.zero
    let day: FoodBurstDay
    let close: @MainActor @Sendable () -> Void
    let save: @MainActor @Sendable (FoodMealDraft) async throws -> Void
    let finished: @MainActor @Sendable (FoodMealDraft) -> Void

    /// Where the picture sits: where it was in the frame, large in the middle while it is read, or
    /// small at the top above the result.
    enum Placement { case origin, hero, top }

    /// - Parameter lens: the mode the camera opens in; Blood tests opens Lab mode.
    init(draft: FoodMealDraft, repository: AppFoodRepository, fixture: Bool, now: Date, day: FoodBurstDay,
         lens: FoodLensModel.Lens = .food,
         close: @escaping @MainActor @Sendable () -> Void,
         save: @escaping @MainActor @Sendable (FoodMealDraft) async throws -> Void,
         finished: @escaping @MainActor @Sendable (FoodMealDraft) -> Void) {
        _model = StateObject(wrappedValue: {
            let model = FoodLensModel(draft: draft, repository: repository, fixture: fixture, now: now)
            model.lens = lens
            return model
        }())
        self.day = day; self.close = close; self.save = save; self.finished = finished
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let metrics = Metrics(size: proxy.size, insets: Self.windowInsets)
                ZStack(alignment: .topLeading) {
                    Color.black
                    viewfinder(metrics)
                    picture(metrics)
                    reading(metrics)
                    if model.stage == .result || model.stage == .problem {
                        panel(metrics)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if model.labActive {
                        FoodLabView(lab: model.lab, size: metrics.size, insets: metrics.insets,
                                    retake: { Task { await model.retakeLab() } },
                                    done: { Task { await model.stop() }; close() },
                                    importPhoto: { item in Task { await model.importPhoto(item) } },
                                    choosePDF: { choosingLabPDF = true })
                            .looprDotFlightHost()
                            .transition(.opacity)
                    }
                    FoodMacroBurst(request: burst, reduceMotion: reduceMotion) { done() }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    chrome(metrics)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .onChange(of: proxy.size, initial: true) { _, value in size = value }
            }
            .ignoresSafeArea()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $editing) { review }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(model.stage == .live)
        .task { await model.prepare() }
        .onDisappear { Task { await model.stop() } }
        .onChange(of: library) { _, item in
            guard let item else { return }
            Task { await model.importPhoto(item); library = nil }
        }
        .fileImporter(isPresented: $choosingLabPDF, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { Task { await model.importLabPDF(url) } }
        }
        .onChange(of: model.subject) { _, subject in
            guard subject != nil, model.stage == .reading else { return }
            fly()
        }
        .onChange(of: model.stage) { old, stage in
            switch stage {
            case .result:
                haptic = .success
                withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { placement = .top }
                if model.items.count == 1 { expanded = model.items.first?.id }
            case .problem:
                haptic = .error
                withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { placement = .top }
            case .live: placement = .origin; expanded = nil; error = nil
            case .reading: if old == .live, model.kind == .barcode { haptic = LooprHaptic(.impact(weight: .medium)) }
            case .burst: break
            }
        }
        .alert("Type the barcode", isPresented: $typing) {
            TextField("Digits under the bars", text: $typed)
                .keyboardType(.numberPad)
                .accessibilityIdentifier("food-lens-barcode-field")
            Button("Look up") { model.typed(typed); typed = "" }
            Button("Cancel", role: .cancel) { typed = "" }
        } message: {
            Text("Loopr looks it up on Open Food Facts.")
        }
        .looprHaptic(haptic)
        .animation(.spring(response: 0.5, dampingFraction: 0.88), value: model.stage)
        .animation(.easeOut(duration: 0.3), value: model.labActive)
    }

    // MARK: Layout

    struct Metrics {
        let size: CGSize
        let insets: UIEdgeInsets
        static let controls: CGFloat = 176
        var preview: CGRect {
            CGRect(x: 6, y: insets.top + 4, width: size.width - 12,
                   height: max(size.height - insets.top - 4 - Self.controls - insets.bottom, 200))
        }
        func hero(_ aspect: CGFloat) -> CGRect {
            var width = size.width - 56
            var height = width / aspect
            let limit = size.height * 0.42
            if height > limit { height = limit; width = height * aspect }
            let middle = insets.top + (size.height - insets.top - insets.bottom) * 0.42
            return CGRect(x: (size.width - width) / 2, y: middle - height / 2, width: width, height: height)
        }
        func top(_ aspect: CGFloat) -> CGRect {
            var height = size.height * 0.19
            var width = height * aspect
            if width > size.width * 0.62 { width = size.width * 0.62; height = width / aspect }
            return CGRect(x: (size.width - width) / 2, y: insets.top + 58, width: width, height: height)
        }
        func panelTop(_ aspect: CGFloat) -> CGFloat { top(aspect).maxY + 20 }
        /// Fits a picture with `region` of a source of `aspect` into the preview the way the camera fills it.
        func origin(of region: CGRect?, aspect: CGFloat) -> CGRect {
            let frame = preview
            guard let region else { return CGRect(x: frame.midX - 40, y: frame.midY - 20, width: 80, height: 40) }
            let scale = max(frame.width / aspect, frame.height)
            let shown = CGSize(width: scale * aspect, height: scale)
            let corner = CGPoint(x: frame.midX - shown.width / 2, y: frame.midY - shown.height / 2)
            return CGRect(x: corner.x + region.minX * shown.width, y: corner.y + region.minY * shown.height,
                          width: region.width * shown.width, height: region.height * shown.height)
        }
    }

    private static var windowInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets ?? .zero
    }

    /// Width over height of what is shown: the clean card for a barcode, else the picture itself.
    private var aspect: CGFloat {
        guard let image = model.card ?? model.subject, image.size.height > 0 else { return 1 }
        return image.size.width / image.size.height
    }

    private func frame(_ metrics: Metrics) -> CGRect {
        switch placement {
        case .origin:
            let start = metrics.origin(of: model.region, aspect: model.sourceAspect)
            // The crop lifts out at its own shape; the clean card takes over once it lands.
            guard let subject = model.subject, subject.size.height > 0 else { return start }
            let ratio = subject.size.width / subject.size.height
            let width = sqrt(start.width * start.height * ratio), height = width / ratio
            return CGRect(x: start.midX - width / 2, y: start.midY - height / 2, width: width, height: height)
        case .hero: return metrics.hero(aspect)
        case .top: return metrics.top(aspect)
        }
    }

    private func fly() {
        var instant = Transaction(); instant.disablesAnimations = true
        withTransaction(instant) { placement = .origin }
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.62, dampingFraction: 0.78)) { placement = .hero }
        }
    }

    // MARK: Viewfinder

    @ViewBuilder private func viewfinder(_ metrics: Metrics) -> some View {
        let frame = metrics.preview
        let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)
        ZStack {
            if model.stage == .live {
                if let bytes = model.fixturePhoto?.bytes, let image = UIImage(data: bytes) {
                    Image(uiImage: image).resizable().scaledToFill().accessibilityLabel("Seeded food photo")
                } else if model.cameraReady {
                    FoodCameraPreview(camera: model.camera).accessibilityHidden(true)
                } else {
                    Color.loopr(.surfaceElevated)
                    VStack(spacing: LooprSpacing.md) {
                        Image(systemName: "camera").font(.system(size: 34, weight: .medium)).foregroundStyle(Color.loopr(.inkSecondary))
                            .accessibilityHidden(true)
                        LooprText(model.cameraMessage ?? "Opening camera", style: .body, color: .inkSecondary)
                            .multilineTextAlignment(.center)
                        if model.cameraMessage != nil {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }.buttonStyle(LooprButtonStyle(prominent: false, accent: .energy)).fixedSize()
                        }
                    }.padding(LooprSpacing.xl)
                }
                FoodLensFinder(barcode: model.lens == .food).padding(frame.width * 0.14).allowsHitTesting(false)
                VStack(spacing: LooprSpacing.xs) {
                    Spacer()
                    if !model.labels.isEmpty, model.lens == .food {
                        HStack(spacing: LooprSpacing.xs) {
                            ForEach(model.labels, id: \.self) { label in
                                Text(label.capitalized).looprTypography(.chip).foregroundStyle(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                        }.transition(.opacity)
                    }
                    Text(model.lens == .food ? "Point at your plate or a barcode"
                         : model.lens == .label ? "Fill the frame with the nutrition table" : "Fill the frame with one page of your report")
                        .looprTypography(.label).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.35), in: Capsule())
                        .accessibilityIdentifier("food-lens-hint")
                }.padding(.bottom, LooprSpacing.lg)
                Color.white.opacity(flash ? 0.85 : 0).allowsHitTesting(false)
            } else if let backdrop = model.backdrop {
                Image(uiImage: backdrop).resizable().scaledToFill()
                    .blur(radius: 28).overlay(Color.black.opacity(model.stage == .burst ? 0.7 : 0.5))
                    .transition(.opacity).accessibilityHidden(true)
            } else {
                LinearGradient(colors: [Color.loopr(.energy).opacity(0.18), .black], startPoint: .top, endPoint: .bottom)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(shape)
        .position(x: frame.midX, y: frame.midY)
        .animation(.easeOut(duration: 0.35), value: model.stage)
        .animation(.easeOut(duration: 0.25), value: model.labels)
        .accessibilityElement(children: .contain)
        .accessibilityHidden(model.labActive)
        .accessibilityIdentifier("food-capture-preview")
    }

    // MARK: Picture

    @ViewBuilder private func picture(_ metrics: Metrics) -> some View {
        if model.stage != .live, let subject = model.subject {
            let rect = frame(metrics)
            let barcode = model.kind == .barcode
            ZStack {
                Image(uiImage: subject).resizable()
                    .aspectRatio(contentMode: barcode ? .fill : .fit)
                if barcode, let card = model.card {
                    Image(uiImage: card).resizable().transition(.opacity)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .clipShape(RoundedRectangle(cornerRadius: barcode ? rect.height * 0.12 : 0, style: .continuous))
            .overlay { if model.stage == .reading { FoodLensScan(subject: model.card ?? subject, barcode: barcode) } }
            .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
            // The sticker leans 4° while it is large in the middle, and tilts towards a finger held on it.
            .looprPressTilt(maxDegrees: 4, resting: LooprTilt(degrees: placement == .hero && !barcode ? 4 : 0, axis: (1, -0.4)),
                            isEnabled: placement == .hero && !barcode)
            .position(x: rect.midX, y: rect.midY)
            .opacity(burst == nil ? 1 : 0)
            .animation(.easeInOut(duration: 0.45), value: model.card)
            .accessibilityElement()
            .accessibilityLabel(barcode ? "Barcode \(model.code ?? "")" : model.kind == .label ? "Your label photo" : "Your food")
            .accessibilityIdentifier("food-lens-subject")
        }
    }

    @ViewBuilder private func reading(_ metrics: Metrics) -> some View {
        if model.stage == .reading, let status = model.status {
            let below = model.subject == nil ? metrics.size.height * 0.46 : metrics.hero(aspect).maxY + 44
            VStack(spacing: LooprSpacing.xs) {
                FoodLensShimmer(text: status)
            }
            .frame(width: metrics.size.width)
            .position(x: metrics.size.width / 2, y: below)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("food-lens-status")
        }
    }

    // MARK: Panel

    @ViewBuilder private func panel(_ metrics: Metrics) -> some View {
        let top = model.subject == nil ? metrics.insets.top + 80 : metrics.panelTop(aspect)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                    if model.stage == .problem, let problem = model.problem { problemContent(problem) }
                    else { resultContent }
                    if let error { LooprText(error, style: .body, color: .critical).accessibilityIdentifier("food-lens-error") }
                }
                .padding(.horizontal, LooprSpacing.xl).padding(.top, LooprSpacing.xl).padding(.bottom, LooprSpacing.md)
            }
            .scrollBounceBehavior(.basedOnSize)
            actions.padding(.horizontal, LooprSpacing.xl).padding(.top, LooprSpacing.sm)
                .padding(.bottom, max(metrics.insets.bottom, LooprSpacing.md) + LooprSpacing.xs)
        }
        .frame(width: metrics.size.width, height: metrics.size.height - top)
        .background(Color.loopr(.sheetFill), in: UnevenRoundedRectangle(topLeadingRadius: LooprRadius.sheet, topTrailingRadius: LooprRadius.sheet, style: .continuous))
        .overlay(alignment: .top) {
            Capsule().fill(Color.loopr(.divider)).frame(width: 36, height: 5).padding(.top, 8).accessibilityHidden(true)
        }
        .offset(y: top)
        .opacity(model.stage == .burst ? 0 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("food-lens-panel")
    }

    @ViewBuilder private var resultContent: some View {
        let totals = model.totals
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            HStack(alignment: .firstTextBaseline) {
                LooprText(model.title, style: .cardTitle).lineLimit(2)
                Spacer(minLength: LooprSpacing.sm)
                slotMenu
            }
            if let detail = model.detail { LooprText(detail, style: .caption, color: .inkSecondary).accessibilityIdentifier("food-lens-detail") }
        }
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
            Text(FoodMacroBurstView.number(totals.energy))
                .looprTypography(.display).foregroundStyle(Color.loopr(.ink))
                .contentTransition(.numericText(value: totals.energy))
            LooprText("kcal", style: .title, color: .inkSecondary)
        }
        .animation(.snappy(duration: 0.3), value: totals.energy)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("food-lens-energy")
        FoodLensMacroSplit(totals: totals)
        if model.items.count == 1, let item = model.items.first {
            amount(for: item)
        } else {
            VStack(spacing: 0) {
                ForEach(model.shownItems) { item in
                    itemRow(item)
                    if item.id != model.shownItems.last?.id { Divider().overlay(Color.loopr(.divider)) }
                }
            }
            .padding(.horizontal, LooprSpacing.md)
            .background(Color.loopr(.surface), in: RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous))
        }
        if model.kind == .barcode {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(FoodProductSource.attribution, style: .caption, color: .inkMuted)
                Link("Open Database License", destination: FoodProductSource.databaseLicense)
                    .looprTypography(.caption).tint(Color.loopr(.energy)).accessibilityIdentifier("food-product-license")
            }
        }
    }

    private func amount(for item: FoodItem) -> some View {
        let unit = item.unit
        let fine = unit == .grams || unit == .millilitres
        let value = model.amounts[item.id] ?? item.amount
        let presets: [Double] = unit == .millilitres ? [100, 250, 330, 500] : unit == .grams ? [30, 50, 100, 200] : [0.5, 1, 2, 3]
        return VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            HStack {
                LooprText("Amount", style: .rowTitle)
                Spacer()
                Text("\(FoodInput.text(value)) \(unit.title)").looprTypography(.metricValue).foregroundStyle(Color.loopr(.energy))
                    .contentTransition(.numericText(value: value)).animation(.snappy, value: value)
            }
            LooprRulerPicker("\(item.name) amount", value: Binding(get: { model.amounts[item.id] ?? item.amount },
                                                                     set: { model.setAmount($0, for: item.id) }),
                             in: fine ? 0...max(1_000, item.amount * 2) : 0...max(6, item.amount * 2),
                             step: fine ? 5 : 0.25, majorEvery: fine ? 10 : 4, unit: unit.title, accent: .energy)
                .frame(height: 74)
                .accessibilityIdentifier("food-lens-amount")
            HStack(spacing: LooprSpacing.xs) {
                ForEach(presets, id: \.self) { preset in
                    Button { withAnimation(.snappy) { model.setAmount(preset, for: item.id) } } label: {
                        Text("\(FoodInput.text(preset)) \(unit.title)").looprTypography(.label)
                            .foregroundStyle(value == preset ? LooprColorToken.energy.filledLabelColor : Color.loopr(.ink))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(Color.loopr(value == preset ? .energy : .surface), in: Capsule())
                    }
                    .buttonStyle(.looprPressableCard)
                    .accessibilityIdentifier("food-lens-preset-\(FoodInput.text(preset))")
                }
            }
        }
        .sensoryFeedback(.selection, trigger: value)
    }

    private func itemRow(_ item: FoodItem) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.3)) { expanded = expanded == item.id ? nil : item.id }
            } label: {
                HStack(spacing: LooprSpacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        LooprText(item.name, style: .rowTitle).lineLimit(2)
                        HStack(spacing: LooprSpacing.xs) {
                            LooprText("\(FoodInput.text(item.amount)) \(item.unit.title)", style: .caption, color: .inkSecondary)
                            if let confidence = item.confidence, confidence != .sure {
                                Text(confidence == .check ? "Check" : "Guess").looprTypography(.chip)
                                    .foregroundStyle(Color.loopr(confidence == .guess ? .critical : .energy))
                            }
                        }
                    }
                    Spacer(minLength: LooprSpacing.sm)
                    Text(item.nutrients[.energy].map { "\(FoodMacroBurstView.number($0)) kcal" } ?? "–")
                        .looprTypography(.metricValue).foregroundStyle(Color.loopr(.ink))
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.loopr(.inkMuted))
                        .rotationEffect(.degrees(expanded == item.id ? 180 : 0))
                }
                .frame(minHeight: LooprSpacing.interactiveRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableRow)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.name), \(FoodInput.text(item.amount)) \(item.unit.title), \(item.nutrients[.energy].map { "\(FoodMacroBurstView.number($0)) kilocalories" } ?? "calories unknown")")
            .accessibilityHint("Change the amount")
            .accessibilityIdentifier("food-lens-item-\(item.id)")
            if expanded == item.id, let base = model.items.first(where: { $0.id == item.id }) {
                amount(for: base).padding(.bottom, LooprSpacing.md).transition(.opacity)
            }
        }
    }

    @ViewBuilder private func problemContent(_ problem: FoodLensModel.Problem) -> some View {
        switch problem {
        case .consent(let name):
            LooprText("Send this photo to \(name)?", style: .cardTitle)
            LooprText("Loopr sends it with your API key, without its location or time. Nothing goes in your log until you add it.", style: .body, color: .inkSecondary)
            if let provider = CoachProvider.allCases.first(where: { $0.name == name }) {
                Link("\(name) privacy policy", destination: provider.privacyURL)
                    .looprTypography(.label).tint(Color.loopr(.energy)).accessibilityIdentifier("food-photo-privacy")
            }
        case .manual(let declined):
            LooprText("Add the foods yourself", style: .cardTitle)
            LooprText(declined ? "Nothing was sent. Add what's on the plate and Loopr keeps the photo with the meal."
                      : "Photo estimates use your own Claude or OpenAI key. Add one under Your data, or add what's on the plate.",
                      style: .body, color: .inkSecondary)
        case .failed(let title, let message):
            LooprText(title, style: .cardTitle)
            LooprText(message, style: .body, color: .inkSecondary).accessibilityIdentifier("food-lens-problem")
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: LooprSpacing.sm) {
            switch model.stage == .problem ? model.problem : nil {
            case .consent?:
                Button("Not now") { model.decline() }
                    .buttonStyle(LooprButtonStyle(prominent: false, accent: .energy)).accessibilityIdentifier("food-photo-consent-cancel")
                Button("Send photo") { Task { await model.allowAndEstimate() } }
                    .buttonStyle(LooprButtonStyle(accent: .energy)).accessibilityIdentifier("food-photo-consent-send")
            case .manual?:
                Button("Retake") { Task { await model.retake() } }
                    .buttonStyle(LooprButtonStyle(prominent: false, accent: .energy)).accessibilityIdentifier("food-lens-retake")
                Button("Add foods") { editing = true }
                    .buttonStyle(LooprButtonStyle(accent: .energy)).accessibilityIdentifier("food-lens-manual")
            case .failed?:
                Button("Try again") { Task { await model.retake() } }
                    .buttonStyle(LooprButtonStyle(prominent: false, accent: .energy)).accessibilityIdentifier("food-lens-retake")
                Button("Add it myself") { editing = true }
                    .buttonStyle(LooprButtonStyle(accent: .energy)).accessibilityIdentifier("food-lens-manual")
            case nil:
                Button("Edit") { editing = true }
                    .buttonStyle(LooprButtonStyle(prominent: false, accent: .energy)).frame(maxWidth: 120)
                    .accessibilityIdentifier("food-lens-edit")
                Button(saving ? "Adding" : "Add to \(model.draft.slot.rawValue)") { Task { await add() } }
                    .buttonStyle(LooprButtonStyle(accent: .energy)).disabled(saving || model.items.isEmpty)
                    .accessibilityIdentifier("food-lens-add")
            }
        }
    }

    private var slotMenu: some View {
        Menu {
            Picker("Meal", selection: $model.draft.slot) {
                ForEach(FoodMealSlot.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.draft.slot.title).looprTypography(.label)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color.loopr(.ink))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.loopr(.surface), in: Capsule())
        }
        .accessibilityLabel("Meal, \(model.draft.slot.title)")
        .accessibilityIdentifier("food-lens-slot")
    }

    // MARK: Chrome

    @ViewBuilder private func chrome(_ metrics: Metrics) -> some View {
        let top = metrics.insets.top + 14
        if model.stage != .burst {
            FoodLensGlassButton(symbol: "xmark", label: "Close", identifier: "food-capture-close") {
                Task { await model.stop() }; close()
            }
            .position(x: 36, y: top + 22)
        }
        if model.labActive {
            labHeader(metrics).position(x: metrics.size.width / 2, y: top + 22)
        } else if model.stage == .live {
            if model.lens == .lab {
                labHeader(metrics).position(x: metrics.size.width / 2, y: top + 22)
                // Most lab portals hand out a PDF; it is read on this iPhone like a photo.
                FoodLensGlassButton(symbol: "doc.text", label: "Choose a PDF of the report", identifier: "food-lab-pdf") {
                    choosingLabPDF = true
                }
                .position(x: metrics.size.width - 36, y: top + 22)
            } else {
                slotMenu.position(x: metrics.size.width / 2, y: top + 22)
                FoodLensGlassButton(symbol: "keyboard", label: "Type a barcode", identifier: "food-lens-type") { typing = true }
                    .position(x: metrics.size.width - 36, y: top + 22)
            }
            controls(metrics)
        } else if model.stage == .result {
            FoodLensGlassButton(symbol: "arrow.counterclockwise", label: "Retake", identifier: "food-lens-retake-top") {
                Task { await model.retake() }
            }
            .position(x: metrics.size.width - 36, y: top + 22)
        }
    }

    /// Lab mode says where the reading happens: on this iPhone, with nothing uploaded.
    private func labHeader(_ metrics: Metrics) -> some View {
        Text("Reading on this iPhone")
            .looprTypography(.label).foregroundStyle(.white)
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .frame(maxWidth: max(metrics.size.width - 150, 120))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("food-lab-header")
    }

    private func controls(_ metrics: Metrics) -> some View {
        let top = metrics.preview.maxY
        return VStack(spacing: LooprSpacing.lg) {
            FoodLensModePicker(selection: model.lens) { lens in Task { await model.switchLens(lens) } }
            HStack {
                PhotosPicker(selection: $library, matching: .images, preferredItemEncoding: .current) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(model.busy)
                .accessibilityLabel("Choose a photo")
                .accessibilityIdentifier("food-capture-library")
                Spacer()
                FoodLensShutter(label: model.lens == .food ? "Take food photo" : model.lens == .label ? "Read nutrition label" : "Read lab report") {
                    flashOnce()
                    Task { await model.shoot() }
                }
                .disabled(!model.cameraReady || model.busy)
                Spacer()
                FoodLensGlassButton(symbol: model.torch ? "flashlight.on.fill" : "flashlight.off.fill",
                                    label: model.torch ? "Turn off the light" : "Turn on the light", identifier: "food-lens-torch", size: 52) {
                    Task { await model.toggleTorch() }
                }
                .disabled(!model.cameraReady || model.fixturePhoto != nil)
            }
            .padding(.horizontal, 30)
        }
        .frame(width: metrics.size.width)
        .position(x: metrics.size.width / 2, y: top + Metrics.controls / 2 - 4)
    }

    private func flashOnce() {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.06)) { flash = true }
        withAnimation(.easeOut(duration: 0.35).delay(0.08)) { flash = false }
    }

    // MARK: Adding

    private var review: some View {
        FoodReviewView(draft: model.finalDraft(), repository: model.repository, runtime: model.runtime, now: model.now) { @MainActor @Sendable draft in
            model.adopt(draft)
            editing = false
            // Let the review screen slide away before the picture breaks up.
            try? await Task.sleep(for: .milliseconds(450))
            await add()
        }
    }

    private func add() async {
        guard !saving else { return }
        let draft = model.finalDraft()
        guard !draft.items.isEmpty else { return }
        saving = true; error = nil
        do {
            try await save(draft)
        } catch {
            saving = false; self.error = error.localizedDescription; haptic = .error
            return
        }
        guard let subject = model.card ?? model.subject else { done(); return }
        let rect = frame(Metrics(size: size, insets: Self.windowInsets))
        let added = FoodBurstNumbers(items: draft.items)
        model.stage = .burst
        burst = FoodBurstRequest(subject: subject, frame: rect, day: day, added: added)
        let total = day.eaten.energy + added.energy
        AccessibilityNotification.Announcement("\(draft.slot.title) added. \(FoodMacroBurstView.number(total)) kilocalories today.").post()
    }

    private func done() {
        Task { await model.stop() }
        finished(model.finalDraft())
    }
}

// MARK: Pieces

/// A round glass button for the camera's corners.
private struct FoodLensGlassButton: View {
    let symbol: String
    let label: String
    let identifier: String
    var size: CGFloat = 44
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1) }
        }
        .buttonStyle(.looprPressableCard)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// A white ring around a warm disc that sinks under the finger.
private struct FoodLensShutter: View {
    let label: String
    let action: () -> Void
    @State private var shots = 0
    var body: some View {
        Button { shots += 1; action() } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 80, height: 80)
                Circle().fill(LinearGradient(colors: [Color.loopr(.energy), Color.loopr(.strainSweep)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 64, height: 64)
            }
        }
        .buttonStyle(FoodLensShutterStyle())
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.9), trigger: shots)
        .accessibilityLabel(label)
        .accessibilityIdentifier("food-capture-shutter")
    }
}

private struct FoodLensShutterStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Food, Label or Lab, like the mode strip in the Camera app.
private struct FoodLensModePicker: View {
    let selection: FoodLensModel.Lens
    let choose: (FoodLensModel.Lens) -> Void
    @Namespace private var space
    var body: some View {
        HStack(spacing: 4) {
            ForEach(FoodLensModel.Lens.allCases, id: \.self) { lens in
                Button { withAnimation(.snappy(duration: 0.3)) { choose(lens) } } label: {
                    Text(lens.title).looprTypography(.label)
                        .foregroundStyle(selection == lens ? Color.loopr(.energy) : .white.opacity(0.75))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background {
                            if selection == lens {
                                Capsule().fill(.white.opacity(0.12)).matchedGeometryEffect(id: "lens", in: space)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == lens ? .isSelected : [])
                .accessibilityIdentifier("food-lens-mode-\(lens.rawValue)")
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
        // Three modes fit one line up to the first accessibility size, as in the Camera app.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

/// Corner marks around the centre of the frame. They breathe slowly so the camera feels awake.
private struct FoodLensFinder: View {
    let barcode: Bool
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { proxy in
            let length = min(proxy.size.width, proxy.size.height) * 0.16
            Path { path in
                let rect = CGRect(origin: .zero, size: proxy.size)
                for (corner, x, y) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                       (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
                    path.move(to: CGPoint(x: corner.x, y: corner.y + y * length))
                    path.addLine(to: corner)
                    path.addLine(to: CGPoint(x: corner.x + x * length, y: corner.y))
                }
            }
            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        }
        .scaleEffect(breathe ? 1.02 : 0.985)
        .opacity(breathe ? 0.95 : 0.7)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
        }
        .accessibilityHidden(true)
    }
}

/// A band of light that sweeps down the picture while it is read, drawn only on the picture itself.
private struct FoodLensScan: View {
    let subject: UIImage
    let barcode: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(paused: reduceMotion)) { context in
                let period = barcode ? 1.3 : 1.7
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                let band = max(proxy.size.height * 0.28, 40)
                ZStack(alignment: .top) {
                    Color.loopr(.energy).opacity(0.10 + 0.06 * sin(phase * 2 * .pi))
                    LinearGradient(colors: [.clear, Color.loopr(.energy).opacity(0.75), .white.opacity(0.9), Color.loopr(.energy).opacity(0.75), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: band)
                        .offset(y: -band + phase * (proxy.size.height + band))
                        .blendMode(.plusLighter)
                }
            }
        }
        .mask { Image(uiImage: subject).resizable().aspectRatio(contentMode: barcode ? .fill : .fit) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Status words with light running through them.
private struct FoodLensShimmer: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Text(text).looprTypography(.title).foregroundStyle(.white.opacity(0.55))
            .overlay {
                TimelineView(.animation(paused: reduceMotion)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.6)
                            .offset(x: -proxy.size.width * 0.6 + phase * proxy.size.width * 1.6)
                    }
                }
                .mask { Text(text).looprTypography(.title) }
            }
            .contentTransition(.opacity)
            .animation(.easeInOut, value: text)
    }
}

/// Where the meal's calories come from: one bar split by protein, carbs and fat, with grams under it.
private struct FoodLensMacroSplit: View {
    let totals: FoodBurstNumbers
    var body: some View {
        let parts: [(String, Double, Double, LooprColorToken)] = [
            ("Protein", totals.protein, totals.protein * 4, .heart),
            ("Carbs", totals.carbs, totals.carbs * 4, .brand),
            ("Fat", totals.fat, totals.fat * 9, .sleep),
        ]
        let sum = max(parts.map(\.2).reduce(0, +), 0.0001)
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            GeometryReader { proxy in
                HStack(spacing: 3) {
                    ForEach(parts, id: \.0) { part in
                        Capsule().fill(Color.loopr(part.3))
                            .frame(width: max((proxy.size.width - 6) * part.2 / sum, part.2 > 0 ? 6 : 0))
                    }
                }
            }
            .frame(height: 10)
            .animation(.snappy(duration: 0.35), value: totals)
            HStack(spacing: 0) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 6) {
                        Circle().fill(Color.loopr(part.3)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(FoodMacroBurstView.number(part.1)) g").looprTypography(.metricValue).foregroundStyle(Color.loopr(.ink))
                                .contentTransition(.numericText(value: part.1))
                            LooprText(part.0, style: .caption, color: .inkSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .animation(.snappy(duration: 0.3), value: totals)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("food-lens-macros")
    }
}
