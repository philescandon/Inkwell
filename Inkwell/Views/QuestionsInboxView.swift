// QuestionsInboxView.swift — global inbox of every note across documents. macOS: its own Window
// (Window > Questions, ⇧⌘Q). iPad: full-screen cover from the toolbar. Clicking a note resolves the
// file bookmark, opens the document, and posts a NoteNavigator request the document view consumes.
// Designed and Architected by: Phillip Escandon
import SwiftUI
import SwiftData

struct QuestionsInboxView: View {
    @Query(sort: \Note.createdAt, order: .reverse) private var notes: [Note]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openDocument) private var openDocument
    #else
    @Environment(\.openURL) private var openURL
    #endif

    @State private var status: NoteStatus? = .open
    @State private var tag: String? = nil
    @State private var search = ""
    @State private var openError: String?
    @State private var showExporter = false

    private var allTags: [String] { Array(Set(notes.flatMap(\.tags))).sorted() }

    private var filtered: [Note] {
        notes.filter { n in
            (status == nil || n.status == status)
            && (tag == nil || n.tags.contains(tag!))
            && (search.isEmpty
                || n.question.localizedCaseInsensitiveContains(search)
                || (n.answer ?? "").localizedCaseInsensitiveContains(search)
                || n.documentDisplayName.localizedCaseInsensitiveContains(search)
                || n.snippet.localizedCaseInsensitiveContains(search))
        }
    }

    /// Grouped by document key, ordered by display name; notes in document order.
    private var groups: [(key: String, name: String, notes: [Note])] {
        Dictionary(grouping: filtered, by: \.documentPath)
            .map { (key: $0.key, name: $0.value[0].documentDisplayName, notes: $0.value.sorted { $0.characterOffset < $1.characterOffset }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if groups.isEmpty {
                    ContentUnavailableView("No Questions", systemImage: "questionmark.bubble",
                                           description: Text("Add notes in a document with ⇧⌘N."))
                }
                ForEach(groups, id: \.key) { g in
                    Section(g.name) {
                        ForEach(g.notes, id: \.id) { note in
                            NoteRowView(note: note, orphaned: false, showDocument: false,
                                        onJump: { open(note) },
                                        onDelete: { context.delete(note); try? context.save() })
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search questions")
            .navigationTitle("Questions")
            .toolbar {
                ToolbarItemGroup {
                    Picker("Status", selection: $status) {
                        Text("All").tag(NoteStatus?.none)
                        ForEach(NoteStatus.allCases) { Text($0.label).tag(NoteStatus?.some($0)) }
                    }
                    Picker("Tag", selection: $tag) {
                        Text("Any tag").tag(String?.none)
                        ForEach(allTags, id: \.self) { Text("#\($0)").tag(String?.some($0)) }
                    }
                    Button { showExporter = true } label: { Label("Export All Questions…", systemImage: "square.and.arrow.up") }
                        .disabled(notes.isEmpty)
                    #if !os(macOS)
                    Button("Done") { dismiss() }
                    #endif
                }
            }
            .fileExporter(isPresented: $showExporter,
                          document: MarkdownExportDocument(text: NoteExport.allQuestions(notes)),
                          contentType: .markdownDocument, defaultFilename: "Questions") { _ in }
            .alert("Could Not Open", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
                Button("OK") {}
            } message: { Text(openError ?? "") }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 360)
        #endif
    }

    private func open(_ note: Note) {
        do {
            let url = try NoteStore.resolveBookmark(note.documentBookmark)
            NoteNavigator.shared.pending = .init(documentPath: NoteStore.documentKey(for: url), noteID: note.id)
            #if os(macOS)
            Task {
                do { try await openDocument(at: url) } catch { openError = error.localizedDescription }
            }
            #else
            openURL(url) { accepted in
                if !accepted { openError = "The system declined to open \(url.lastPathComponent)." }
            }
            dismiss()
            #endif
        } catch {
            openError = "The file for this note could not be located: \(error.localizedDescription)"
        }
    }
}
