import AnalyticsKit
import Combine
import DataKit
import DesignSystem
import DomainKit
import Foundation
import RoutineKit
import SwiftUI

/// The route destination for the blood test screens, pushed on Data's stack: the list (`.labs`), one report
/// (`.labReport`), typed entry (`.labEntry`) and lab clock entry (`.labClockEntry`).
struct LabsFeatureRoot: View {
    let route: AppHealthRoute
    @ObservedObject var repositories: ProductRepositoryContainer
    let navigate: (AppHealthRoute) -> Void

    var body: some View {
        switch route {
        case .labs: LabsListRoot(repositories: repositories, navigate: navigate)
        case .labReport(let id): LabReportRoot(reportID: id, repositories: repositories, navigate: navigate)
        case .labEntry: LabEntryRoot(repositories: repositories)
        case .labClockEntry: LabClockEntryRoot(repositories: repositories)
        case .labMarker(let key): LabMarkerRoot(key: key, repositories: repositories, navigate: navigate)
        default: EmptyView()
        }
    }
}

private enum LabsClock {
    @MainActor static func now(_ repositories: ProductRepositoryContainer) -> Date {
        repositories.environment.dateProvider.now()
    }

    @MainActor static func calendar(_ repositories: ProductRepositoryContainer) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = repositories.environment.timeZoneProvider.timeZone
        return calendar
    }
}

private struct LabsUnavailableError: Error {}

private let labsUnavailable = "Loopr could not open your blood tests on this iPhone. Close and open the app to try again."

/// Loads what the list shows and keeps the last good result. A load that a newer load overtook is dropped.
@MainActor
private final class LabsListLoader: ObservableObject {
    @Published private(set) var snapshot: LabsListSnapshot?
    @Published private(set) var failure: String?
    private var generation = 0

    func load(_ services: LabsServices?, now: Date, calendar: Calendar) async {
        generation += 1
        let token = generation
        guard let services else { failure = labsUnavailable; return }
        var reminded: Set<RuleKey> = []
        #if canImport(UserNotifications)
        reminded = await LooprNotificationRuntime.shared.testReminderKeys()
        #endif
        do {
            let next = try await LabsReader.list(services, now: now, calendar: calendar, reminded: reminded)
            guard token == generation, !Task.isCancelled else { return }
            snapshot = next
            failure = nil
        } catch {
            guard token == generation else { return }
            failure = "Loopr could not read your blood tests. Open this screen again to retry."
        }
    }
}

private struct LabsListRoot: View {
    @ObservedObject var repositories: ProductRepositoryContainer
    let navigate: (AppHealthRoute) -> Void
    @Environment(\.looprScanLabReport) private var scanLabReport
    @StateObject private var loader = LabsListLoader()

    var body: some View {
        let services = LabsServicesProvider.services(for: repositories)
        let now = LabsClock.now(repositories)
        let calendar = LabsClock.calendar(repositories)
        LabsListScreen(snapshot: loader.snapshot, failure: loader.failure,
                       actions: actions(services: services, now: now, calendar: calendar), now: now, calendar: calendar)
            .onAppear { reload(services: services, now: now, calendar: calendar) }
    }

    private func reload(services: LabsServices?, now: Date, calendar: Calendar) {
        let loader = loader
        Task { await loader.load(services, now: now, calendar: calendar) }
    }

    private func actions(services: LabsServices?, now: Date, calendar: Calendar) -> LabsListActions {
        let loader = loader
        let navigate = navigate
        let refresh: @MainActor () async -> Void = { await loader.load(services, now: now, calendar: calendar) }
        return LabsListActions(
            openReport: { navigate(.labReport($0)) },
            addTyped: { navigate(.labEntry) },
            addClock: { navigate(.labClockEntry) },
            // The Food camera's Lab mode, opened by the shell. Without a shell (previews) the action is hidden.
            scan: scanLabReport.map { action in { @MainActor in action.run() } },
            deleteClock: { id in
                guard let services else { return labsUnavailable }
                do { try await LabsReader.delete(services, clockID: id) } catch { return "Loopr could not delete that result. Try again." }
                await refresh()
                return nil
            },
            setReminder: { test in
                #if canImport(UserNotifications)
                let outcome = await LooprNotificationRuntime.shared.scheduleTestReminder(test, now: now, calendar: calendar)
                await refresh()
                return LabsReminderCopy.message(for: outcome)
                #else
                return nil
                #endif
            },
            removeReminder: { test in
                #if canImport(UserNotifications)
                await LooprNotificationRuntime.shared.cancelTestReminder(test.ruleKey)
                #endif
                await refresh()
            },
            markDone: { test in
                guard let services else { return labsUnavailable }
                do { try await LabsReader.markDone(services, ruleKey: test.ruleKey, now: now, calendar: calendar) }
                catch { return "Loopr could not mark that done. Try again." }
                await refresh()
                return nil
            },
            saveValue: { value in
                guard let services else { return labsUnavailable }
                do { try await LabsReader.update(services, value: value) } catch { return "Loopr could not save that value. Try again." }
                await refresh()
                return nil
            },
            openRangesMethod: { navigate(.method(.labRanges)) },
            openBloodAgeMethod: { navigate(.method(.phenoAge)) })
    }
}

