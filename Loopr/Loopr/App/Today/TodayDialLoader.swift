import BodyKit
import DomainKit
import FoodKit
import HealthKitBridge
import Foundation
import SwiftUI
import TodayKit
import UIKit

/// Reads the dial's inputs for Today and cuts the day's meal photos into stickers.
@MainActor
struct TodayDialLoader {
    let environment: AppEnvironment
    let repositories: ProductRepositoryContainer?
    let history: any MetricHistoryProviding
    var bandName = ""
    var arguments = ProcessInfo.processInfo.arguments

    /// Sticker images are cut at this many pixels across.
    static let stickerPixels: CGFloat = 96
    /// The meal card's header photo is read at this many pixels on its longest side.
    static let photoPixels: CGFloat = 900

    /// The dial's clock: fixtures pin it on the fixture day; production reads the real clock in the app's zone.
    func clock(for day: DayIdentity) -> (now: Date, calendar: Calendar, isPinned: Bool) {
        var calendar = Calendar(identifier: .gregorian)
        if repositories?.isFixtureComposition != false {
            // The launch's one fixture clock, the one Protocol, Food and Fitness read too (ICP R3-OPT-1, R3-OPT-5).
            let clock = TodayDialFixtureClock.clock(environment: environment, arguments: arguments)
            return (clock.now, clock.calendar, true)
        }
        calendar.timeZone = environment.timeZoneProvider.timeZone
        return (environment.dateProvider.now(), calendar, false)
    }

    /// - Parameter protocolDay: the protocol day Today's rail already evaluated. The dial then draws the same rules and
    ///   checks without a second evaluation.
    func load(day: DayIdentity, protocolDay: TodayDialProtocolDay? = nil) async -> TodayDialContent? {
        let clock = clock(for: day)
        var sources = TodayDialSources.live(environment: environment, repositories: repositories, history: history, bandName: bandName)
        if let protocolDay { sources.readProtocol = { _, _, _ in protocolDay } }
        #if DEBUG
        // The populated fixture has no Apple Health store; its daylight and steps come from the Today fixture.
        if sources.readAppleHealth == nil, repositories?.isFixtureComposition != false, environment.composition == .populated {
            let fixtureDay = environment.productDay(fixture: TodayFixtures.day)
            let calendar = clock.calendar
            sources.readAppleHealth = { kind, start, _ in
                TodayFixtureAppleHealth.read(kind, dayStart: start, fixtureDay: fixtureDay, calendar: calendar)
            }
        }
        // The dial's Zone 2 readout reads the same 48 minutes the rail's Zone 2 rule kept, not "not measured" beside
        // "48 min in zone 2" (R1-OPT-17). The empty fixture day has none.
        if repositories?.isFixtureComposition != false, environment.composition == .populated {
            let fixtureDay = environment.productDay(fixture: TodayFixtures.day)
            let now = clock.now, timeZone = clock.calendar.timeZone
            sources.readZoneMinutes = { day in
                TodayNoteRailFixture.zoneMinutes(on: day, fixtureDay: fixtureDay, now: now, timeZone: timeZone)
            }
        }
        #endif
        guard var inputs = await sources.inputs(day: day, now: clock.now, calendar: clock.calendar, recovery: nil) else { return nil }
        #if DEBUG
        if TodayLearningFixture.isRequested(arguments: arguments) { TodayLearningFixture.limit(&inputs, bandName: bandName) }
        #endif
        let art = await mealArt(for: inputs)
        return TodayDialContent(inputs: inputs, isClockPinned: clock.isPinned, stickers: art.stickers, photos: art.photos)
    }

    private var foodRepository: AppFoodRepository? {
        if let persistent = repositories?.persistent { return AppFoodRepository(store: persistent.food, environment: environment) }
        #if DEBUG
        return repositories?.fixtureFoodRepository
        #else
        return nil
        #endif
    }

    /// Each meal's first photo, cut round for its sticker, and uncut for the card a tapped sticker opens. A photo that
    /// cannot be read leaves the drawn sticker in its place.
    private func mealArt(for inputs: TodayDialInputs) async -> (stickers: [UUID: Image], photos: [UUID: UIImage]) {
        let ids = inputs.meals.compactMap(\.sticker?.photoID)
        guard !ids.isEmpty, let repository = foodRepository, let bytes = try? await repository.photoBytes(ids: ids) else { return ([:], [:]) }
        var stickers: [UUID: Image] = [:]
        var photos: [UUID: UIImage] = [:]
        for (id, data) in bytes {
            if let sticker = FoodLensArt.dialSticker(data, pixels: Self.stickerPixels) { stickers[id] = Image(uiImage: sticker) }
            if let photo = FoodLensArt.dialPhoto(data, longestSide: Self.photoPixels) { photos[id] = photo }
        }
        return (stickers, photos)
    }
}
