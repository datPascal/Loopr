import AnalyticsKit
import DesignSystem
import SwiftUI

/// The words an unexpected save failure shows. A refused draft shows its own `LabEntryError` message instead.
enum LabsEntryCopy {
    static let saveFailed = "Loopr could not save this on this iPhone. Try again."

    static func message(for error: Error) -> String {
        (error as? LabEntryError)?.message ?? saveFailed
    }
}

/// A pinned save button, as every focus screen has.
private struct LabsSaveBar: View {
    let title: String
    let identifier: String
    let error: String?
    let errorIdentifier: String
    let saving: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: LooprSpacing.xs) {
            if let error {
                LooprInlineMessage(error, tone: .critical)
                    .accessibilityIdentifier(errorIdentifier)
            }
            Button(saving ? "Saving" : title, action: action)
                .buttonStyle(LooprButtonStyle())
                .disabled(saving)
                .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .padding(.top, LooprSpacing.sm)
        .padding(.bottom, LooprSpacing.xs)
        // Solid down to the screen's edge, with a line on top: the form scrolled through a see-through bar and
        // an error drew over the row behind it (ICP R2-LAB-1, R2-LAB-2).
        .background {
            Color.loopr(.background)
                .overlay(alignment: .top) { LooprHairline() }
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// Typed entry of a lab report (`labs-entry-screen`). The person picks the day, names the lab, says whether they
/// fasted, and adds values by searching the marker catalog or typing another test's name. Saving builds the report
/// through the model with source typed.
public struct LabEntryScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LabTypedReportDraft
    @State private var picking = false
    @State private var error: String?
    @State private var saving = false
    @State private var haptic: LooprHaptic?
    private let now: Date
    private let save: @MainActor (LabReport, [LabValue]) async throws -> Void

    public init(now: Date, timeZoneIdentifier: String = TimeZone.current.identifier,
                save: @escaping @MainActor (LabReport, [LabValue]) async throws -> Void) {
        self.now = now
        self.save = save
        _draft = State(initialValue: LabTypedReportDraft(collectedOn: now, timeZoneIdentifier: timeZoneIdentifier))
    }

    public var body: some View {
        ZStack {
            LooprColorField(accent: .brand)
            form
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Type in a report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .looprHaptic(haptic)
        .sheet(isPresented: $picking) {
            LabMarkerPicker(alreadyAdded: Set(draft.values.compactMap(\.subject.markerKey))) { subject in
                withAnimation(LooprMotion.stateChange) { draft.values.append(LabValueDraft(subject: subject)) }
                error = nil
            }
            .presentationDetents([.large])
        }
    }

    /// A refusal about one value shows under that value; any other shows on the save bar.
    @State private var valueError: LabEntryError?

    private var form: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LabsEyebrow(text: "From the paper or PDF")
                    LooprText("Type in what the lab printed. Loopr keeps the lab's own ranges and flags and never judges a value.",
                              style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                reportCard
                if !draft.values.isEmpty {
                    LooprSectionHeader("Values", detail: LabsDisplay.valueCount(draft.values.count), identifier: "labs-entry-values-header")
                        .padding(.top, LooprSpacing.xs)
                }
                ForEach(Array(draft.values.enumerated()), id: \.element.id) { index, value in
                    LabValueFields(
                        draft: Binding(get: { draft.values.indices.contains(index) ? draft.values[index] : value },
                                       set: { if draft.values.indices.contains(index) { draft.values[index] = $0 } }),
                        idPrefix: "labs-entry-value-\(index)",
                        remove: { withAnimation(LooprMotion.stateChange) { draft.values.removeAll { $0.id == value.id } } },
                        revealRange: { anchor in
                            Task { @MainActor in
                                // After the disclosure has laid its fields out.
                                try? await Task.sleep(for: .milliseconds(250))
                                withAnimation(LooprMotion.stateChange) { proxy.scrollTo(anchor, anchor: .bottom) }
                            }
                        })
                        .id(value.id)
                    if let valueError, valueError.valueName == value.name {
                        LooprInlineMessage(valueError.message, tone: .critical)
                            .id(Self.valueErrorAnchor)
                            .accessibilityIdentifier("labs-entry-error")
                    }
                }
                Button { labsDismissKeyboard(); picking = true } label: {
                    Label(draft.values.isEmpty ? "Add a value" : "Add another value", systemImage: "plus")
                }
                .buttonStyle(LooprButtonStyle(prominent: false))
                .accessibilityIdentifier("labs-entry-add-value")
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.md)
            .padding(.bottom, LooprSpacing.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        // The screen identifier sits on the scroll view only. On the whole screen it replaced the save button's own.
        .accessibilityIdentifier("labs-entry-screen")
        .safeAreaInset(edge: .bottom) {
            LabsSaveBar(title: "Save report", identifier: "labs-entry-save", error: valueError == nil ? error : nil,
                        errorIdentifier: "labs-entry-error", saving: saving, action: submit)
        }
        .onChange(of: valueError) { _, refused in
            guard refused?.valueName != nil else { return }
            withAnimation(LooprMotion.stateChange) { proxy.scrollTo(Self.valueErrorAnchor, anchor: .center) }
        }
        // An edit answers the refusal, so it goes until the next save.
        .onChange(of: draft.values) { _, _ in if valueError != nil { valueError = nil; error = nil } }
        }
    }

    private static let valueErrorAnchor = "labs-entry-value-error"

    /// The draw itself leads the form, lit in Data's accent.
    private var reportCard: some View {
        LooprCard(style: .hero(.brand), density: .flush) {
            VStack(spacing: 0) {
                // The picker shows the day in the report's zone, the zone the save reads it in (ICP R2-LAB-5).
                DatePicker("Date of the blood draw", selection: $draft.collectedOn,
                           in: ...LabEntryDates.latestPickable(now: now, timeZone: draft.timeZone), displayedComponents: .date)
                    .environment(\.timeZone, draft.timeZone)
                    .looprTypography(.settingsRow)
                    .padding(.horizontal, LooprSpacing.formCardPadding)
                    .frame(minHeight: LooprSpacing.interactiveRowHeight)
                    .accessibilityIdentifier("labs-entry-date")
                LooprHairline()
                LooprTextFieldRow(title: "Lab", placeholder: "Name on the report", text: $draft.labName)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("labs-entry-lab")
                LooprHairline()
                LooprPickerRow(title: "Fasting", selection: $draft.fasting, options: LabTypedReportDraft.Fasting.allCases,
                               label: \.title)
                    .accessibilityIdentifier("labs-entry-fasting")
            }
        }
    }

    private func submit() {
        labsDismissKeyboard()
        let built: (report: LabReport, values: [LabValue])
        do { built = try draft.build(now: now) } catch {
            haptic = .error
            self.error = LabsEntryCopy.message(for: error)
            valueError = (error as? LabEntryError).flatMap { $0.valueName == nil ? nil : $0 }
            return
        }
        saving = true
        error = nil
        valueError = nil
        Task {
            defer { saving = false }
            do {
                try await save(built.report, built.values)
                haptic = .success
                AccessibilityNotification.Announcement("Report saved with \(LabsDisplay.valueCount(built.values.count)).").post()
                dismiss()
            } catch {
                haptic = .error
                self.error = LabsEntryCopy.message(for: error)
            }
        }
    }
}

/// Typed entry of a lab clock result (`labs-clock-entry-screen`). The lab's number is stored as printed, with the
/// lab's name. Loopr never works a clock out.
public struct LabClockEntryScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LabClockDraft
    @State private var error: String?
    @State private var saving = false
    @State private var haptic: LooprHaptic?
    private let now: Date
    private let save: @MainActor (LabClockResult) async throws -> Void

    public init(now: Date, timeZoneIdentifier: String = TimeZone.current.identifier,
                save: @escaping @MainActor (LabClockResult) async throws -> Void) {
        self.now = now
        self.save = save
        _draft = State(initialValue: LabClockDraft(collectedOn: now, timeZoneIdentifier: timeZoneIdentifier))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                LooprText("Type in the number your lab reported. Loopr stores it with the lab's name and does not calculate a clock.",
                          style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                LooprFormCard(padding: 0) {
                    VStack(spacing: 0) {
                        LooprPickerRow(title: "Clock", selection: $draft.choice, options: LabClockDraft.Choice.allCases,
                                       label: \.title)
                            .accessibilityIdentifier("labs-clock-kind")
                        if draft.choice == .other {
                            LooprHairline()
                            LooprTextFieldRow(title: "Name", placeholder: "Name of the clock", text: $draft.otherName)
                                .textInputAutocapitalization(.words)
                                .accessibilityIdentifier("labs-clock-name")
                        }
                        LooprHairline()
                        LooprTextFieldRow(title: "Value", placeholder: "As printed", text: $draft.valueText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("labs-clock-value")
                        LooprHairline()
                        LooprTextFieldRow(title: "Unit", placeholder: draft.choice == .grimAge ? "Years" : "None printed",
                                          text: $draft.unit)
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("labs-clock-unit")
                        LooprHairline()
                        LooprTextFieldRow(title: "Lab", placeholder: "Required", text: $draft.labName)
                            .textInputAutocapitalization(.words)
                            .accessibilityIdentifier("labs-clock-lab")
                        LooprHairline()
                        DatePicker("Day", selection: $draft.collectedOn,
                                   in: ...LabEntryDates.latestPickable(now: now, timeZone: draft.timeZone), displayedComponents: .date)
                            .environment(\.timeZone, draft.timeZone)
                            .looprTypography(.settingsRow)
                            .padding(.horizontal, LooprSpacing.formCardPadding)
                            .frame(minHeight: LooprSpacing.interactiveRowHeight)
                            .accessibilityIdentifier("labs-clock-date")
                        LooprHairline()
                        LooprTextFieldRow(title: "Note", placeholder: "Optional", text: $draft.note)
                            .accessibilityIdentifier("labs-clock-note")
                    }
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.md)
            .padding(.bottom, LooprSpacing.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        // The screen identifier sits on the scroll view only. On the whole screen it replaced the save button's own.
        .accessibilityIdentifier("labs-clock-entry-screen")
        .safeAreaInset(edge: .bottom) {
            LabsSaveBar(title: "Save lab clock result", identifier: "labs-clock-entry-save", error: error,
                        errorIdentifier: "labs-clock-entry-error", saving: saving, action: submit)
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Add a lab clock result")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .looprHaptic(haptic)
    }

    private func submit() {
        labsDismissKeyboard()
        let built: LabClockResult
        do { built = try draft.build(now: now) } catch {
            haptic = .error
            self.error = LabsEntryCopy.message(for: error)
            return
        }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await save(built)
                haptic = .success
                dismiss()
            } catch {
                haptic = .error
                self.error = LabsEntryCopy.message(for: error)
            }
        }
    }
}
