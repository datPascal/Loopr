import AIKit
import DesignSystem
import SwiftUI
import UIKit

/// What Loopr sent to AI providers in the last 30 days, with the exact bytes of each request.
/// The list lives on this iPhone, goes out with exports and goes away with Delete all data.
struct RequestLogScreen: View {
    let log: any AgentRequestLogStore
    @State private var records: [AIRequestRecord] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var confirmingClear = false

    var body: some View {
        LooprDetailScaffold(spacing: LooprSpacing.lg) {
            LooprText("What Loopr sent to your AI provider in the last \(AgentRequestLogPolicy.retentionDays) days. Each entry holds the exact request, including the health data in it. It stays on this iPhone.",
                      style: .prose, color: .inkSecondary)
            if failed {
                LooprInlineMessage("Loopr could not read the log. Try again.", tone: .warning)
            } else if loaded && records.isEmpty {
                LooprCard {
                    LooprText("No requests yet. Ask sends nothing until you send a message.", style: .prose, color: .inkSecondary)
                }
                .accessibilityIdentifier("request-log-empty")
            } else if !records.isEmpty {
                LooprCard(density: .flush) {
                    VStack(spacing: 0) {
                        ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                            NavigationLink { RequestLogDetailScreen(record: record) } label: {
                                LooprRow(title: Self.title(record.purpose), subtitle: Self.subtitle(record), symbol: nil)
                            }
                            .buttonStyle(.looprPressableRow)
                            .padding(.horizontal, LooprSpacing.formCardPadding)
                            .accessibilityIdentifier("request-log-row-\(index)")
                            if index < records.count - 1 { LooprHairline().padding(.horizontal, LooprSpacing.formCardPadding) }
                        }
                    }
                }
                Button("Clear log", role: .destructive) { confirmingClear = true }
                    .buttonStyle(LooprDestructiveButtonStyle())
                    .accessibilityIdentifier("request-log-clear")
            }
        }
        .navigationTitle("Request log")
        .toolbarTitleDisplayMode(.inline)
        .accessibilityIdentifier("request-log-screen")
        .task { await reload() }
        .confirmationDialog("Clear the request log?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear log", role: .destructive) {
                Task {
                    do { try await Task.detached { try log.clear() }.value; await reload() } catch { failed = true }
                }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("This deletes the saved list. It does not change what providers already received.")
        }
    }

    /// The log holds whole request bodies, so it is read off the main actor.
    private func reload() async {
        let store = log
        do { records = try await Task.detached(priority: .userInitiated) { try store.records() }.value; failed = false } catch { failed = true }
        loaded = true
    }

    static func title(_ purpose: AIRequestPurpose) -> String {
        switch purpose {
        case .chat: "Chat message"
        case .toolRound: "Question with lookups"
        case .briefing: "Morning briefing"
        case .weeklyReview: "Weekly review"
        case .foodEstimate: "Food estimate"
        }
    }
    static func size(_ bytes: Int) -> String { Int64(bytes).formatted(.byteCount(style: .file).locale(LooprUnitFormatter.displayLocale)) }
    static func subtitle(_ record: AIRequestRecord) -> String {
        [record.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()),
         record.provider.name, size(record.bodyBytes)].joined(separator: " · ")
    }
    static func statusLabel(_ status: AIRequestStatus) -> String {
        switch status {
        case .sent: "Sent"
        case .succeeded: "Answered"
        case .failed: "Failed"
        case .refused: "Refused"
        case .cancelled: "Cancelled"
        }
    }
}

struct RequestLogDetailScreen: View {
    let record: AIRequestRecord
    @State private var copied = false
    /// The text view stays quick. Copy always carries every byte.
    private static let displayLimit = 40_000
    /// Decoded once. A request body can be hundreds of kilobytes.
    private let bodyText: String
    private let bodyIsCut: Bool

    init(record: AIRequestRecord) {
        self.record = record
        let text = String(decoding: record.body, as: UTF8.self)
        bodyText = text
        bodyIsCut = text.utf8.count > Self.displayLimit * 2 || text.count > Self.displayLimit
    }

    var body: some View {
        LooprDetailScaffold(spacing: LooprSpacing.lg) {
            LooprCard(density: .flush) {
                VStack(spacing: 0) {
                    fact("When", record.date.formatted(date: .abbreviated, time: .standard))
                    fact("Why", RequestLogScreen.title(record.purpose))
                    fact("Provider", "\(record.provider.name), \(record.model)")
                    if let origin = record.origin { fact("Asked from", origin) }
                    fact("Size", RequestLogScreen.size(record.bodyBytes))
                    fact("Result", record.httpStatus.map { "\(RequestLogScreen.statusLabel(record.status)), code \($0)" } ?? RequestLogScreen.statusLabel(record.status))
                }
                .padding(.horizontal, LooprSpacing.formCardPadding)
            }
            if !record.toolCalls.isEmpty {
                VStack(spacing: LooprSpacing.xs) {
                    LooprSectionHeader("Lookups in this request", detail: "Results from earlier rounds travel back in the body below.")
                    LooprCard(density: .flush) {
                        VStack(spacing: 0) {
                            ForEach(Array(record.toolCalls.enumerated()), id: \.offset) { index, call in
                                fact(call.name, call.denied ? "Blocked" : "\(RequestLogScreen.size(call.resultBytes))\(call.isError ? ", error" : "")")
                                if index < record.toolCalls.count - 1 { LooprHairline() }
                            }
                        }
                        .padding(.horizontal, LooprSpacing.formCardPadding)
                    }
                }
            }
            if !record.denials.isEmpty {
                VStack(spacing: LooprSpacing.xs) {
                    LooprSectionHeader("Blocked reads")
                    LooprCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            ForEach(Array(record.denials.enumerated()), id: \.offset) { _, denial in
                                LooprText(denial.message, style: .prose, color: .inkSecondary)
                            }
                        }
                    }
                }
            }
            VStack(spacing: LooprSpacing.xs) {
                LooprSectionHeader("Exact request", detail: "The bytes sent to \(record.provider.name).")
                LooprCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        Text(String(bodyText.prefix(Self.displayLimit)))
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(Color.loopr(.ink))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("request-log-body")
                        if bodyIsCut {
                            LooprText("Showing the first \(Self.displayLimit.formatted()) characters. Copy has all of it.", style: .caption, color: .inkSecondary)
                        }
                    }
                }
                Button { UIPasteboard.general.string = bodyText; copied = true } label: {
                    Label(copied ? "Copied" : "Copy request", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(LooprButtonStyle())
                .accessibilityIdentifier("request-log-copy")
            }
        }
        .navigationTitle(RequestLogScreen.title(record.purpose))
        .toolbarTitleDisplayMode(.inline)
        .accessibilityIdentifier("request-log-detail")
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.md) {
            LooprText(title, style: .prose, color: .inkSecondary)
            Spacer(minLength: LooprSpacing.sm)
            LooprText(value, style: .prose).multilineTextAlignment(.trailing)
        }
        .padding(.vertical, LooprSpacing.sm)
        .accessibilityElement(children: .combine)
    }
}
