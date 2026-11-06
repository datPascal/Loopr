import SwiftUI

/// Image-level labels in three presentation slots. Slots do not represent object bounds.
public struct LooprCaptureAnnotations: View {
    @Environment(\.dynamicTypeSize) private var size
    private let labels: [String]
    private let guide: String
    public init(labels: [String], guide: String) { self.labels = Array(labels.prefix(3)); self.guide = guide }
    public var body: some View {
        ZStack(alignment: .bottom) {
            if size.isAccessibilitySize {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    ForEach(labels, id: \.self) { chip($0) }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(LooprSpacing.lg)
            } else {
                GeometryReader { geometry in
                    ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                        let anchor = position(index)
                        chip(label).position(x: geometry.size.width * anchor.x, y: geometry.size.height * anchor.y)
                    }
                }
            }
            LooprText(guide, style: .body)
                .padding(LooprSpacing.sm)
                .padding(.bottom, LooprSpacing.lg)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }
    private func chip(_ label: String) -> some View {
        StatusChip(label, symbol: nil, accent: .brand)
            .background(Color.loopr(.background).opacity(0.75), in: Capsule())
    }
    private func position(_ index: Int) -> CGPoint {
        switch index {
        case 0: .init(x: 0.44, y: 0.27)
        case 1: .init(x: 0.64, y: 0.54)
        default: .init(x: 0.24, y: 0.61)
        }
    }
}

#Preview {
    Color.loopr(.surfaceSunk).overlay {
        LooprCaptureAnnotations(labels: ["Chicken", "Rice", "Avocado"], guide: "Fit the whole plate in the frame")
    }.frame(height: LooprSpacing.capturePreviewHeight)
}
