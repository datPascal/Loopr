import DesignSystem
import DomainKit
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import TodayKit

/// ICP R3-PAS-1: Today never shows the recovery ring layout of earlier builds. The dial leads, and until it has loaded
/// its placeholder stands in its place at its size.
@MainActor struct TodayDialPlaceholderTests {
    @Test func todayLeadsWithTheDialOrItsPlaceholderAndNothingElse() {
        #expect(TodayLead.allCases == [.dial, .placeholder], "no ring hero choice is left")
        #expect(TodayLead(dial: nil) == .placeholder)
        #expect(TodayLead(dial: TodayDialContent(inputs: DialFixture.inputs())) == .dial)
    }

    @Test func thePlaceholderTakesTheDialsSquare() {
        let width: CGFloat = 393
        let host = UIHostingController(rootView: TodayDialPlaceholder().frame(width: width))
        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        // The dial is at most 353 points across; the notes line and the readout row sit under it.
        #expect(size.height >= TodayDialStack.maximumSide)
        #expect(size.height < TodayDialStack.maximumSide + 200)
    }

    @Test func todayStillBuildsWithoutADial() {
        let viewModel = TodayViewModel(repository: InMemoryTodayRepository(values: [TodayFixtures.day: TodayFixtures.populated]))
        let host = UIHostingController(rootView: TodayScreen(viewModel: viewModel, dial: nil))
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        host.view.layoutIfNeeded()
        #expect(host.view.bounds.width == 393)
    }
}
