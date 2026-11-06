import AnalyticsKit
import DesignSystem
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Puts the keyboard away. The decimal pad has no return key.
@MainActor
func labsDismissKeyboard() {
    #if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #endif
}

/// The fields of one typed value: the number as the lab printed it, the unit, and the lab's own range and flag. The
/// range and flag stay optional and collapsed until the person opens them.
struct LabValueFields: View {
    @Binding var draft: LabValueDraft
    /// `labs-entry-value-0`, `labs-value-edit`: each control adds its own suffix.
    let idPrefix: String
    var remove: (() -> Void)?
    /// Called with the last range field's scroll id when the range opens, so the form can scroll it above the save bar.
    var revealRange: ((String) -> Void)?
    @State private var showsRange: Bool

    private static let noUnit = "No unit printed"

    /// The scroll id of the last field in the range section.
    static func rangeEndAnchor(_ idPrefix: String) -> String { idPrefix + "-range-end" }

    init(draft: Binding<LabValueDraft>, idPrefix: String, remove: (() -> Void)? = nil, revealRange: ((String) -> Void)? = nil) {
        _draft = draft
        self.idPrefix = idPrefix
        self.remove = remove
        self.revealRange = revealRange
        let value = draft.wrappedValue
        _showsRange = State(initialValue: !(value.rangeLowText.isEmpty && value.rangeHighText.isEmpty
            && value.rangeText.isEmpty && value.flagText.isEmpty))
    }

