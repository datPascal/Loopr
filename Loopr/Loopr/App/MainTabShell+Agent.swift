import AIKit
import DesignSystem
import DomainKit
import JournalKit
import SleepKit
import SwiftUI
import TrainKit

/// Where one Ask source button goes. This is the whole mapping and it needs no shell, so a test can
/// check it. A source whose id or day cannot be read lands on the tab that owns the data, never on
/// a blank screen.
nonisolated enum AgentSourceDestination: Equatable {
    case metric(MetricKey, day: DayIdentity?)
    case sleepNight(day: DayIdentity?)
    case foodDay(day: DayIdentity?)
    case workout(UUID)
    case trainSession(UUID)
    case habitCheckIn(String)
    case habitHistory
    case patterns
    case tabHome(MainTab)

    init(_ link: AgentSourceLink) {
        switch link {
        case .metric(let key, let day):
            if let metric = MetricKey(rawValue: key) { self = .metric(metric, day: DayIdentity(habitKey: day)) }
            else { self = .tabHome(.data) }
        case .sleep(let day): self = .sleepNight(day: DayIdentity(habitKey: day))
        case .foodDay(let day): self = .foodDay(day: DayIdentity(habitKey: day))
        case .workout(let id):
            if let identifier = UUID(uuidString: id) { self = .workout(identifier) } else { self = .tabHome(.fitness) }
        case .trainSession(let id):
            if let identifier = UUID(uuidString: id) { self = .trainSession(identifier) } else { self = .tabHome(.fitness) }
        case .habitCheckIn(let day):
            if DayIdentity(habitKey: day) != nil { self = .habitCheckIn(day) } else { self = .tabHome(.protocol) }
        case .habitHistory: self = .habitHistory
        case .patterns: self = .patterns
        }
    }
}

extension MainTabShell {
    /// A source button under an Ask answer. Ask closes first, then the app shows the record behind
    /// the source, through the same routes a deep link uses.
    func openAgentSource(_ link: AgentSourceLink) {
        router.dismiss()
        switch AgentSourceDestination(link) {
        case .metric(let key, let day):
            show(day)
            healthPath = [.metric(key)]
            selection = .data
        case .sleepNight(let day):
            show(day)
            healthPath = [.sleepHome]
            selection = .data
        case .foodDay(let day):
            // The Food tab reads the shared day, so picking the day is how it opens on it.
            show(day)
            selection = .food
        case .workout(let id): apply(.workout(id))
        case .trainSession(let id):
            selection = .fitness
            workoutsPath = [.train(.summary(id))]
        case .habitCheckIn(let day): apply(.habitCheckIn(day))
        case .habitHistory: apply(.habitHistory)
        // Same gate as the deep link: Release builds keep Patterns off until its stage opens.
        case .patterns: apply(.patterns)
        case .tabHome(let tab): selection = tab
        }
    }

    private func show(_ day: DayIdentity?) {
        if let day { daySelection.select(day) }
    }
}
