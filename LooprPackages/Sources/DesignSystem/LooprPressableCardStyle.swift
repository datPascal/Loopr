import SwiftUI

/// Press feedback for any card that navigates: it gives a little under the
/// finger and springs back. With Reduce Motion it only dims.
public struct LooprPressableCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let reduces = LooprMotion.reducesMotion(reduceMotion)
        configuration.label
            .scaleEffect(configuration.isPressed && !reduces ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(LooprMotion.press, value: configuration.isPressed)
    }
}

/// Press feedback for a row inside a list card, where scaling one row would
/// pull it out of line with its neighbours. The row dims instead.
public struct LooprPressableListRowStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(LooprMotion.press, value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == LooprPressableCardStyle {
    static var looprPressableCard: LooprPressableCardStyle { LooprPressableCardStyle() }
}

public extension ButtonStyle where Self == LooprPressableListRowStyle {
    static var looprPressableRow: LooprPressableListRowStyle { LooprPressableListRowStyle() }
}