    var body: some View {
        LooprFormCard(padding: 0) {
            VStack(spacing: 0) {
                header
                LooprHairline()
                LooprTextFieldRow(title: "Value", placeholder: "As printed", text: $draft.numberText)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier(idPrefix + "-number")
                LooprHairline()
                // The decimal pad has no "<" or ">", so a result printed as a limit gets its sign here. "Printed as,
                // A number" did not say what else a result could be (ICP R2-LAB-3).
                LooprPickerRow(title: "Result type", selection: Binding(get: { LabComparatorChoice(draft.comparator) },
                                                                       set: { draft.comparator = $0.comparator }),
                               options: LabComparatorChoice.allCases, label: \.title)
                    .accessibilityIdentifier(idPrefix + "-sign")
                LooprHairline()
                unitRow
                LooprHairline()
                DisclosureGroup(isExpanded: $showsRange) {
                    VStack(spacing: 0) {
                        LooprTextFieldRow(title: "Range low", placeholder: "Optional", text: $draft.rangeLowText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier(idPrefix + "-range-low")
                        LooprHairline()
                        LooprTextFieldRow(title: "Range high", placeholder: "Optional", text: $draft.rangeHighText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier(idPrefix + "-range-high")
                        LooprHairline()
                        LooprTextFieldRow(title: "Range text", placeholder: "For example <5.0", text: $draft.rangeText)
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier(idPrefix + "-range-text")
                        LooprHairline()
                        LooprTextFieldRow(title: "Flag", placeholder: "As printed", text: $draft.flagText)
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier(idPrefix + "-flag")
                            .id(Self.rangeEndAnchor(idPrefix))
                    }
                    .padding(.horizontal, -LooprSpacing.formCardPadding)
                } label: {
                    LooprText("The lab's range and flag", style: .settingsRow)
                }
                .padding(.horizontal, LooprSpacing.formCardPadding)
                .frame(minHeight: LooprSpacing.interactiveRowHeight)
                .accessibilityIdentifier(idPrefix + "-range-toggle")
            }
        }
        // The opened fields sat under the save bar, so a tap meant for Range low saved the report (ICP R3-LAB-11).
        .onChange(of: showsRange) { _, open in
            if open { revealRange?(Self.rangeEndAnchor(idPrefix)) }
        }
    }

    private var header: some View {
        HStack(spacing: LooprSpacing.sm) {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(draft.name, style: .rowTitle)
                if let key = draft.subject.markerKey {
                    LooprText(key.marker.bodySystem.displayName, style: .caption, color: .inkSecondary)
                } else {
                    LooprText("Another test", style: .caption, color: .inkSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: LooprSpacing.sm)
            if let remove {
                Button("Remove", action: remove)
                    .buttonStyle(LooprButtonStyle(prominent: false, quiet: true))
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Remove \(draft.name)")
                    .accessibilityIdentifier(idPrefix + "-remove")
            }
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .frame(minHeight: LooprSpacing.interactiveRowHeight)
    }

    @ViewBuilder
    private var unitRow: some View {
        if let key = draft.subject.markerKey {
            // A stored unit the catalog does not list stays on offer, so editing never changes it by accident.
            let kept = draft.unit.flatMap { key.marker.units.contains($0) ? nil : $0 }
            LooprPickerRow(
                title: "Unit",
                selection: Binding(get: { draft.unit ?? Self.noUnit }, set: { draft.unit = $0 == Self.noUnit ? nil : $0 }),
                options: (kept.map { [$0] } ?? []) + key.marker.units + [Self.noUnit],
                label: { $0 })
                .accessibilityIdentifier(idPrefix + "-unit")
        } else {
            LooprTextFieldRow(title: "Unit", placeholder: "None printed",
                              text: Binding(get: { draft.unit ?? "" }, set: { draft.unit = $0.isEmpty ? nil : $0 }))
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier(idPrefix + "-unit")
        }
    }
}

/// How the lab printed a result: an exact number, or a limit with its sign. The typed entry and the scan's edit row
/// offer these, because the decimal pad has no "<" or ">".
enum LabComparatorChoice: String, CaseIterable, Hashable, Sendable {
    case exact, below, atMost, above, atLeast

    init(_ comparator: LabValueComparator?) {
        switch comparator {
        case nil: self = .exact
        case .lessThan?: self = .below
        case .lessThanOrEqual?: self = .atMost
        case .greaterThan?: self = .above
        case .greaterThanOrEqual?: self = .atLeast
        }
    }

    var comparator: LabValueComparator? {
        switch self {
        case .exact: nil
        case .below: .lessThan
        case .atMost: .lessThanOrEqual
        case .above: .greaterThan
        case .atLeast: .greaterThanOrEqual
        }
    }

    var title: String {
        switch self {
        case .exact: "A number"
        case .below: "Below a limit, <"
        case .atMost: "At or below a limit, ≤"
        case .above: "Above a limit, >"
        case .atLeast: "At or above a limit, ≥"
        }
    }
}

/// The marker search the typed entry opens: the catalog by English or German name, and any other test by its name.
struct LabMarkerPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let alreadyAdded: Set<LabMarkerKey>
    let choose: (LabValueSubject) -> Void

    private var results: [LabMarker] { LabMarkerSearch.results(for: query) }
    private var typedName: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var offersOther: Bool {
        guard !typedName.isEmpty else { return false }
        let folded = LabMarkerSearch.fold(typedName)
        return !LabMarkerCatalog.markers.contains { LabMarkerSearch.names(of: $0).contains(folded) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprFormCard(padding: 0) {
                        LooprSearchField("Search markers, English or German", text: $query,
                                         identifier: "labs-entry-marker-search")
                    }
                    if offersOther {
                        Button { choose(.other(name: typedName)); dismiss() } label: {
                            HStack(spacing: LooprSpacing.sm) {
                                LooprText("Add \(typedName) as another test", style: .settingsRow)
                                Spacer(minLength: LooprSpacing.sm)
                                Image(systemName: "plus").foregroundStyle(Color.loopr(.brand)).accessibilityHidden(true)
                            }
                            .padding(.horizontal, LooprSpacing.formCardPadding)
                            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                            .looprCardBackground()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.looprPressableRow)
                        .accessibilityIdentifier("labs-entry-other")
                    }
                    if results.isEmpty, !offersOther {
                        LooprText("No marker matches that name.", style: .prose, color: .inkSecondary)
                    } else if !results.isEmpty {
                        LooprFormCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(results.enumerated()), id: \.element.key) { index, marker in
                                    row(marker)
                                    if index < results.count - 1 { LooprHairline() }
                                }
                            }
                        }
                    }
                    if typedName.isEmpty {
                        LooprText("A test that is not listed? Type its name above and add it as another test.",
                                  style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.vertical, LooprSpacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle("Add a value")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("labs-entry-marker-cancel")
                }
            }
        }
        .accessibilityIdentifier("labs-marker-search-screen")
    }

    private func row(_ marker: LabMarker) -> some View {
        let added = alreadyAdded.contains(marker.key)
        return Button {
            choose(.marker(marker.key)); dismiss()
        } label: {
            HStack(spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(marker.displayName, style: .settingsRow)
                    LooprText(marker.bodySystem.displayName, style: .caption, color: .inkSecondary)
                }
                Spacer(minLength: LooprSpacing.sm)
                if added { LooprText("Added", style: .caption, color: .inkSecondary) }
            }
            .padding(.horizontal, LooprSpacing.formCardPadding)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .disabled(added)
        .accessibilityLabel(added ? "\(marker.displayName), already in this report" : marker.displayName)
        .accessibilityIdentifier("labs-entry-marker-\(marker.key.rawValue)")
    }
}
