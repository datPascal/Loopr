import Foundation
import SwiftUI

/// One haptic for one finished action. Each value carries its own token, so
/// two saves in a row still play twice.
///
/// ```swift
/// @State private var haptic: LooprHaptic?
/// ...
/// haptic = LooprHaptic(.success)
/// ...
/// .looprHaptic(haptic)
/// ```
public struct LooprHaptic: Equatable, Sendable {
    public let feedback: SensoryFeedback
    private let token = UUID()

    public init(_ feedback: SensoryFeedback) {
        self.feedback = feedback
    }

    /// A saved or finished result.
    public static var success: LooprHaptic { LooprHaptic(.success) }
    /// Something the person asked for did not happen.
    public static var error: LooprHaptic { LooprHaptic(.error) }
    /// A small confirmation, such as a toggle or a pick.
    public static var light: LooprHaptic { LooprHaptic(.impact(weight: .light)) }
}

public extension View {
    /// Plays `event` each time it changes to a new value.
    func looprHaptic(_ event: LooprHaptic?) -> some View {
        sensoryFeedback(trigger: event) { _, event in event?.feedback }
    }
}
