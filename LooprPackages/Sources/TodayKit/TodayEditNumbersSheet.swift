import SwiftUI
import DesignSystem

/// Pick and order the numbers pinned to Today. Up to six; the order here is
/// the order of the tiles.
struct TodayEditNumbersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pinned: [TodayTrackedMetric]
    private let onSave: ([TodayTrackedMetric]) -> Void

    init(pinned: [TodayTrackedMetric], onSave: @escaping ([TodayTrackedMetric]) -> Void) {
        _pinned = State(initialValue: pinned)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(pinned) { metric in
                        row(metric, isPinned: true)
                    }
                    .onMove { pinned.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in
                        withAnimation(.snappy(duration: LooprMotion.fast)) { pinned.remove(atOffsets: offsets) }
                    }
                } header: {
                    eyebrow("On Today · \(pinned.count) of \(TodayPreferences.maximumPinned)")
                        .contentTransition(.numericText())
                } footer: {
                    Text(pinned.isEmpty
                         ? "Nothing pinned. Add a number below."
                         : "Drag to reorder. The first two sit side by side at the top.")
                }

                Section {
                    ForEach(available) { metric in
                        row(metric, isPinned: false)
                    }
                } header: {
                    eyebrow("More numbers")
                } footer: {
                    if isFull {
                        Text("Six is the most Today holds. Remove one to add another.")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(Color.loopr(.settingsBackground).ignoresSafeArea())
            .navigationTitle("Your numbers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("today-numbers-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(pinned)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("today-numbers-done")
                }
            }
        }
        .accessibilityIdentifier("today-numbers-sheet")
        // Adding, removing and reordering a number each tick once.
        .sensoryFeedback(.selection, trigger: pinned)
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .looprTypography(.sectionLabel)
            .foregroundStyle(Color.loopr(.inkSecondary))
    }

    private var available: [TodayTrackedMetric] {
        TodayTrackedMetric.pinnable.filter { !pinned.contains($0) }
    }

    private var isFull: Bool { pinned.count >= TodayPreferences.maximumPinned }

    @ViewBuilder
    private func row(_ metric: TodayTrackedMetric, isPinned: Bool) -> some View {
        HStack(spacing: LooprSpacing.sm) {
            if !isPinned {
                Button {
                    guard !isFull else { return }
                    withAnimation(.snappy(duration: LooprMotion.fast)) { pinned.append(metric) }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isFull ? Color.loopr(.inkMuted) : Color.green)
                }
                .buttonStyle(.plain)
                .disabled(isFull)
                .accessibilityLabel("Add \(metric.title)")
            }
            Circle()
                .fill(Color.loopr(metric.accent))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(metric.title)
                    .looprTypography(.settingsRow)
                    .foregroundStyle(Color.loopr(.ink))
                if metric.isEstimate {
                    Text("Estimate")
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                }
            }
        }
        .accessibilityIdentifier("today-numbers-\(isPinned ? "pinned" : "add")-\(metric.rawValue)")
    }
}
