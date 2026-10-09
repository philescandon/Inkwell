// NotesPanelView.swift — inspector tab listing this document's notes. Inline editing writes straight to
// the SwiftData model; the parent re-resolves anchors when the note list changes.
// Designed and Architected by: Phillip Escandon
import SwiftUI
import SwiftData

struct NotesPanelView: View {
    let notes: [Note]                       // already filtered to this document
    let controller: EditorController
    @Environment(\.modelContext) private var context
    @State private var filter: NoteStatus? = nil

    private var revealSnippet: String? {
        guard let p = controller.revealParagraph else { return nil }
        let ns = controller.currentText as NSString
        guard p < ns.length else { return "" }
        let r = ns.paragraphRange(for: NSRange(location: p, length: 0))
        return String(ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }

    private var visible: [Note] {
        var list = notes
        if let filter { list = list.filter { $0.status == filter } }
        if let p = controller.revealParagraph {
            list = list.filter { controller.anchors[$0.id]?.paragraph.location == p }
        }
        // Document order, orphans last.
        return list.sorted {
            let a = controller.anchors[$0.id]?.paragraph.location ?? Int.max
            let b = controller.anchors[$1.id]?.paragraph.location ?? Int.max
            return a == b ? $0.createdAt < $1.createdAt : a < b
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Status", selection: $filter) {
                Text("All").tag(NoteStatus?.none)
                ForEach(NoteStatus.allCases) { Text($0.label).tag(NoteStatus?.some($0)) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .padding(8)

            if let snippet = revealSnippet {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(snippet.isEmpty ? "This paragraph" : "“\(snippet)”").lineLimit(1)
                    Spacer()
                    Button { controller.revealParagraph = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.bottom, 6)
            }

            ScrollViewReader { proxy in
                // Own selection tint via listRowBackground: system List selection paints the whole row
                // accent-blue and makes the secondary text unreadable.
                List {
                    if visible.isEmpty {
                        Text(notes.isEmpty ? "No notes. Press ⇧⌘N to add one." : "No matching notes.")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                    ForEach(visible, id: \.id) { note in
                        NoteRowView(note: note,
                                    number: controller.noteNumbers[note.id],
                                    orphaned: controller.anchors[note.id] == nil,
                                    context: { controller.context(for: note) },
                                    onJump: { controller.select(note: note) },
                                    onDelete: { delete(note) })
                            .id(note.id)
                            .listRowBackground(controller.selectedNoteID == note.id ? Color.accentColor.opacity(0.12) : Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: controller.selectedNoteID) {
                    guard let id = controller.selectedNoteID else { return }
                    // A status filter must not hide the note the user just added or clicked.
                    if let n = notes.first(where: { $0.id == id }), let filter, n.status != filter { self.filter = nil }
                    // Scroll after the row exists: the note may have been inserted in this same update.
                    Task { @MainActor in withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
                .onAppear {
                    if let id = controller.selectedNoteID { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func delete(_ note: Note) {
        context.delete(note)
        try? context.save()
    }
}

/// One note: editable question/answer, status, tags, jump, delete, and the (disabled) AI button.
struct NoteRowView: View {
    @Bindable var note: Note
    /// Per-document number; nil in the cross-document inbox.
    var number: Int? = nil
    var orphaned: Bool
    var showDocument = false
    var context: () -> String = { "" }
    var onJump: () -> Void
    var onDelete: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var aiBusy = false
    @State private var aiError: String?
    @State private var tagText = ""

    private var answerBinding: Binding<String> {
        Binding(get: { note.answer ?? "" }, set: { note.answer = $0.isEmpty ? nil : $0; note.touch() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ZStack {
                    Circle().fill(Color(note.status.markerColor))
                    if let number {
                        Text("\(number)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: number == nil ? 8 : 15, height: number == nil ? 8 : 15)
                if showDocument {
                    Text(note.documentDisplayName).font(.caption.bold()).lineLimit(1)
                }
                if orphaned {
                    Label("Orphaned", systemImage: "link.badge.plus")
                        .font(.caption2).foregroundStyle(.orange).labelStyle(.titleAndIcon)
                        .help("Anchor text not found; edit the document or delete the note.")
                }
                Spacer()
                Text(NoteExport.date(note.createdAt)).font(.caption2).foregroundStyle(.tertiary)
            }
            // Quote first: the text the note is about is what makes the note legible on its own.
            let quote = note.displayQuote
            if !quote.isEmpty {
                Text(quote)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(4)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(Color(note.status.markerColor)).frame(width: 3) }
            }
            TextField("Question", text: $note.question, axis: .vertical)
                .font(.subheadline.weight(.medium))
                .textFieldStyle(.plain)
                .onChange(of: note.question) { note.touch() }
            TextField("Answer…", text: answerBinding, axis: .vertical)
                .font(.caption)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
            if !note.headingPath.isEmpty {
                Text(note.headingPath.joined(separator: " › ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            TextField("tags", text: $tagText)
                .font(.caption2).textFieldStyle(.plain).foregroundStyle(.secondary)
                .onSubmit { note.tags = Note.parseTags(tagText); note.touch() }
            if let aiError { Text(aiError).font(.caption2).foregroundStyle(.red) }
            HStack(spacing: 10) {
                Button { onJump() } label: { Image(systemName: "arrow.right.circle") }
                    .help("Jump to anchor").disabled(orphaned)
                Menu {
                    ForEach(NoteStatus.allCases) { s in
                        Button { note.status = s } label: { Label(s.label, systemImage: s.systemImage) }
                    }
                } label: { Label(note.status.label, systemImage: note.status.systemImage).font(.caption) }
                    .menuStyle(.borderlessButton).fixedSize()
                Button { answerWithAI() } label: {
                    Label(aiBusy ? "Thinking…" : "Answer with AI", systemImage: "sparkles").font(.caption)
                }
                .disabled(!AIService.provider.isAvailable || aiBusy)
                .help(AIService.provider.isAvailable ? "Ask the AI provider" : "No AI provider configured")
                Spacer()
                Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                    .help("Delete note")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if !orphaned { onJump() } }
        .onAppear { tagText = note.tags.joined(separator: ", ") }
    }

    private func answerWithAI() {
        aiBusy = true
        aiError = nil
        let q = note.question
        let ctx = context()
        Task {
            do {
                let a = try await AIService.provider.answer(question: q, context: ctx)
                note.answer = a
                note.status = .answered
            } catch {
                aiError = error.localizedDescription
            }
            aiBusy = false
        }
    }
}
