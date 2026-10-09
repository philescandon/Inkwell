// NoteAnchorResolver.swift — pure functions that locate a note's paragraph in the current text,
// and build a fresh anchor from a cursor/selection. Fallback order: exact snippet → fuzzy prefix
// (first 30 chars, case/diacritic-insensitive) → heading path → offset (only if the paragraph
// there still shares a word with the snippet). Anything else is "orphaned".
// Designed and Architected by: Phillip Escandon
import Foundation

enum AnchorMethod: String, Sendable {
    case exact, fuzzy, heading, offset
}

struct ResolvedAnchor: Equatable, Sendable {
    /// Range of the anchored paragraph (including its trailing newline, as NSString.paragraphRange returns).
    var paragraph: NSRange
    /// Exact quoted text if it still exists, else the snippet match, else the paragraph without its newline.
    var range: NSRange
    var method: AnchorMethod
}

/// Snapshot of a note's anchor fields, so resolution stays a pure function usable off the model layer.
struct NoteAnchor: Equatable, Sendable {
    var headingPath: [String]
    var snippet: String
    var characterOffset: Int
    var quotedText: String = ""
}

enum NoteAnchorResolver {
    static let snippetLength = 80
    static let fuzzyPrefixLength = 30

    // MARK: - Building

    /// Builds an anchor for `selection` (or the caret paragraph when empty) in `text`.
    static func makeAnchor(text: String, selection: NSRange) -> NoteAnchor {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let sel = NSIntersectionRange(selection, full)
        let paragraph = ns.length > 0 ? ns.paragraphRange(for: sel) : NSRange(location: 0, length: 0)
        let source = sel.length > 0 ? ns.substring(with: sel) : ns.substring(with: paragraph)
        let quoted = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = String(quoted.prefix(snippetLength))
        return NoteAnchor(headingPath: headingPath(in: text, at: paragraph.location),
                          snippet: snippet,
                          characterOffset: paragraph.location,
                          quotedText: quoted)
    }

    /// Nearest enclosing headings above `location`, outermost first (a stack keyed by level).
    static func headingPath(in text: String, at location: Int) -> [String] {
        var stack: [HeadingItem] = []
        for h in MarkdownAnalysis.headings(in: text) where h.id <= location {
            while let last = stack.last, last.level >= h.level { stack.removeLast() }
            stack.append(h)
        }
        return stack.map(\.title)
    }

    // MARK: - Resolving

    static func resolve(_ anchor: NoteAnchor, in text: String) -> ResolvedAnchor? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let full = NSRange(location: 0, length: ns.length)

        let snippet = anchor.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = anchor.quotedText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Prefer the full quote so the highlight covers exactly what the user selected; multi-paragraph
        // quotes anchor to the paragraph where they start.
        if quoted.count > snippet.count, let r = nearestMatch(of: quoted, in: ns, options: [], hint: anchor.characterOffset) {
            return ResolvedAnchor(paragraph: ns.paragraphRange(for: NSRange(location: r.location, length: 0)), range: r, method: .exact)
        }
        if !snippet.isEmpty {
            if let r = nearestMatch(of: snippet, in: ns, options: [], hint: anchor.characterOffset) {
                return ResolvedAnchor(paragraph: ns.paragraphRange(for: r), range: r, method: .exact)
            }
            let prefix = String(snippet.prefix(fuzzyPrefixLength)).trimmingCharacters(in: .whitespaces)
            if prefix.count >= 6,
               let r = nearestMatch(of: prefix, in: ns, options: [.caseInsensitive, .diacriticInsensitive], hint: anchor.characterOffset) {
                return ResolvedAnchor(paragraph: ns.paragraphRange(for: r), range: r, method: .fuzzy)
            }
        }

        if let loc = headingLocation(path: anchor.headingPath, in: text) {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            return ResolvedAnchor(paragraph: para, range: trimmedLine(para, ns), method: .heading)
        }

        // Offset is a hint only: accept it when the paragraph there still shares a word with the snippet.
        let offset = anchor.characterOffset
        if offset >= 0, offset < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: offset, length: 0))
            let there = ns.substring(with: para)
            if snippet.isEmpty || sharesWord(there, snippet) {
                let p = NSIntersectionRange(para, full)
                return ResolvedAnchor(paragraph: p, range: trimmedLine(p, ns), method: .offset)
            }
        }
        return nil
    }

    /// Paragraph range minus its trailing newline, so a highlight never spills onto the next line.
    private static func trimmedLine(_ para: NSRange, _ ns: NSString) -> NSRange {
        var r = para
        while r.length > 0, ns.character(at: NSMaxRange(r) - 1) == 0x0A || ns.character(at: NSMaxRange(r) - 1) == 0x0D { r.length -= 1 }
        return r
    }

    /// All occurrences of `needle`, choosing the one closest to `hint` so duplicated lines resolve sensibly.
    private static func nearestMatch(of needle: String, in ns: NSString, options: NSString.CompareOptions, hint: Int) -> NSRange? {
        var best: NSRange?
        var searchFrom = 0
        while searchFrom < ns.length {
            let r = ns.range(of: needle, options: options, range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            guard r.location != NSNotFound else { break }
            if let b = best {
                if abs(r.location - hint) < abs(b.location - hint) { best = r }
            } else {
                best = r
            }
            searchFrom = NSMaxRange(r)
        }
        return best
    }

    /// Location of the deepest heading whose path matches; partial matches walk as far as they can.
    private static func headingLocation(path: [String], in text: String) -> Int? {
        guard !path.isEmpty else { return nil }
        let headings = MarkdownAnalysis.headings(in: text)
        var index = 0
        var found: Int?
        for target in path {
            var matched = false
            while index < headings.count {
                let h = headings[index]
                index += 1
                if h.title.compare(target, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                    found = h.id
                    matched = true
                    break
                }
            }
            if !matched { break }
        }
        return found
    }

    private static func sharesWord(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 4 })
        }
        return !words(a).intersection(words(b)).isEmpty
    }
}
