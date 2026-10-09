import BackgroundTasks
import Foundation
import UIKit
import UserNotifications
import NotificationKit
import SwiftUI
import BluetoothKit

nonisolated enum LooprBluetoothBackgroundTaskID {
    static let sync = "com.loopr.bluetooth.sync"
    static let refresh = "com.loopr.bluetooth.refresh"
    static let all: Set<String> = [sync, refresh]
}

/// The OS bridge owns registration and scheduling only.  Bluetooth state and
/// serialized work remain in `BluetoothApplicationModel`/SyncKit, which keeps
/// task expiration and foreground preemption on the same runtime owner.
@MainActor
final class LooprBluetoothBackgroundTaskBridge {
    private weak var model: BluetoothApplicationModel?
    weak var lifecycleDelegate: LooprApplicationDelegate?
    private var didRegister = false

    func configure(model: BluetoothApplicationModel) {
        self.model = model
    }

    /// One stderr line per scheduling decision. `fputs` is used everywhere in
    /// the background path: `FileHandle.write` raises an Objective-C exception
    /// on a failed write and that killed a background relaunch once already.
    nonisolated static func debugLog(_ message: String) {
        #if DEBUG
        let stamp = Date().formatted(date: .omitted, time: .standard)
        fputs("[Loopr BGTask] \(stamp) \(message)\n", stderr)
        #endif
    }

    func registerHandlers() {
        guard !didRegister else { return }
        didRegister = true

        let syncRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: LooprBluetoothBackgroundTaskID.sync,
            using: .main
        ) { [weak self] task in
            self?.handle(task: task, identifier: LooprBluetoothBackgroundTaskID.sync)
        }
        let refreshRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: LooprBluetoothBackgroundTaskID.refresh,
            using: .main
        ) { [weak self] task in
            self?.handle(task: task, identifier: LooprBluetoothBackgroundTaskID.refresh)
        }
        // `register` returns false when the identifier is missing from
        // BGTaskSchedulerPermittedIdentifiers. That failure is silent at
        // runtime and every later submit throws `notPermitted`, so say it.
        Self.debugLog("registered sync=\(syncRegistered) refresh=\(refreshRegistered)")
    }

    /// The band tops history up about every fifteen minutes, so asking iOS for
    /// a window sooner than that only buys passes with nothing new in them.
    /// The heavy derivation is deliberately steered into the processing task,
    /// which is the window iOS grants when the phone is idle and charging.
    nonisolated static let earliestWindowSeconds: TimeInterval = 15 * 60

    /// Submits both requests, skipping any identifier that iOS already holds.
    ///
    /// Re-submitting a pending identifier replaces it, and a replacement resets
    /// `earliestBeginDate` to now + fifteen minutes. Loopr is relaunched for its
    /// restored Bluetooth central every few minutes overnight, and every one of
    /// those relaunches used to push the pending request out of reach again, so
    /// the fallback never became eligible. Leaving an existing request alone is
    /// what lets it mature.
    func schedule(reason: String) {
        Task { @MainActor in
            let pending = Set(
                await BGTaskScheduler.shared.pendingTaskRequests().map(\.identifier)
            )
            self.submitIfAbsent(pending: pending, reason: reason)
        }
    }

    /// The synchronous half, kept separate so tests and the task handlers can
    /// drive it with a known pending set. `identifiers` limits which requests
    /// are considered, so a handler can renew only the identifier it consumed
    /// instead of replacing the other one and resetting its begin date.
    func submitIfAbsent(
        pending: Set<String>,
        reason: String,
        identifiers: Set<String> = LooprBluetoothBackgroundTaskID.all
    ) {
        let needed = Self.identifiersNeedingSubmission(pending: pending, allowed: identifiers)
        for identifier in LooprBluetoothBackgroundTaskID.all.sorted() {
            guard identifiers.contains(identifier) else { continue }
            guard needed.contains(identifier) else {
                Self.debugLog("schedule skip \(identifier); already pending (reason=\(reason))")
                continue
            }
            submit(makeRequest(for: identifier), reason: reason)
        }
    }

    /// The scheduling decision, with no BGTaskScheduler in it.
    ///
    /// An identifier iOS already holds is left alone: re-submitting replaces the
    /// request and pushes `earliestBeginDate` another fifteen minutes out, which
    /// is how a night of Bluetooth relaunches starved the fallback.
    nonisolated static func identifiersNeedingSubmission(
        pending: Set<String>,
        allowed: Set<String> = LooprBluetoothBackgroundTaskID.all
    ) -> Set<String> {
        LooprBluetoothBackgroundTaskID.all
            .intersection(allowed)
            .subtracting(pending)
    }

    private func makeRequest(for identifier: String) -> BGTaskRequest {
        let request: BGTaskRequest
        if identifier == LooprBluetoothBackgroundTaskID.sync {
            let processing = BGProcessingTaskRequest(identifier: identifier)
            // The band tops up over Bluetooth, so neither a charger nor Wi-Fi is
            // a real prerequisite. Demanding either would mean no overnight run
            // on a night the phone is off the charger.
            processing.requiresNetworkConnectivity = false
            processing.requiresExternalPower = false
            request = processing
        } else {
            request = BGAppRefreshTaskRequest(identifier: identifier)
        }
        request.earliestBeginDate = Date().addingTimeInterval(Self.earliestWindowSeconds)
        return request
    }

    private func submit(_ request: BGTaskRequest, reason: String) {
        do {
            try BGTaskScheduler.shared.submit(request)
            Self.debugLog(
                "schedule submitted \(request.identifier) earliest=+\(Int(Self.earliestWindowSeconds))s (reason=\(reason))"
            )
        } catch {
            // `try?` here hid `notPermitted`, `tooManyPendingTaskRequests`, and
            // `unavailable` for the whole life of this bridge.
            Self.debugLog("schedule FAILED \(request.identifier) (reason=\(reason)) error=\(error)")
        }
    }

    private func handle(task: BGTask, identifier: String) {
        Self.debugLog("handler start \(identifier)")
        // Re-submit inside the handler. A consumed request is gone, and nothing
        // else asks for the next window while the phone stays locked, so a
        // single fire used to be the last one Loopr ever got.
        submitIfAbsent(pending: [], reason: "handler \(identifier)", identifiers: [identifier])

        let completion = OneShotBGTaskCompletion(task: task)
        task.expirationHandler = { [weak self] in
            Self.debugLog("handler expired \(identifier)")
            // Complete first. iOS kills the app if `setTaskCompleted` is late,
            // and the fence below neither needs nor blocks that call.
            completion.complete(success: false)
            Task { @MainActor in
                await self?.model?.expireBackgroundTask()
            }
        }

        Task { @MainActor [weak self] in
            guard let model = self?.model else {
                Self.debugLog("handler end \(identifier) success=false reason=no model")
                completion.complete(success: false)
                return
            }
            await self?.lifecycleDelegate?.backgroundTaskStarted()
            // SyncKit logs the matching `background run end; stored=N` line, so
            // the two together say whether the window banked anything.
            let success = await model.runBackgroundTask(identifier: identifier)
            Self.debugLog("handler end \(identifier) success=\(success)")
            completion.complete(success: success)
        }
    }
}

