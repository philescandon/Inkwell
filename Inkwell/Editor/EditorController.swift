// EditorController.swift — per-document bridge between SwiftUI commands and the native text view.
// MVVM-light: it owns UI state (source mode, sheets) and performs edits; the document text stays
// the single source of truth via the binding in MarkdownEditor.
// Designed and Architected by: Phillip Escandon
import SwiftUI
import Observation

@MainActor
@Observable
final class EditorController {
    weak var textView: PlatformTextView?

    var sourceMode = false
    var showPreview = false
    var showExporter = false
    var showAbout = false
    var showSettings = false

    // MARK: Notes state
    enum InspectorTab: String, CaseIterable, Identifiable {
        case outline, notes
        var id: String { rawValue }
    }
    /// A one-shot request to briefly tint a range in the editor; `token` makes repeats distinguishable.
    struct FlashRequest: Equatable {
        var range: NSRange
        var token: Int
    }
    var inspectorTab: InspectorTab = .outline
    var showAddNote = false
    var showNotesExporter = false
    var showAllQuestionsExporter = false
    var showQuestionsInbox = false          // iPad full-screen inbox
    var noteError: String?
    /// Set by ContentView; nil for an unsaved document, which cannot be annotated (the anchor needs a bookmark).
    var fileURL: URL?
    /// Anchor captured when "Add Note…" was invoked, consumed by the sheet.
    var pendingAnchor: NoteAnchor?
    /// Paragraph the notes panel should focus on (set by "Show Notes" in the context menu).
    var revealParagraph: Int?
    /// Note the panel should select and scroll to (set by dot / highlight clicks).
    var selectedNoteID: UUID?
    /// Current resolution of this document's notes, keyed by Note.id. Missing key = orphaned.
    var anchors: [UUID: ResolvedAnchor] = [:]
    /// Per-document note numbers in creation order (1-based); shown in dots, badges, and panel rows.
    var noteNumbers: [UUID: Int] = [:]
    var markers: [NoteMarker] = []
    var highlights: [NoteHighlight] = []
    var flash: FlashRequest?
    private var flashCounter = 0

    var currentText: String { textView?.plainText ?? "" }

    /// Snapshot the selection/caret paragraph and open the question sheet.
    func beginAddNote() {
        guard let tv = textView else { return }
        guard fileURL != nil else {
            noteError = "Save the document first. Notes are linked to a file on disk, so an untitled document cannot be annotated yet."
            return
        }
        pendingAnchor = NoteAnchorResolver.makeAnchor(text: tv.plainText, selection: tv.primarySelectedRange)
        showAddNote = true
    }

    func revealNotes(atParagraph location: Int) {
        let ns = currentText as NSString
        let full = NSRange(location: 0, length: ns.length)
        let para = ns.length > 0 ? ns.paragraphRange(for: NSIntersectionRange(NSRange(location: location, length: 0), full)) : full
        selectedNoteID = nil
        revealParagraph = para.location
        inspectorTab = .notes
        EditorSettings.shared.showOutline = true
    }

    /// Dot or highlight click: open the inspector on this note and flash its quote.
    func revealNote(id: UUID) {
        revealParagraph = nil
        selectedNoteID = id
        inspectorTab = .notes
        EditorSettings.shared.showOutline = true
        if let r = anchors[id] { flashRange(r.range) }
    }

    /// Panel row selection: scroll the editor to the quote and flash it.
    func select(note: Note) {
        selectedNoteID = note.id
        guard let r = anchors[note.id] else { return }
        jump(to: r.range.location)
        flashRange(r.range)
    }

    private func flashRange(_ range: NSRange) {
        flashCounter += 1
        flash = FlashRequest(range: range, token: flashCounter)
    }

    /// Re-resolves every note against `text` (defaults to the live text view); updates markers and
    /// highlights for the layout manager and styler. `notes` must be in creation order.
    func resolveNotes(_ notes: [Note], text: String? = nil) {
        let text = text ?? currentText
        var resolved: [UUID: ResolvedAnchor] = [:]
        var numbers: [UUID: Int] = [:]
        for (i, n) in notes.enumerated() {
            numbers[n.id] = i + 1
            let anchor = NoteAnchor(headingPath: n.headingPath, snippet: n.snippet, characterOffset: n.characterOffset, quotedText: n.quotedText)
            if let r = NoteAnchorResolver.resolve(anchor, in: text) { resolved[n.id] = r }
        }
        anchors = resolved
        noteNumbers = numbers
        func summary(_ n: Note) -> String { "\(numbers[n.id]!) · \(n.question)" }

        // One dot per paragraph; open beats answered beats dropped so an unresolved question stays visible.
        var byParagraph: [Int: (status: NoteStatus, count: Int, number: Int, summary: String)] = [:]
        let rank: [NoteStatus: Int] = [.open: 0, .answered: 1, .dropped: 2]
        for n in notes {
            guard let r = resolved[n.id] else { continue }
            let cur = byParagraph[r.paragraph.location]
            let status = cur.map { rank[n.status]! < rank[$0.status]! ? n.status : $0.status } ?? n.status
            byParagraph[r.paragraph.location] = (status, (cur?.count ?? 0) + 1, cur?.number ?? numbers[n.id]!,
                                                 cur.map { $0.summary + "\n" + summary(n) } ?? summary(n))
        }
        let m = byParagraph.map { NoteMarker(location: $0.key, status: $0.value.status, count: $0.value.count,
                                             number: $0.value.number, summary: $0.value.summary) }
            .sorted { $0.location < $1.location }
        if m != markers { markers = m }
        let h = notes.compactMap { n in
            resolved[n.id].map { NoteHighlight(id: n.id, range: $0.range, status: n.status, number: numbers[n.id]!, summary: summary(n)) }
        }
        if h != highlights { highlights = h }
    }

