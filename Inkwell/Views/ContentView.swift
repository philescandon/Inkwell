// ContentView.swift — one document window: sidebar (folder tree) | editor | optional outline, status bar below.
// NavigationSplitView collapses the sidebar automatically at iPad compact widths.
// Designed and Architected by: Phillip Escandon
import SwiftUI
import SwiftData

struct ContentView: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?

    @State private var controller = EditorController()
    @State private var folderStore = FolderBookmarkStore()
    @State private var stats = TextStats()
    @State private var headings: [HeadingItem] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showFolderPicker = false
    private var settings = EditorSettings.shared
    private var navigator = NoteNavigator.shared
    // All notes; filtered in memory (note counts are small and this keeps the panel reactive to inserts).
    @Query(sort: \Note.createdAt) private var allNotes: [Note]

    private var title: String { fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled" }
    private var documentKey: String? { fileURL.map(NoteStore.documentKey) }
    private var documentNotes: [Note] {
        guard let documentKey else { return [] }
        return allNotes.filter { $0.documentPath == documentKey }
    }
    /// Cheap identity for "did the note set change" — ids plus anchor fields plus status.
    private var notesFingerprint: [String] {
        documentNotes.map { "\($0.id)|\($0.snippet)|\($0.quotedText)|\($0.headingPath.joined(separator: "/"))|\($0.characterOffset)|\($0.statusRaw)|\($0.question)" }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(store: folderStore, showFolderPicker: $showFolderPicker)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    MarkdownEditor(text: $document.text,
                                   controller: controller,
                                   config: StyleConfig(fontSize: settings.fontSize, theme: settings.theme,
                                                       sourceMode: controller.sourceMode, focusMode: settings.focusMode),
                                   typewriter: settings.typewriterMode,
                                   markers: controller.markers,
                                   highlights: controller.highlights,
                                   flash: controller.flash)
                    if settings.showOutline {
                        Divider()
                        inspector.frame(width: 240)
                    }
                }
                Divider()
                StatusBarView(stats: stats, sourceMode: controller.sourceMode,
                              typewriter: settings.typewriterMode, focus: settings.focusMode)
            }
            .background(Color(settings.theme.background))
        }
        .navigationTitle(title)
        .focusedSceneValue(\.editorController, controller)
        .focusedSceneValue(\.documentTitle, title)
        .preferredColorScheme(settings.theme.colorScheme)
        .toolbar { toolbarContent }
        .task(id: document.text) { recompute() }
        .task(id: fileURL) { controller.fileURL = fileURL; resolveNotes() }
        .onChange(of: notesFingerprint) { resolveNotes() }
        .onChange(of: navigator.pending) { consumeNavigation() }
        .onChange(of: controller.revealParagraph) { if controller.revealParagraph != nil { controller.inspectorTab = .notes } }
        .sheet(isPresented: $controller.showAddNote) {
            if let anchor = controller.pendingAnchor {
                AddNoteSheet(anchor: anchor, fileURL: fileURL) { note in
                    // Select the new note: clears any paragraph filter left by "Show Notes" and scrolls
                    // the panel to the row, so an added note is never hidden below the fold or by a filter.
                    controller.revealNote(id: note.id)
                }
            }
        }
        #if !os(macOS)
        .fullScreenCover(isPresented: $controller.showQuestionsInbox) { QuestionsInboxView() }
        #endif
        .fileExporter(isPresented: $controller.showNotesExporter,
                      document: MarkdownExportDocument(text: NoteExport.inline(text: document.text, notes: documentNotes, anchors: controller.anchors)),
                      contentType: .markdownDocument, defaultFilename: title + " (notes)") { _ in }
        .fileExporter(isPresented: $controller.showAllQuestionsExporter,
                      document: MarkdownExportDocument(text: NoteExport.allQuestions(allNotes)),
                      contentType: .markdownDocument, defaultFilename: "Questions") { _ in }
        .alert("Notes", isPresented: Binding(get: { controller.noteError != nil }, set: { if !$0 { controller.noteError = nil } })) {
            Button("OK") {}
        } message: { Text(controller.noteError ?? "") }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { folderStore.choose(url) }
        }
        .sheet(isPresented: $controller.showPreview) {
            HTMLPreviewView(html: controller.html(title: title, scripts: .bundled))
        }
        .sheet(isPresented: $controller.showAbout) { AboutView() }
        .sheet(isPresented: $controller.showSettings) { SettingsView() }
        .fileExporter(isPresented: $controller.showExporter,
                      document: HTMLExportDocument(html: controller.html(title: title)),
                      contentType: .html, defaultFilename: title) { _ in }
    }

    private func recompute() {
        // Runs on the main actor after each text change; both passes are linear and cheap for typical notes.
        stats = MarkdownAnalysis.stats(for: document.text)
        headings = MarkdownAnalysis.headings(in: document.text)
        resolveNotes()
    }

    /// Re-anchors notes on every text change so margin dots track their paragraphs while typing.
    /// Uses the document text rather than the text view so the first pass works before the view attaches.
    private func resolveNotes() {
        controller.resolveNotes(documentNotes, text: document.text)
        consumeNavigation()
    }

    /// Fulfils a jump request from the Questions inbox once this document's anchors are known.
    private func consumeNavigation() {
        guard let req = navigator.pending, req.documentPath == documentKey else { return }
        navigator.pending = nil
        controller.inspectorTab = .notes
        settings.showOutline = true
        if let note = documentNotes.first(where: { $0.id == req.noteID }) {
            if let r = controller.anchors[note.id] {
                controller.select(note: note)
            } else {
                controller.revealParagraph = nil
                controller.noteError = "This note is orphaned: its anchor text was not found in the document."
            }
        }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: Bindable(controller).inspectorTab) {
                Text("Outline").tag(EditorController.InspectorTab.outline)
                Text(documentNotes.isEmpty ? "Notes" : "Notes (\(documentNotes.count))").tag(EditorController.InspectorTab.notes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            switch controller.inspectorTab {
            case .outline:
                OutlineView(headings: headings) { controller.jump(to: $0.id) }
            case .notes:
                NotesPanelView(notes: documentNotes, controller: controller)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button { controller.sourceMode.toggle() } label: {
                Label("Source", systemImage: controller.sourceMode ? "doc.plaintext.fill" : "doc.plaintext")
            }.help("Toggle source mode (⌘/)")
            Button { settings.showOutline.toggle() } label: {
                Label("Outline", systemImage: "list.bullet.indent")
            }.help("Toggle inspector")
            Button { controller.beginAddNote() } label: {
                Label("Add Note", systemImage: "text.bubble")
            }.help("Add a note or question (⇧⌘N)").disabled(fileURL == nil)
            #if !os(macOS)
            Button { controller.showQuestionsInbox = true } label: {
                Label("Questions", systemImage: "questionmark.bubble")
            }.help("All questions")
            #endif
            Button { controller.showPreview = true } label: {
                Label("Preview", systemImage: "eye")
            }.help("HTML preview (⇧⌘P)")
            #if !os(macOS)
            Menu {
                Button("Settings…") { controller.showSettings = true }
                Button("About Inkwell") { controller.showAbout = true }
            } label: { Label("More", systemImage: "ellipsis.circle") }
            #endif
        }
    }
}
