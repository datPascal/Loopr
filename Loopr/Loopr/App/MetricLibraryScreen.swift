import DesignSystem
import SwiftUI
import UIKit

struct MetricLibraryScreen: View {
    @Environment(\.healthMetricPins) private var pins
    @Environment(\.metricHistoryProvider) private var provider
    @Environment(\.looprMetricLink) private var link
    @Environment(\.looprDaySelection) private var day
    @State private var query = ""
    @State private var model = HealthMetricsModel()
    @FocusState private var searchFocused: Bool
    @State private var keyboardVisible = false
    @State private var pendingMetric: MetricKey?
    var showsPinOrder = false
    private var anchor: MetricDetailAnchor {
        MetricDetailAnchor(selectedDay: day.map { LooprDays.looprDay($0.day) },
            today: day.map { LooprDays.looprDay($0.today) }, calendar: .current)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                LooprFormCard(padding: 0) {
                    LooprSearchField("Search \(MetricKey.allCases.count) metrics", text: $query,
                                     identifier: "metric-library-search", focus: $searchFocused)
                }
                if showsPinOrder, query.isEmpty { pinOrder }
                ForEach(HealthMetricGroup.allCases, id: \.self) { group in
                    let keys = group.matching(query)
                    if !keys.isEmpty {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprSectionHeader(group.rawValue)
                            LooprCard {
                                VStack(spacing: 0) {
                                    ForEach(Array(keys.enumerated()), id: \.element) { index, key in
                                        let reading = model.reading(key, on: anchor.day)
                                        // Skin temperature is a change from the band's baseline: "No change" or a signed
                                        // change, as Pinned shows it, never "0.0 °C" (Data ICP R1-DES-12, R1-NEW-16).
                                        let shown = HealthPinnedSection.valueText(key, reading: reading)
                                        LooprPinnableMetricRow(title: key == .steps ? "Steps" : key.presentation.title,
                                            value: shown.value, unit: shown.unit, detail: model.isLoading ? "Loading" : reading.value == nil || reading.comparison == "Estimated" ? reading.comparison : nil,
                                            pinned: pins?.contains(key) ?? false, identifier: "metric-library-\(key.rawValue)",
                                            open: { openMetric(key) }, toggle: { pins?.toggle(key) })
                                        if index < keys.count - 1 { LooprHairline() }
                                    }
                                }
                            }
                        }
                    }
                }
                if HealthMetricGroup.allCases.allSatisfy({ $0.matching(query).isEmpty }) {
                    LooprCard { LooprText("No metrics match your search.", style: .prose, color: .inkSecondary) }
                }
                LooprText("Unpinned metrics keep recording. They stay in your exports and in the data you can share with the agent.", style: .prose, color: .inkSecondary)
                    .accessibilityIdentifier("metric-library-recording-note")
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.sm)
            .padding(.bottom, LooprSpacing.tabBarClearance)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("All metrics")
        .toolbarTitleDisplayMode(.inline)
        .looprAskToolbar(origin: "All metrics")
        .accessibilityIdentifier("metric-library-screen")
        .task(id: anchor.day) { await model.load(keys: MetricKey.allCases, provider: provider, anchor: anchor) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            guard notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool != false else { return }
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { notification in
            guard notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool != false else { return }
            keyboardVisible = false
            if let key = pendingMetric {
                pendingMetric = nil
                link?.open(key.rawValue)
            }
        }
        .onDisappear { pendingMetric = nil }
    }

    private func openMetric(_ key: MetricKey) {
        guard pendingMetric == nil else { return }
        // Finish the keyboard's layout transition before pushing another scroll view.
        if keyboardVisible {
            pendingMetric = key
            searchFocused = false
        } else {
            searchFocused = false
            link?.open(key.rawValue)
        }
    }

    @ViewBuilder private var pinOrder: some View {
        if let pins, !pins.metrics.isEmpty {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Pinned order", detail: "The same order on Data and Today")
                LooprCard {
                    VStack(spacing: 0) {
                        ForEach(Array(pins.metrics.enumerated()), id: \.element) { index, key in
                            HStack {
                                LooprText(key.presentation.title, style: .rowTitle)
                                Spacer()
                                Menu {
                                    Button("Move up") { pins.move(key, by: -1) }.disabled(index == 0).accessibilityIdentifier("pin-order-\(key.rawValue)-up")
                                    Button("Move down") { pins.move(key, by: 1) }.disabled(index == pins.metrics.count - 1).accessibilityIdentifier("pin-order-\(key.rawValue)-down")
                                    Button("Unpin") { pins.toggle(key) }.accessibilityIdentifier("pin-order-\(key.rawValue)-remove")
                                } label: {
                                    Image(systemName: "arrow.up.arrow.down")
                                        .frame(minWidth: LooprSpacing.interactiveRowHeight, minHeight: LooprSpacing.interactiveRowHeight)
                                }
                                .accessibilityLabel("Reorder \(key.presentation.title)")
                                .accessibilityIdentifier("pin-order-\(key.rawValue)")
                            }
                            if index < pins.metrics.count - 1 { LooprHairline() }
                        }
                    }
                }
            }
        }
    }
}
