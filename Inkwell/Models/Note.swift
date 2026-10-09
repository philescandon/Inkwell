// Note.swift — SwiftData model for a question/note anchored to a paragraph in a markdown file.
// The anchor is intentionally redundant (snippet + heading path + offset) so notes survive edits:
// see NoteAnchorResolver for the fallback order.
// Designed and Architected by: Phillip Escandon
import Foundation
import SwiftData

enum NoteStatus: String, CaseIterable, Codable, Sendable, Identifiable {
    case open, answered, dropped

    var id: String { rawValue }

    var label: String {
        switch self {
        case .open: "Open"
        case .answered: "Answered"
        case .dropped: "Dropped"
        }
    }

    var systemImage: String {
        switch self {
        case .open: "questionmark.circle"
        case .answered: "checkmark.circle.fill"
        case .dropped: "xmark.circle"
        }
    }
}

@Model
final class Note {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var question: String
    var answer: String?
    /// Stored as the raw string; SwiftData enum columns are fine but a String keeps migrations trivial.
    var statusRaw: String
    var tags: [String]

    // Anchor
    var documentBookmark: Data
    var documentDisplayName: String
    /// Standardized file path, used as the grouping/matching key. The bookmark is what we resolve to open.
    var documentPath: String
    var headingPath: [String]
    var snippet: String
    var characterOffset: Int
    /// Full text the user had selected when the note was created (the snippet is the 80-char anchor key).
    /// Defaulted so stores written before this field existed migrate lightweight; see `displayQuote`.
    var quotedText: String = ""

    init(question: String,
         documentBookmark: Data,
         documentDisplayName: String,
         documentPath: String,
         headingPath: [String],
         snippet: String,
         characterOffset: Int,
         quotedText: String = "",
         tags: [String] = []) {
        self.id = UUID()
        self.createdAt = .now
        self.updatedAt = .now
        self.question = question
        self.answer = nil
        self.statusRaw = NoteStatus.open.rawValue
        self.tags = tags
        self.documentBookmark = documentBookmark
        self.documentDisplayName = documentDisplayName
        self.documentPath = documentPath
        self.headingPath = headingPath
        self.snippet = snippet
        self.characterOffset = characterOffset
        self.quotedText = quotedText
    }

    /// Text shown as the note's quote: the full selection, or the anchor snippet for pre-migration notes.
    var displayQuote: String { quotedText.isEmpty ? snippet : quotedText }

    var status: NoteStatus {
        get { NoteStatus(rawValue: statusRaw) ?? .open }
        set { statusRaw = newValue.rawValue; updatedAt = .now }
    }

    func touch() { updatedAt = .now }

    /// Parses a comma-separated tag string; used by the add sheet and inline editors.
    static func parseTags(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
