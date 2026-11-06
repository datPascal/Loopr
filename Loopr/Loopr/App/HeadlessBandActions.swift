import Foundation
import StorageKit

/// A Bluetooth restoration can launch the process without a SwiftUI scene.
/// Give it the same event consumer as the shell, then join its shutdown before
/// the shell takes ownership so a tap or alarm event is never handled twice.
@MainActor
enum LooprHeadlessBandActions {
    private static var task: Task<Void, Never>?

    static func start(model: BluetoothApplicationModel) {
        guard task == nil, AppEnvironment.make().composition == .production else { return }
        task = Task {
            defer { task = nil }
            let environment = AppEnvironment.production()
            guard let storageURL = environment.storageURL else { return }
            var runtime: (any LooprDeviceCenterRuntime)?
            for _ in 0..<60 {
                guard !Task.isCancelled else { return }
                runtime = model.heartLiveRuntime() as? any LooprDeviceCenterRuntime
                if runtime != nil { break }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
            guard let runtime, !Task.isCancelled else { return }
            do {
                let database = try await Task.detached {
                    try LooprProductionDatabases.shared.database(
                        at: storageURL, applicationVersion: environment.applicationVersion
                    )
                }.value
                guard !Task.isCancelled else { return }
                let consumer = BandEventActionConsumerFactory.make(
                    runtime: runtime,
                    journal: try SQLiteJournalRepository(database: database),
                    alarmRepository: try SQLiteDeviceCenterRepository(database: database),
                    performer: LooprPhoneActionPerformer()
                )
                await consumer.start()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { break }
                }
                await consumer.stop()
            } catch {
                BandActionLog.alarm("background alarm storage unavailable: \(error)")
            }
        }
    }

    static func stop() async {
        task?.cancel()
        await task?.value
    }
}
