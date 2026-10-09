import Foundation
import Testing
@testable import Loopr

struct AppLifecycleStateMachineTests {
    @Test
    func pairingLogCasesOmitIdentifiersAndFailureDetails() {
        #expect(BluetoothApplicationStatus.connected(.init()).logCase == "connected")
        #expect(BluetoothApplicationStatus.failed("private reason").logCase == "failed")
    }

    @Test
    func coldForegroundLaunchWaitsForSceneActivation() {
        var lifecycle = LooprLifecycleStateMachine()
        #expect(lifecycle.mode == .awaitingScene)
        #expect(lifecycle.receive(.sceneBackground) == .none)
        #expect(lifecycle.receive(.sceneActive) == .enterForeground)
        #expect(lifecycle.receive(.sceneActive) == .none)
        #expect(lifecycle.mode == .foreground)
    }

    @Test
    func bluetoothRestorationIsAnExplicitBackgroundLaunch() {
        var lifecycle = LooprLifecycleStateMachine()
        #expect(lifecycle.receive(.bluetoothRestoration) == .enterBackground)
        #expect(lifecycle.receive(.sceneBackground) == .none)
        #expect(lifecycle.mode == .background)
        #expect(lifecycle.receive(.sceneActive) == .enterForeground)
    }

    @Test
    func backgroundTaskLaunchHasNoImplicitSceneTransition() {
        var lifecycle = LooprLifecycleStateMachine()
        // The BGTask handler starts background work directly. UIApplication's
        // initial .background value must not be treated as a scene transition.
        #expect(lifecycle.receive(.sceneBackground) == .none)
        #expect(lifecycle.receive(.backgroundTask) == .enterBackground)
        #expect(lifecycle.mode == .background)
    }

    @Test
    func foregroundBackgroundForegroundMakesOneTransitionEach() {
        var lifecycle = LooprLifecycleStateMachine()
        #expect(lifecycle.receive(.sceneActive) == .enterForeground)
        #expect(lifecycle.receive(.sceneBackground) == .enterBackground)
        #expect(lifecycle.receive(.sceneBackground) == .none)
        #expect(lifecycle.receive(.sceneActive) == .enterForeground)
        #expect(lifecycle.mode == .foreground)
    }
}
