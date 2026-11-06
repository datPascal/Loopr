import SwiftUI
import WebKit

/// Shows the published page the way a browser will. The page has no script and no subresources, and this view
/// refuses every navigation away from it, so the preview cannot reach a network.
@available(iOS 26.0, macOS 26.0, *)
struct PublishPreviewWebView: View {
    enum Phase: Equatable { case loading, shown, failed }

    let html: String
    @State private var page: WebPage = Self.makePage()
    @State private var phase: Phase = .loading

    var body: some View {
        WebView(page)
            .webViewContentBackground(.hidden)
            .webViewLinkPreviews(.disabled)
            // The area is never an unexplained blank: it says when the page is still drawing or could not be drawn.
            .overlay {
                switch phase {
                case .loading:
                    ProgressView("Drawing the page")
                        .accessibilityIdentifier("publish-preview-loading")
                case .failed:
                    Text(verbatim: "The preview could not be drawn here. The files below are complete.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding()
                        .accessibilityIdentifier("publish-preview-failed")
                case .shown:
                    EmptyView()
                }
            }
            .task(id: html) {
                phase = .loading
                do {
                    for try await _ in page.load(html: html, baseURL: URL(string: "about:blank") ?? URL(fileURLWithPath: "/")) {}
                    phase = .shown
                } catch {
                    // The file size and the save control below still work.
                    phase = .failed
                }
            }
    }

    @MainActor
    private static func makePage() -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.loadsSubresources = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultNavigationPreferences.allowsContentJavaScript = false
        return WebPage(configuration: configuration, navigationDecider: Decider())
    }

    /// Allows only the page itself. A tap on anything that would leave it is cancelled.
    private struct Decider: WebPage.NavigationDeciding {
        func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
            action.request.url?.scheme == "about" ? .allow : .cancel
        }
    }
}
