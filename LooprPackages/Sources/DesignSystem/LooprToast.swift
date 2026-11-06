import SwiftUI

/// A short confirmation that floats above the tab bar, with an optional action such as Undo.
/// The owner shows one at a time and clears it; `looprToast` hides it after a few seconds.
public struct LooprToastContent: Equatable, Identifiable, Sendable {
    public let id = UUID()
    public let message: String
    public let symbol: String
    public let accent: LooprColorToken
    public let actionTitle: String?

    public init(_ message: String, symbol: String = "checkmark.circle.fill", accent: LooprColorToken = .brand, actionTitle: String? = nil) {
        self.message = message; self.symbol = symbol; self.accent = accent; self.actionTitle = actionTitle
    }
}

public struct LooprToast: View {
    private let content: LooprToastContent
    private let action: (() -> Void)?

    public init(_ content: LooprToastContent, action: (() -> Void)? = nil) {
        self.content = content; self.action = action
    }

    public var body: some View {
        HStack(spacing: LooprSpacing.sm) {
            Image(systemName: content.symbol)
                .looprTypography(.title)
                .foregroundStyle(Color.loopr(content.accent))
                .symbolEffect(.bounce, value: content.id)
                .accessibilityHidden(true)
            LooprText(content.message, style: .rowTitle)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let title = content.actionTitle, let action {
                Button(title, action: action)
                    .looprTypography(.label)
                    .foregroundStyle(Color.loopr(content.accent))
                    .padding(.horizontal, LooprSpacing.sm)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("loopr-toast-action")
            }
        }
        .padding(.leading, LooprSpacing.md)
        .padding(.trailing, content.actionTitle == nil ? LooprSpacing.md : LooprSpacing.xxs)
        .frame(minHeight: 52)
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("loopr-toast")
    }
}

public extension View {
    /// Shows `toast` above the bottom edge and clears it after `seconds`. Each new toast restarts the clock.
    func looprToast(_ toast: Binding<LooprToastContent?>, bottomPadding: CGFloat = LooprSpacing.tabBarClearance,
                    seconds: Double = 4, action: (() -> Void)? = nil) -> some View {
        overlay(alignment: .bottom) {
            ZStack {
                if let content = toast.wrappedValue {
                    LooprToast(content, action: action.map { run in { run(); toast.wrappedValue = nil } })
                        .padding(.horizontal, LooprSpacing.screenGutter)
                        .padding(.bottom, bottomPadding)
                        .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.92, anchor: .bottom)))
                        .task(id: content.id) {
                            try? await Task.sleep(for: .seconds(seconds))
                            if toast.wrappedValue?.id == content.id { toast.wrappedValue = nil }
                        }
                        .onAppear { AccessibilityNotification.Announcement(content.message).post() }
                }
            }
            .animation(LooprMotion.reducesMotion(false) ? .linear(duration: 0) : .spring(response: 0.42, dampingFraction: 0.82), value: toast.wrappedValue?.id)
        }
    }
}
