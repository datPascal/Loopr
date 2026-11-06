import AIKit
import DesignSystem
import SwiftUI

/// What the top rows of the history sheet do. The screen owns each one, because each closes or
/// pushes something the sheet cannot reach.
struct CoachHistoryActions {
    var newChat: () -> Void
    var reviewSharedData: () -> Void
    var preferences: () -> Void
    var providers: () -> Void
}

/// The Ask sheet's menu: New chat, shared data, preferences and providers, then past chats
/// newest first, grouped by day. Deleting asks first, inside the sheet.
struct CoachHistorySheet: View {
    @ObservedObject var model: CoachChatViewModel
    let open: (CoachConversation) -> Void
    let actions: CoachHistoryActions
    @State private var pendingDelete: CoachConversation?

    private struct Day: Identifiable {
        let title: String
        let chats: [CoachConversation]
        var id: String { title }
    }

    private var days: [Day] {
        let calendar = Calendar.current
        var order: [Date] = []
        var groups: [Date: [CoachConversation]] = [:]
        for chat in model.history {
            let day = calendar.startOfDay(for: chat.updatedAt)
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(chat)
        }
        return order.map { Day(title: Self.title(for: $0, calendar: calendar), chats: groups[$0] ?? []) }
    }

    private static func title(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    var body: some View {
        List {
            Section {
                actionRow("New chat", symbol: "square.and.pencil", id: "ask-history-new", disabled: model.phase != .ready, action: actions.newChat)
                if model.conversation != nil {
                    actionRow("Review shared data", symbol: "hand.raised", id: "ask-history-review", action: actions.reviewSharedData)
                }
                actionRow("Coach preferences", symbol: "slider.horizontal.3", id: "ask-history-preferences", showsChevron: true, action: actions.preferences)
                actionRow("AI providers", symbol: "key", id: "ask-history-providers", showsChevron: true, action: actions.providers)
            }
            if model.history.isEmpty {
                Section { emptyCard }
            } else {
                ForEach(days) { day in
                    Section {
                        ForEach(day.chats) { chat in row(chat) }
                    } header: {
                        Text(day.title.looprLabelCased)
                            .looprTypography(.sectionLabel)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .accessibilityLabel(day.title)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.loopr(.settingsBackground).ignoresSafeArea())
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refreshHistory() }
        .confirmationDialog("Delete this chat?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            if let value = pendingDelete {
                Button("Delete chat", role: .destructive) { Task { await model.delete(value); pendingDelete = nil } }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
        } message: {
            Text("This removes the chat from Loopr. It does not delete data already received by the provider.")
        }
    }

    private var emptyCard: some View {
        LooprCard {
            HStack(alignment: .top, spacing: LooprSpacing.sm) {
                Image(systemName: "clock")
                    .looprTypography(.cardTitle)
                    .foregroundStyle(Color.loopr(.brand))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    Text("No chats yet")
                        .looprTypography(.rowTitle)
                        .foregroundStyle(Color.loopr(.ink))
                    Text("Chats you start in Ask show up here.")
                        .looprTypography(.prose)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        .accessibilityIdentifier("coach-history-empty")
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: LooprSpacing.xxs, leading: LooprSpacing.screenGutter, bottom: LooprSpacing.xxs, trailing: LooprSpacing.screenGutter))
    }

    private func actionRow(_ title: String, symbol: String, id: String, disabled: Bool = false, showsChevron: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: LooprSpacing.sm) {
                Image(systemName: symbol)
                    .looprTypography(.rowTitle)
                    .foregroundStyle(Color.loopr(disabled ? .inkSecondary : .brandInk))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(title)
                    .looprTypography(.rowTitle)
                    .foregroundStyle(Color.loopr(disabled ? .inkSecondary : .ink))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: LooprSpacing.xs)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, LooprSpacing.compactCardHorizontal)
            .padding(.vertical, LooprSpacing.compactCardVertical)
            .looprCardBackground(.standard, density: .compact)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableCard)
        .disabled(disabled)
        .accessibilityIdentifier(id)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: LooprSpacing.xxs, leading: LooprSpacing.screenGutter, bottom: LooprSpacing.xxs, trailing: LooprSpacing.screenGutter))
    }

    /// The last reply as one plain line, so two chats with the same first question can be told apart.
    private static func preview(of chat: CoachConversation) -> String? {
        guard let reply = chat.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty }) else { return nil }
        let plain = CoachMarkdownParser.plainText(CoachMarkdownParser.parse(reply.text))
        return plain.split(separator: "\n").first.map(String.init)
    }

    private func row(_ chat: CoachConversation) -> some View {
        let isCurrent = chat.id == model.conversation?.id
        return Button { open(chat) } label: {
            HStack(alignment: .center, spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    Text(chat.title)
                        .looprTypography(.rowTitle)
                        .foregroundStyle(Color.loopr(.ink))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let preview = Self.preview(of: chat) {
                        Text(preview)
                            .looprTypography(.prose)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .lineLimit(1)
                    }
                    HStack(spacing: LooprSpacing.xs) {
                        Text("\(chat.configuration.provider.name) · \(chat.updatedAt.formatted(date: .omitted, time: .shortened))")
                            .looprTypography(.caption)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                        if chat.isBriefing { StatusChip("Briefing", symbol: "sun.max", tone: .brand) }
                    }
                }
                Spacer(minLength: LooprSpacing.xs)
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.loopr(.brand))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, LooprSpacing.compactCardHorizontal)
            .padding(.vertical, LooprSpacing.compactCardVertical)
            .looprCardBackground(.standard, density: .compact)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableCard)
        .accessibilityValue(isCurrent ? "Current chat" : "")
        .accessibilityIdentifier("coach-history-row")
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: LooprSpacing.xxs, leading: LooprSpacing.screenGutter, bottom: LooprSpacing.xxs, trailing: LooprSpacing.screenGutter))
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { pendingDelete = chat }
        }
        .contextMenu {
            Button("Delete chat", systemImage: "trash", role: .destructive) { pendingDelete = chat }
        }
    }
}
