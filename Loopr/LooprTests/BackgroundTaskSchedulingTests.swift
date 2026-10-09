import Foundation
import Testing

@testable import Loopr

/// The BGTask fallback is the only thing that brings Loopr back when iOS has
/// stopped relaunching it for the band. An overnight trace showed it never
/// firing in five hours, so the two things that can silently disable it are
/// pinned here: the permitted identifiers, and the re-submission rule.
struct BackgroundTaskSchedulingTests {
    @Test
    func permittedIdentifiersCoverEveryRegisteredTask() {
        let permitted = Bundle.main.object(
            forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"
        ) as? [String]
        #expect(permitted != nil, "BGTaskSchedulerPermittedIdentifiers is missing")
        let declared = Set(permitted ?? [])
        // `BGTaskScheduler.register` returns false for an identifier that is not
        // declared, and every later submit throws notPermitted. Both failures
        // are silent at runtime.
        #expect(LooprBluetoothBackgroundTaskID.all.isSubset(of: declared))
    }

    @Test
    func backgroundModesAllowBluetoothProcessingAndRefresh() {
        let modes = Set(
            Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        )
        #expect(modes.contains("bluetooth-central"))
        #expect(modes.contains("processing"))
        #expect(modes.contains("fetch"))
    }

    @Test
    func nothingPendingSubmitsBothRequests() {
        let needed = LooprBluetoothBackgroundTaskBridge.identifiersNeedingSubmission(pending: [])
        #expect(needed == LooprBluetoothBackgroundTaskID.all)
    }

    /// The overnight regression. iOS relaunches Loopr for its restored central
    /// every few minutes, and re-submitting a pending identifier replaces it and
    /// resets earliestBeginDate to another fifteen minutes out, so the request
    /// never matured. A pending identifier must be left alone.
    @Test
    func aPendingRequestIsLeftAloneSoItsBeginDateCanMature() {
        let needed = LooprBluetoothBackgroundTaskBridge.identifiersNeedingSubmission(
            pending: [LooprBluetoothBackgroundTaskID.refresh]
        )
        #expect(needed == [LooprBluetoothBackgroundTaskID.sync])

        let none = LooprBluetoothBackgroundTaskBridge.identifiersNeedingSubmission(
            pending: LooprBluetoothBackgroundTaskID.all
        )
        #expect(none.isEmpty)
    }

    /// A handler renews only the identifier it consumed. Renewing the other one
    /// would replace a healthy pending request and push it out of reach again.
    @Test
    func aHandlerRenewsOnlyTheIdentifierItConsumed() {
        let needed = LooprBluetoothBackgroundTaskBridge.identifiersNeedingSubmission(
            pending: [],
            allowed: [LooprBluetoothBackgroundTaskID.refresh]
        )
        #expect(needed == [LooprBluetoothBackgroundTaskID.refresh])
    }

    @Test
    func unknownIdentifiersAreNeverSubmitted() {
        let needed = LooprBluetoothBackgroundTaskBridge.identifiersNeedingSubmission(
            pending: [],
            allowed: ["com.loopr.not.a.task"]
        )
        #expect(needed.isEmpty)
    }

    /// Fifteen minutes matches the band's own top-up cadence. A shorter window
    /// buys passes with nothing new in them; a longer one leaves a gap.
    @Test
    func theEarliestWindowMatchesTheBandTopUpCadence() {
        #expect(LooprBluetoothBackgroundTaskBridge.earliestWindowSeconds == 15 * 60)
    }
}
