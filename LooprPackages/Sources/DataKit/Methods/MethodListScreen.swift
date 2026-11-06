import DesignSystem
import SwiftUI

/// "How the numbers work": every method page, grouped. Data's root links here; each row opens one page.
public struct MethodListScreen: View {
    private let open: (MethodID) -> Void

    public init(open: @escaping (MethodID) -> Void) {
        self.open = open
    }

    public var body: some View {
        ZStack {
            LooprColorField(accent: .brand)
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
                    LooprText("Each page shows the inputs, the paper or rule, the source file and its version, the tests and the limits.",
                              style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(MethodGroup.allCases, id: \.self) { group in
                        let entries = MethodCatalog.entries(in: group)
                        if !entries.isEmpty {
                            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                                LooprSectionHeader(group.title)
                                LooprCard(density: .flush) {
                                    VStack(alignment: .leading, spacing: LooprSpacing.none) {
                                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                            LooprNavigationRow(title: entry.title, caption: entry.listLine,
                                                               accessibilityLabel: "\(entry.title) method",
                                                               identifier: "methods-list-\(entry.id.rawValue)",
                                                               showsDivider: index < entries.count - 1) { open(entry.id) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.md)
                .padding(.bottom, LooprSpacing.tabBarClearance)
            }
            .accessibilityIdentifier("methods-list")
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("How the numbers work")
        .navigationBarTitleDisplayMode(.inline)
    }
}
