import DesignSystem
import JournalKit
import SwiftUI
import UIKit

struct JournalNoteDraft: Identifiable {
    let entry: JournalEntry
    let dictate: Bool
    var id: UUID { entry.id }
}

struct JournalNoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dictation = CoachDictation()
    @State private var text: String
    @State private var tags: String
    @State private var saving = false
    @State private var errorMessage: String?
    private let draft: JournalNoteDraft
    private let onSave: @MainActor (JournalEntry) async throws -> Void

    init(draft: JournalNoteDraft, onSave: @escaping @MainActor (JournalEntry) async throws -> Void) {
        self.draft = draft; self.onSave = onSave
        _text = State(initialValue: draft.entry.note ?? "")
        _tags = State(initialValue: draft.entry.tags.union(draft.entry.behaviors).sorted().joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            LooprDetailScaffold {
                LooprCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprTextEditorRow(title: "Note", placeholder: "Write a note", text: $text,
                        minimumHeight: LooprSpacing.interactiveRowHeight * 3)
                        .accessibilityIdentifier("journal-note-input")
                    LooprTextFieldRow(title: "Tags", placeholder: "work, knee", text: $tags)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("journal-tags-input")
                    Button {
                        if dictation.recording { dictation.stop() } else { startDictation() }
                    } label: {
                        Label(dictation.recording ? "Stop dictation" : "Dictate", systemImage: dictation.recording ? "stop.fill" : "mic")
                    }
                    .buttonStyle(LooprButtonStyle(prominent: false))
                    .accessibilityIdentifier("journal-note-microphone")
                    }
                }
                .disabled(saving)
                if let issue = dictation.issue {
                    LooprCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        StateMessage(issue.isFailure ? .recoverableError : .partial, compact: true)
                        LooprText(issue.message, style: .prose, color: .inkSecondary)
                        if issue.needsSettings {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }.buttonStyle(LooprButtonStyle(prominent: false))
                                .accessibilityIdentifier("journal-dictation-settings")
                        }
                        }
                    }
                }
                if let errorMessage {
                    LooprCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            StateMessage(.recoverableError, compact: true)
                            LooprText(errorMessage, style: .prose, color: .inkSecondary)
                        }
                    }
                }
                Button(saving ? "Saving" : "Save note") {
                    dictation.stop()
                    saving = true
                    var entry = draft.entry
                    entry.note = text.isEmpty ? nil : text
                    entry.tags = Set(tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                    entry.behaviors = entry.tags
                    Task {
                        do { try await onSave(entry); dismiss() }
                        catch { errorMessage = "Could not save this note. \(error.localizedDescription)" }
                        saving = false
                    }
                }
                .buttonStyle(LooprButtonStyle())
                .disabled(saving)
                .accessibilityIdentifier("journal-save")
                LooprText("Dictation runs on this iPhone. Your note saves only when you tap Save note.", style: .prose, color: .inkSecondary)
            }
            .navigationTitle("Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving).accessibilityIdentifier("journal-note-cancel")
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journal-note-editor")
        .task { if draft.dictate { startDictation() } }
        .onDisappear { dictation.stop() }
    }

    private func startDictation() {
        let original = text
        Task { await dictation.start { text = original + (original.isEmpty ? "" : " ") + $0 } }
    }
}
