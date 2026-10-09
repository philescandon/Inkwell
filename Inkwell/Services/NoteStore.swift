// NoteStore.swift — SwiftData container for notes, document bookmark helpers, cross-window
// jump requests, and the two markdown export formats.
//
// Storage: a local store in ~/Library/Application Support/Inkwell/Notes.store (inside the sandbox
// container). CloudKit needs an iCloud container entitlement the project does not have, so the
// store is local only; see README.
// Designed and Architected by: Phillip Escandon
import Foundation
import SwiftData
import Observation

@MainActor
enum NoteStore {
    static let container: ModelContainer = {
        let schema = Schema([Note.self])
        do {
            let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
                .appendingPathComponent("Inkwell", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let config = ModelConfiguration("Notes", schema: schema, url: dir.appendingPathComponent("Notes.store"),
                                            cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Never block the editor on the notes database: fall back to memory and keep going.
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [memory])
        }
    }()

    /// Matching key for a document URL. Standardized so /private/var vs /var aliases compare equal.
    static func documentKey(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func bookmark(for url: URL) throws -> Data {
        #if os(macOS)
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    /// Resolves a stored bookmark and opens security-scoped access. Access is left open for the app's
    /// lifetime (same policy as FolderBookmarkStore) so the DocumentGroup can read the file afterwards.
    static func resolveBookmark(_ data: Data) throws -> URL {
        var stale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: data, relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        _ = url.startAccessingSecurityScopedResource()
        return url
    }
}

/// A jump request raised by the Questions inbox. The ContentView whose file matches `documentPath`
/// consumes it once its anchors have resolved (which may be after the document window opens).
@MainActor
@Observable
final class NoteNavigator {
    static let shared = NoteNavigator()

    struct Request: Equatable {
        var documentPath: String
        var noteID: UUID
    }

    var pending: Request?

    private init() {}
}

// MARK: - Export

enum NoteExport {
    /// FormatStyle is a value type, so it is Sendable-safe as a static (unlike ISO8601DateFormatter).
    static func date(_ d: Date) -> String { d.formatted(.iso8601.year().month().day()) }

    /// Inline export: `<!-- note[status] (date) re: "quoted text" — question — answer -->` after each resolved paragraph.
    /// Orphans go at the end under a comment so nothing is silently lost. Works on a copy of the text.
    static func inline(text: String, notes: [Note], anchors: [UUID: ResolvedAnchor]) -> String {
        let ns = NSMutableString(string: text)
        var orphans: [Note] = []
        // Insert bottom-up so earlier offsets stay valid.
        let resolved = notes.compactMap { n in anchors[n.id].map { (n, $0) } }
            .sorted { ($0.1.paragraph.location, $0.0.createdAt) > ($1.1.paragraph.location, $1.0.createdAt) }
        for (note, anchor) in resolved {
            var at = NSMaxRange(anchor.paragraph)
            var line = comment(for: note)
            // Paragraph without trailing newline (end of file): start the comment on its own line.
            if at > 0, ns.character(at: at - 1) != 0x0A { line = "\n" + line }
            if at > ns.length { at = ns.length }
            ns.insert(line + "\n", at: at)
        }
        orphans = notes.filter { anchors[$0.id] == nil }
        if !orphans.isEmpty {
            if ns.length > 0, ns.character(at: ns.length - 1) != 0x0A { ns.append("\n") }
            ns.append("\n<!-- orphaned notes -->\n")
            for n in orphans { ns.append(comment(for: n) + "\n") }
        }
        return ns as String
    }

    static func comment(for note: Note) -> String {
        var body = clean(note.question)
        if let a = note.answer, !a.trimmingCharacters(in: .whitespaces).isEmpty { body += " — " + clean(a) }
        let quote = clean(note.displayQuote).replacingOccurrences(of: "\"", with: "'")
        let re = quote.isEmpty ? "" : " re: \"\(quote)\""
        return "<!-- note[\(note.status.rawValue)] (\(date(note.createdAt)))\(re) — \(body) -->"
    }

    /// Single markdown file, grouped by document, one task-list item per note.
    static func allQuestions(_ notes: [Note]) -> String {
        var out = "# Questions\n\nExported \(date(.now)) from Inkwell.\n"
        let groups = Dictionary(grouping: notes, by: \.documentPath)
        for key in groups.keys.sorted(by: { groups[$0]!.first!.documentDisplayName.lowercased() < groups[$1]!.first!.documentDisplayName.lowercased() }) {
            let items = groups[key]!.sorted { $0.characterOffset < $1.characterOffset }
            out += "\n## \(items[0].documentDisplayName)\n\n"
            for n in items {
                let box = n.status == .open ? "[ ]" : "[x]"
                var where_ = n.documentDisplayName
                if !n.headingPath.isEmpty { where_ += " › " + n.headingPath.joined(separator: " › ") }
                var line = "- \(box) \(clean(n.question)) (\(where_))"
                if n.status == .dropped { line += " _(dropped)_" }
                let quote = clean(n.displayQuote)
                if !quote.isEmpty { line += "\n  > \(quote)" }
                if let a = n.answer, !a.trimmingCharacters(in: .whitespaces).isEmpty { line += "\n  - Answer: \(clean(a))" }
                if !n.tags.isEmpty { line += "\n  - Tags: " + n.tags.map { "#\($0)" }.joined(separator: " ") }
                out += line + "\n"
            }
        }
        return out
    }

    /// Collapses newlines and keeps HTML comments well-formed.
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "-->", with: "--\u{200B}>")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
