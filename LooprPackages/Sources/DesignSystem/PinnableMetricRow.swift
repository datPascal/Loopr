import SwiftUI

/// Separate targets for reading a measurement and changing its pin.
public struct LooprPinnableMetricRow: View {
    private let title: String
    private let value: String?
    private let unit: String?
    private let detail: String?
    private let pinned: Bool
    private let identifier: String
    private let open: () -> Void
    private let toggle: () -> Void

    public init(title: String, value: String?, unit: String? = nil, detail: String? = nil,
                pinned: Bool, identifier: String, open: @escaping () -> Void, toggle: @escaping () -> Void) {
        self.title = title; self.value = value; self.unit = unit; self.detail = detail
        self.pinned = pinned; self.identifier = identifier; self.open = open; self.toggle = toggle
    }

    public var body: some View {
        HStack(spacing: LooprSpacing.xxs) {
            Button(action: open) {
                HairlineMetricRow(title: title, confidence: detail, value: value ?? "No reading", unit: value == nil ? nil : unit, showsDisclosure: false)
            }
            .buttonStyle(.looprPressableRow)
            .accessibilityIdentifier(identifier)
            .accessibilityHint("Opens measurement history")
            Button(action: toggle) {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .looprTypography(.rowTitle)
                    .foregroundStyle(Color.loopr(pinned ? .brand : .inkMuted))
                    .frame(minWidth: LooprSpacing.interactiveRowHeight, minHeight: LooprSpacing.interactiveRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel((pinned ? "Unpin " : "Pin ") + title)
            .accessibilityValue(pinned ? "Pinned" : "Not pinned")
            .accessibilityIdentifier(identifier + "-pin")
        }
    }
}

#Preview {
    LooprCard {
        LooprPinnableMetricRow(title: "HRV", value: "61", unit: "ms", pinned: true,
            identifier: "pin-preview", open: {}, toggle: {})
    }
}