/// `BGTask` can race normal completion and expiration.  This guard is kept in
/// the app bridge as a final OS-facing defense even though SyncKit also guards
/// its internal completion callback.
private final class OneShotBGTaskCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false
    private let task: BGTask

    init(task: BGTask) { self.task = task }

    func complete(success: Bool) {
        let shouldComplete = lock.withLock {
            guard !didComplete else { return false }
            didComplete = true
            return true
        }
        guard shouldComplete else { return }
        task.setTaskCompleted(success: success)
    }
}

/// Hands the model created in `LooprApp.init()` to the application delegate.
///
/// When iOS relaunches Loopr for its Bluetooth central it does not connect a
/// scene, so the SwiftUI `.task` that normally installs the runtime never runs
/// and the app would sit awake next to the band doing nothing. The delegate
/// reads the model from here and starts provisioning inspection itself.
@MainActor
final class LooprLaunchBootstrap {
    static let shared = LooprLaunchBootstrap()

    private(set) weak var model: BluetoothApplicationModel?

    func register(_ model: BluetoothApplicationModel) {
        self.model = model
    }
}

/// Launch begins without an active scene, even for an ordinary foreground
/// launch. Only a scene transition or an explicit restoration callback may
/// change the Bluetooth runtime's mode.
struct LooprLifecycleStateMachine {
    enum Mode: Equatable { case awaitingScene, foreground, background }
    enum Event { case sceneActive, sceneBackground, bluetoothRestoration, backgroundTask }
    enum Action: Equatable { case none, enterForeground, enterBackground }

    private(set) var mode: Mode = .awaitingScene

    mutating func receive(_ event: Event) -> Action {
        switch event {
        case .sceneActive:
            guard mode != .foreground else { return .none }
            mode = .foreground
            return .enterForeground
        case .sceneBackground:
            // SwiftUI can report an initial .background phase before the
            // first scene activation. This is not a background transition.
            guard mode == .foreground else { return .none }
            mode = .background
            return .enterBackground
        case .bluetoothRestoration, .backgroundTask:
            guard mode != .foreground, mode != .background else { return .none }
            mode = .background
            return .enterBackground
        }
    }
}

