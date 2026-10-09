import SwiftUI
import ProfileKit
import DesignSystem

struct SleepNeedSetting: View {
    let repository: any GoalsRepository
    @State private var hours = 8.0
    @State private var savedHours = 8.0
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            HStack {
                LooprText("Sleep need", style: .settingsRow)
                Spacer()
                Picker("Sleep need", selection: $hours) {
                    ForEach(options, id: \.self) { option in
                        Text(LooprUnitFormatter.duration(minutes: option * 60) ?? "8 h").tag(option)
                    }
                }
                .tint(Color.loopr(.brand))
                .accessibilityIdentifier("settings-sleep-need")
            }
            if let message {
                LooprText(message, style: .caption, color: .inkSecondary)
            }
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .task { await load() }
        .onChange(of: hours) { _, value in
            guard value != savedHours else { return }
            Task { await save() }
        }
    }

    private var options: [Double] {
        Array(Set((8...24).map { Double($0) / 2 } + [hours])).sorted()
    }

    private func load() async {
        guard let goals = try? await repository.readGoals() else {
            message = "Sleep need could not be loaded."
            return
        }
        let resolved = SleepNeed.minutes(from: goals) / 60
        hours = resolved
        savedHours = resolved
    }

    private func save() async {
        do {
            _ = try await repository.saveGoal(type: .sleep, target: hours, unit: "hours", isEnabled: true)
            savedHours = hours
            message = "Sleep need saved."
            NotificationCenter.default.post(name: SleepNeed.didChange, object: nil)
        } catch {
            message = "Sleep need could not be saved."
        }
    }
}
