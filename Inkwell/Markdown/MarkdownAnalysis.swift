// MarkdownAnalysis.swift — pure functions over the raw text: outline, stats, TOC.
// Designed and Architected by: Phillip Escandon
import Foundation

struct HeadingItem: Identifiable, Hashable, Sendable {
    let id: Int          // UTF-16 location of the heading line — stable enough for jump-to
    let level: Int
    let title: String
    var slug: String { MarkdownAnalysis.slug(title) }
}

struct TextStats: Sendable, Equatable {
    var words = 0
    var characters = 0
    var readingMinutes = 0

    var readingLabel: String { readingMinutes < 1 ? "< 1 min" : "\(readingMinutes) min" }
}

enum MarkdownAnalysis {
    static func headings(in text: String) -> [HeadingItem] {
        var items: [HeadingItem] = []
        let ns = text as NSString
        var inFence = false
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { line, range, _, _ in
            guard let line else { return }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); return }
            guard !inFence, trimmed.hasPrefix("#") else { return }
            let hashes = trimmed.prefix { $0 == "#" }
            let level = hashes.count
            let rest = trimmed.dropFirst(level)
            guard level <= 6, rest.first == " " || rest.first == "\t" else { return }
            let title = rest.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression) // closing hashes
            items.append(HeadingItem(id: range.location, level: level, title: title))
        }
        return items
    }

    static func stats(for text: String) -> TextStats {
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        // 200 wpm is the conventional reading-speed estimate.
        return TextStats(words: words, characters: text.count, readingMinutes: Int((Double(words) / 200.0).rounded(.up)))
    }

    /// GitHub-style anchor slug so TOC links match the exported HTML ids.
    static func slug(_ title: String) -> String {
        let lowered = title.lowercased()
        let allowed = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" }
        return String(String.UnicodeScalarView(allowed)).replacingOccurrences(of: " ", with: "-")
    }

    static func tableOfContents(for text: String) -> String {
        let hs = headings(in: text)
        guard !hs.isEmpty else { return "" }
        let minLevel = hs.map(\.level).min() ?? 1
        let lines = hs.map { h in
            String(repeating: "  ", count: h.level - minLevel) + "- [\(h.title)](#\(h.slug))"
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
