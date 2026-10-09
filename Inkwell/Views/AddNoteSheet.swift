// AddNoteSheet.swift — "Add Note…" (⇧⌘N). Shows the captured anchor, takes a question and optional tags.
// Return saves. The anchor was snapshotted by EditorController.beginAddNote() before the sheet appeared,
// so the caret can move without affecting where the note lands.
// Designed and Architected by: Phillip Escandon
import SwiftUI
import SwiftData

struct AddNoteSheet: View {
    let anchor: NoteAnchor
    let fileURL: URL?
    /// Called with the saved note so the caller can select it in the panel.
    let onDone: (Note) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var tags = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Note").font(.headline)
            if !anchor.headingPath.isEmpty {
                Label(anchor.headingPath.joined(separator: " › "), systemImage: "number")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if !anchor.quotedText.isEmpty {
                // Read-only quote block: the exact text this note is about.
                ScrollView {
                    Text(anchor.quotedText)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
                .padding(10)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 3) }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            TextField("Question", text: $question)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
            TextField("Tags (comma separated)", text: $tags)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 420)
        .onAppear { focused = true }
    }

    private func save() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard let url = fileURL else {
            error = "Save the document first so the note can be linked to its file."
            return
        }
        do {
            let note = Note(question: q,
                            documentBookmark: try NoteStore.bookmark(for: url),
                            documentDisplayName: url.lastPathComponent,
                            documentPath: NoteStore.documentKey(for: url),
                            headingPath: anchor.headingPath,
                            snippet: anchor.snippet,
                            characterOffset: anchor.characterOffset,
                            quotedText: anchor.quotedText,
                            tags: Note.parseTags(tags))
            context.insert(note)
            try context.save()
            onDone(note)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