/// One marker with every draw, opened from Data's year rows or its star map. It reads the same list the Blood tests
/// page reads and shows that marker's row.
private struct LabMarkerRoot: View {
    let key: LabMarkerKey
    @ObservedObject var repositories: ProductRepositoryContainer
    let navigate: (AppHealthRoute) -> Void
    @StateObject private var loader = LabsListLoader()

    var body: some View {
        let services = LabsServicesProvider.services(for: repositories)
        let now = LabsClock.now(repositories)
        let calendar = LabsClock.calendar(repositories)
        Group {
            if let snapshot = loader.snapshot {
                let row = snapshot.marker(key)
                LabMarkerScreen(row: row, labName: row?.entries.last.map { LabsDisplay.labName($0.report) },
                    save: { value in
                        guard let services else { return labsUnavailable }
                        do { try await LabsReader.update(services, value: value) } catch { return "Loopr could not save that value. Try again." }
                        await loader.load(services, now: now, calendar: calendar)
                        return nil
                    },
                    openRangesMethod: { navigate(.method(.labRanges)) },
                    openBloodAgeMethod: { navigate(.method(.phenoAge)) })
            } else if let failure = loader.failure {
                LooprInlineMessage(failure, tone: .warning).padding(LooprSpacing.screenGutter)
            } else {
                LooprSkeleton(height: 120).padding(LooprSpacing.screenGutter)
            }
        }
        .task { await loader.load(services, now: now, calendar: calendar) }
    }
}

@MainActor
private final class LabReportLoader: ObservableObject {
    @Published private(set) var detail: LabReportDetail?
    @Published private(set) var missing = false
    @Published private(set) var failure: String?

    func load(_ services: LabsServices?, reportID: UUID) async {
        guard let services else { failure = labsUnavailable; return }
        do {
            let next = try await LabsReader.detail(services, reportID: reportID)
            detail = next
            missing = next == nil
            failure = nil
        } catch {
            failure = "Loopr could not read this report. Open it again to retry."
        }
    }
}

private struct LabReportRoot: View {
    let reportID: UUID
    @ObservedObject var repositories: ProductRepositoryContainer
    let navigate: (AppHealthRoute) -> Void
    @StateObject private var loader = LabReportLoader()

    var body: some View {
        let services = LabsServicesProvider.services(for: repositories)
        let loader = loader
        let id = reportID
        let reload: @MainActor () async -> Void = { await loader.load(services, reportID: id) }
        VStack(spacing: 0) {
            if let failure = loader.failure {
                LooprInlineMessage(failure, tone: .warning).padding(LooprSpacing.screenGutter)
            }
            LabReportScreen(detail: loader.detail, missing: loader.missing, actions: LabReportActions(
                saveValue: { value in
                    guard let services else { return labsUnavailable }
                    do { try await LabsReader.update(services, value: value) } catch { return "Loopr could not save that value. Try again." }
                    await reload()
                    return nil
                },
                markChecked: { valueID in
                    guard let services, var value = loader.detail?.groups.flatMap(\.rows).map(\.value).first(where: { $0.id == valueID }) else {
                        return labsUnavailable
                    }
                    value.needsReview = false
                    do { try await LabsReader.update(services, value: value) } catch { return "Loopr could not save that. Try again." }
                    await reload()
                    return nil
                },
                deleteReport: {
                    guard let services else { return labsUnavailable }
                    do { try await LabsReader.delete(services, reportID: id) } catch { return "Loopr could not delete this report. Try again." }
                    return nil
                },
                openBloodAgeMethod: { navigate(.method(.phenoAge)) },
                openRangesMethod: { navigate(.method(.labRanges)) }))
        }
        .task { await reload() }
    }
}

private struct LabEntryRoot: View {
    @ObservedObject var repositories: ProductRepositoryContainer

    var body: some View {
        let services = LabsServicesProvider.services(for: repositories)
        LabEntryScreen(now: LabsClock.now(repositories),
                       timeZoneIdentifier: repositories.environment.timeZoneProvider.timeZone.identifier) { report, values in
            guard let services else { throw LabsUnavailableError() }
            try await LabsReader.save(services, report: report, values: values)
        }
    }
}

private struct LabClockEntryRoot: View {
    @ObservedObject var repositories: ProductRepositoryContainer

    var body: some View {
        let services = LabsServicesProvider.services(for: repositories)
        LabClockEntryScreen(now: LabsClock.now(repositories),
                            timeZoneIdentifier: repositories.environment.timeZoneProvider.timeZone.identifier) { result in
            guard let services else { throw LabsUnavailableError() }
            try await LabsReader.save(services, clock: result)
        }
    }
}