@MainActor
final class LooprApplicationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let backgroundTasks = LooprBluetoothBackgroundTaskBridge()
    private var lifecycle = LooprLifecycleStateMachine()
    private var lifecycleTask: Task<Void, Never>?
    private var restorationObserver: (any NSObjectProtocol)?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        #if DEBUG
        // Overnight runs have no console attached, so keep the DEBUG stderr
        // trace in a file the developer can pull from the app container.
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let path = caches.appendingPathComponent("loopr-debug.log").path
            // `freopen` closes stderr when it fails, so probe the file first.
            // A locked phone can refuse the open.
            if let probe = fopen(path, "a") {
                fclose(probe)
                if freopen(path, "a", stderr) != nil { setvbuf(stderr, nil, _IONBF, 0) }
            }
        }
        #endif
        application.shortcutItems = LooprQuickActions.items
        backgroundTasks.lifecycleDelegate = self
        #if canImport(CoreBluetooth)
        restorationObserver = NotificationCenter.default.addObserver(
            forName: CoreBluetoothTransport.didRestoreStateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in self?.bluetoothRestorationDetected() }
        }
        #endif
        backgroundTasks.registerHandlers()
        UNUserNotificationCenter.current().delegate = self
        // Until permission is read, the notification policy only queues.
        // Reading it on every launch, the Bluetooth relaunch included, is what
        // lets a queued alert go out at all.
        Task { await LooprNotificationRuntime.shared.prepareAtLaunch() }
        // UIApplication reports .background before a normal scene activates.
        // No scene is on screen yet, so the derivation budget starts closed.
        // CoreBluetooth's willRestoreState callback and BGTask handlers enter
        // background mode when they actually arrive.
        LooprForegroundState.shared.set(foreground: false)
        #if DEBUG
        let message = "[Loopr BG] \(Date().formatted(date: .omitted, time: .standard)) didFinishLaunching; awaitingScene=true\n"
        // `FileHandle.write` raises an Objective-C exception on a failed write,
        // which killed a background relaunch. `fputs` fails quietly.
        fputs(message, stderr)
        #endif
        // Scheduling is not conditional on the model, on the launch reason, or
        // on provisioning inspection finishing. Every launch is a chance to make
        // sure iOS still holds a request for Loopr; a launch that found no model
        // is exactly the launch that most needs the fallback.
        backgroundTasks.schedule(reason: "launch/awaitingScene")
        if let model = LooprLaunchBootstrap.shared.model {
            backgroundTasks.configure(model: model)
            Task { @MainActor in await model.inspectProvisioningOnLaunch() }
        }
        _ = launchOptions
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = LooprQuickActionSceneDelegate.self
        return configuration
    }

    func configure(model: BluetoothApplicationModel) {
        backgroundTasks.configure(model: model)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        transition(.sceneActive)
        // Permission can change in iOS Settings while Loopr is away.
        Task {
            _ = await LooprNotificationRuntime.shared.refreshAuthorization()
            await LooprHeartAlertsRuntime.shared.appBecameActive()
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        transition(.sceneBackground)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: transition(.sceneActive)
        case .background: transition(.sceneBackground)
        case .inactive: LooprForegroundState.shared.set(foreground: false)
        @unknown default: break
        }
    }

    func backgroundTaskStarted() async {
        transition(.backgroundTask)
        await lifecycleTask?.value
    }

    private func bluetoothRestorationDetected() {
        #if DEBUG
        let headless = lifecycle.mode == .awaitingScene
        #endif
        transition(.bluetoothRestoration)
        #if DEBUG
        if headless, let model = backgroundTasks.modelForLifecycle {
            Task { @MainActor in await DebugLaunchAlarm.runHeadless(model: model) }
        }
        #endif
    }

    private func transition(_ event: LooprLifecycleStateMachine.Event) {
        let action = lifecycle.receive(event)
        if action == .none {
            // Returning from an inactive interruption does not restart the
            // Bluetooth runtime, but it does reopen the derivation budget.
            if case .sceneActive = event {
                LooprForegroundState.shared.set(foreground: true)
            }
            return
        }
        LooprForegroundState.shared.set(foreground: action == .enterForeground)
        backgroundTasks.schedule(reason: action == .enterForeground ? "scene/active" : "scene/background")
        let predecessor = lifecycleTask
        lifecycleTask = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let model = self?.backgroundTasks.modelForLifecycle
                ?? LooprLaunchBootstrap.shared.model else { return }
            await model.inspectProvisioningOnLaunch()
            switch action {
            case .enterForeground: await model.enterForeground()
            case .enterBackground: await model.enterBackground()
            case .none: break
            }
        }
    }

    /// Loopr raises almost every notification right after something happened
    /// in the app, so the app is usually still on screen when it lands.
    /// Without this iOS drops those silently and the person sees nothing.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if response.actionIdentifier == NotificationCategoryCatalog.pauseForTodayAction {
            // A background action: silence that kind for the rest of the day
            // without opening Loopr.
            let family = NotificationResponsePayload.family(from: userInfo)
            Task {
                if let family { await LooprHeartAlertsRuntime.shared.pauseForToday(family) }
                completionHandler()
            }
            return
        }
        let link = try? NotificationResponsePayload.deepLink(from: userInfo)
        DispatchQueue.main.async {
            if let link {
                // A tap can cold-launch Loopr before the shell subscribes, so
                // the link is also parked for the shell to pick up.
                LooprNotificationLaunchRoute.shared.park(link)
                NotificationCenter.default.post(name: looprNotificationDeepLinkName, object: link)
            }
            completionHandler()
        }
    }
}

private extension LooprBluetoothBackgroundTaskBridge {
    var modelForLifecycle: BluetoothApplicationModel? { model }
}