    func jump(toNote note: Note) {
        guard let r = anchors[note.id] else { return }
        jump(to: r.range.location)
    }

    /// Context handed to AIProvider.answer: the anchored paragraph plus ~600 chars either side.
    func context(for note: Note) -> String {
        let ns = currentText as NSString
        guard let r = anchors[note.id] else { return note.snippet }
        let start = max(0, r.paragraph.location - 600)
        let end = min(ns.length, NSMaxRange(r.paragraph) + 600)
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    // MARK: - Formatting

    func toggleBold() { wrapSelection("**") }
    func toggleItalic() { wrapSelection("*") }
    func toggleCode() { wrapSelection("`") }
    func toggleStrike() { wrapSelection("~~") }

    func insertLink() {
        guard let tv = textView else { return }
        let sel = tv.primarySelectedRange
        let ns = tv.plainText as NSString
        let label = sel.length > 0 ? ns.substring(with: sel) : "link text"
        let replacement = "[\(label)](url)"
        tv.replaceUndoable(sel, with: replacement)
        // Select "url" so the user can type the destination immediately.
        tv.setSelection(NSRange(location: sel.location + label.utf16.count + 3, length: 3))
    }

    /// Wraps the selection in `marker`, or unwraps if already wrapped. With no selection, inserts a pair and places the caret inside.
    func wrapSelection(_ marker: String) {
        guard let tv = textView else { return }
        let sel = tv.primarySelectedRange
        let ns = tv.plainText as NSString
        let mlen = marker.utf16.count
        let selected = ns.substring(with: sel)

        if selected.hasPrefix(marker), selected.hasSuffix(marker), selected.utf16.count >= mlen * 2 {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            tv.replaceUndoable(sel, with: inner)
            tv.setSelection(NSRange(location: sel.location, length: inner.utf16.count))
            return
        }
        // Unwrap when the markers sit just outside the selection.
        let outer = NSRange(location: sel.location - mlen, length: sel.length + mlen * 2)
        if outer.location >= 0, NSMaxRange(outer) <= ns.length,
           ns.substring(with: NSRange(location: outer.location, length: mlen)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(sel), length: mlen)) == marker {
            tv.replaceUndoable(outer, with: selected)
            tv.setSelection(NSRange(location: outer.location, length: sel.length))
            return
        }
        tv.replaceUndoable(sel, with: marker + selected + marker)
        tv.setSelection(NSRange(location: sel.location + mlen, length: sel.length))
    }

    /// Sets heading level 1–6 on the current paragraph; 0 removes the heading prefix.
    func setHeading(level: Int) {
        guard let tv = textView else { return }
        let ns = tv.plainText as NSString
        let sel = tv.primarySelectedRange
        let para = ns.paragraphRange(for: sel)
        var line = ns.substring(with: para)
        let hadNewline = line.hasSuffix("\n")
        if hadNewline { line.removeLast() }
        let stripped = line.replacingOccurrences(of: #"^#{1,6}[ \t]+"#, with: "", options: .regularExpression)
        let prefix = level > 0 ? String(repeating: "#", count: level) + " " : ""
        let newLine = prefix + stripped + (hadNewline ? "\n" : "")
        tv.replaceUndoable(para, with: newLine)
        tv.setSelection(NSRange(location: para.location + newLine.utf16.count - (hadNewline ? 1 : 0), length: 0))
    }

    func insertTableOfContents() {
        guard let tv = textView else { return }
        let toc = MarkdownAnalysis.tableOfContents(for: tv.plainText)
        guard !toc.isEmpty else { return }
        let sel = tv.primarySelectedRange
        tv.replaceUndoable(sel, with: toc)
        tv.setSelection(NSRange(location: sel.location + toc.utf16.count, length: 0))
    }

    // MARK: - Navigation

    func jump(to location: Int) {
        guard let tv = textView else { return }
        let ns = tv.plainText as NSString
        guard location <= ns.length else { return }
        tv.setSelection(NSRange(location: location, length: 0))
        #if os(macOS)
        tv.window?.makeFirstResponder(tv)
        #else
        tv.becomeFirstResponder()
        #endif
    }

    // MARK: - Export

    /// `scripts: .bundled` for the in-app WKWebView (sandbox has no network access, so the mermaid runtime
    /// must travel with the page); `.cdn` for exported/copied HTML so the file stays small.
    func html(title: String, scripts: MarkdownHTML.ScriptSource = .cdn) -> String {
        let theme = EditorSettings.shared.theme
        return MarkdownHTML.document(from: currentText, title: title, css: theme.css,
                                     scripts: scripts, mermaidTheme: theme.mermaidTheme)
    }

    func copyAsHTML(title: String) {
        let html = html(title: title)
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(html, forType: .html)
        pb.setString(html, forType: .string)
        #else
        UIPasteboard.general.string = html
        #endif
    }
}

// FocusedValue plumbing so app-level menus reach the frontmost document's controller.
extension FocusedValues {
    @Entry var editorController: EditorController?
    @Entry var documentTitle: String?
}
