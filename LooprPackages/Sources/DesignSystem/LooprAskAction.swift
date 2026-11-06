import SwiftUI

/// The shell supplies one Ask presentation to every feature package.
public struct LooprAskAction: Sendable {
    public let run: @MainActor @Sendable (String) -> Void
    private let runWithPrompt: (@MainActor @Sendable (String, String) -> Void)?

    /// - Parameter runWithPrompt: Opens Ask with a question already in the message field. Without
    ///   it, `open(_:prompt:)` opens Ask from the screen and drops the question.
    public init(
        run: @escaping @MainActor @Sendable (String) -> Void,
        runWithPrompt: (@MainActor @Sendable (String, String) -> Void)? = nil
    ) {
        self.run = run
        self.runWithPrompt = runWithPrompt
    }

    /// Opens Ask from `origin`. A prompt fills the message field and is never sent for the person.
    @MainActor
    public func open(_ origin: String, prompt: String? = nil) {
        if let prompt, let runWithPrompt { runWithPrompt(origin, prompt) } else { run(origin) }
    }

    /// The word beside the sparkle in a tab header.
    public static let buttonTitle = "Ask"

    /// - Parameter titled: Tab headers draw "Ask" beside the sparkle; the toolbar on pushed pages keeps the symbol.
    @MainActor
    public func header(for title: String, identifier: String? = nil, titled: Bool = true) -> LooprHeaderAction {
        LooprHeaderAction(symbol: "sparkles", label: "Ask about \(title)", title: titled ? Self.buttonTitle : nil,
            identifier: identifier ?? "\(title.lowercased().replacingOccurrences(of: " ", with: "-"))-header-ask") {
                run(title)
            }
    }
}

extension EnvironmentValues {
    @Entry public var looprAsk: LooprAskAction? = nil
    @Entry public var looprOpenYourData: LooprShellAction? = nil
    /// Set by the outermost Ask toolbar on a page, so a screen inside it that adds its own does not draw a second button.
    @Entry var looprAskToolbarPlaced: Bool = false
}

/// The same entry on pushed pages, beside the native back button. One per page: the outermost one wins.
private struct LooprAskToolbar: ViewModifier {
    @Environment(\.looprAsk) private var ask
    @Environment(\.looprAskToolbarPlaced) private var placed
    let origin: String

    func body(content: Content) -> some View {
        content
            .environment(\.looprAskToolbarPlaced, true)
            .toolbar {
                if let ask, !placed {
                    ToolbarItem(placement: .topBarTrailing) {
                        LooprHeaderActionButton(action: ask.header(for: origin, identifier: "screen-ask", titled: false))
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
    }
}

public extension View {
    func looprAskToolbar(origin: String) -> some View {
        modifier(LooprAskToolbar(origin: origin))
    }
}

#Preview {
    NavigationStack {
        LooprTabScaffold(header: .init(title: "Data", accent: .heart), glow: .heart, identifier: "ask-preview") {
            LooprCard { LooprText("Your measurements", style: .rowTitle) }
                .padding(.horizontal, LooprSpacing.screenGutter)
        }
        .environment(\.looprAsk, LooprAskAction { _ in })
    }
}
