import DesignSystem
import SwiftUI

enum WorkoutDurationText {
    static func formatted(_ seconds: TimeInterval?) -> String? {
        guard let seconds else { return nil }
        return LooprUnitFormatter.duration(minutes: seconds / 60)
    }
}

struct WorkoutDatePickerRow: View {
    let title: String
    @Binding var selection: Date

    var body: some View {
        DatePicker(selection: $selection, displayedComponents: [.date, .hourAndMinute]) {
            LooprText(title, style: .settingsRow)
        }
        .datePickerStyle(.compact)
        .looprTypography(.settingsRow)
        .tint(Color.loopr(.movement))
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
    }
}
