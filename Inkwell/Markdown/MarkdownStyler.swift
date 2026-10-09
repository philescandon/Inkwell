// MarkdownStyler.swift — applies Typora-style visual attributes to an NSTextStorage whose
// string is raw markdown. Nothing here mutates characters; only attributes change.
//
// Performance design: callers pass an edited range; we expand it to paragraph boundaries and
// restyle only those paragraphs. The one global pass is a fence scan (``` lines) which is a
// cheap byLines enumeration; full restyles happen only when an edit touches a fence marker.
// Designed and Architected by: Phillip Escandon
import SwiftUI // re-exports AppKit/UIKit for NSTextStorage

struct StyleConfig: Equatable {
    var fontSize: CGFloat = 16
    var theme: EditorTheme = .light
    var sourceMode = false
    var focusMode = false
}

@MainActor
final class MarkdownStyler {
    var config = StyleConfig()
    /// Quoted ranges of this document's notes. Applied on every restyle (the base pass wipes attributes),
    /// so a highlight survives typing on its line. Set by the editor coordinator; see EditorController.
    var highlights: [NoteHighlight] = []

    // Regexes are instance lets (not statics) to stay on the main actor without Sendable gymnastics.
    private let headingRE = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+"#)
    private let quoteRE = try! NSRegularExpression(pattern: #"^[ \t]*>[ \t]?"#)
    private let listRE = try! NSRegularExpression(pattern: #"^[ \t]*(?:[-*+]|\d+[.)])[ \t]+(\[[ xX]\][ \t]+)?"#)
    private let hrRE = try! NSRegularExpression(pattern: #"^[ \t]*([-*_])[ \t]*(?:\1[ \t]*){2,}$"#)
    private let codeRE = try! NSRegularExpression(pattern: #"(`+)([^`\n]+?)\1"#)
    private let boldRE = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private let italicRE = try! NSRegularExpression(pattern: #"(?<![\w*_])(\*|_)(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![\w*_])"#)
    private let strikeRE = try! NSRegularExpression(pattern: #"(~~)(?=\S)(.+?)(?<=\S)\1"#)
    private let linkRE = try! NSRegularExpression(pattern: #"(!?\[)([^\]]*)(\]\([^)]*\))"#)

    private static let headingScale: [CGFloat] = [2.0, 1.6, 1.35, 1.2, 1.1, 1.0]

    // MARK: - Base attributes

    var bodyFont: PlatformFont {
        FontKit.font(size: config.fontSize, mono: config.sourceMode)
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = config.fontSize * 0.25
        ps.paragraphSpacing = config.fontSize * 0.6
        return [.font: bodyFont, .foregroundColor: config.theme.text, .paragraphStyle: ps]
    }

    // MARK: - Entry points

    func restyleAll(_ storage: NSTextStorage, cursor: NSRange?) {
        restyle(storage, editedRange: NSRange(location: 0, length: storage.length), cursor: cursor)
    }

    /// Restyles every paragraph intersecting `editedRange`. `cursor` decides which paragraph shows raw markers.
    func restyle(_ storage: NSTextStorage, editedRange: NSRange, cursor: NSRange?) {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        let full = NSRange(location: 0, length: ns.length)
        let target = ns.paragraphRange(for: NSIntersectionRange(editedRange, full))
        let cursorParagraph = cursor.map { ns.paragraphRange(for: NSIntersectionRange($0, full)) }

        storage.beginEditing()
        defer { storage.endEditing() }

        if config.sourceMode {
            storage.setAttributes(baseAttributes, range: target)
            applyHighlights(storage, in: target)
            return
        }

        let fences = fenceRanges(in: ns)
        ns.enumerateSubstrings(in: target, options: [.byParagraphs, .substringNotRequired]) { _, subRange, enclosing, _ in
            storage.setAttributes(self.baseAttributes, range: enclosing)
            let isCursorLine = cursorParagraph.map { NSIntersectionRange($0, enclosing).length > 0 || $0.location == enclosing.location } ?? false
            let inFence = fences.contains { NSIntersectionRange($0, enclosing).length > 0 }
            self.styleParagraph(storage, ns: ns, range: subRange, isCursorLine: isCursorLine, inFence: inFence)
            if self.config.focusMode && !isCursorLine {
                storage.addAttribute(.foregroundColor, value: self.config.theme.dimmedText, range: enclosing)
            }
            self.applyHighlights(storage, in: enclosing)
        }
    }

    /// Status-tinted background (and a hover tooltip on macOS) over each note's quoted range.
    private func applyHighlights(_ storage: NSTextStorage, in paragraph: NSRange) {
        guard !highlights.isEmpty else { return }
        let full = NSRange(location: 0, length: storage.length)
        for h in highlights {
            let r = NSIntersectionRange(NSIntersectionRange(h.range, paragraph), full)
            guard r.length > 0 else { continue }
            storage.addAttribute(.backgroundColor, value: h.status.highlightColor(for: config.theme), range: r)
            #if os(macOS)
            storage.addAttribute(.toolTip, value: h.summary, range: r)
            #endif
        }
    }

    // MARK: - Fences

    /// Ranges covered by ``` / ~~~ fenced blocks (including the fence lines).
    private func fenceRanges(in ns: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var open: Int?
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { line, _, enclosing, _ in
            guard let line, Self.isFence(line) else { return }
            if let s = open {
                result.append(NSRange(location: s, length: NSMaxRange(enclosing) - s)); open = nil
            } else {
                open = enclosing.location
            }
        }
        if let s = open { result.append(NSRange(location: s, length: ns.length - s)) }
        return result
    }

    static func isFence(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("```") || t.hasPrefix("~~~")
    }

    // MARK: - Paragraph styling

    private func styleParagraph(_ storage: NSTextStorage, ns: NSString, range: NSRange, isCursorLine: Bool, inFence: Bool) {
        guard range.length > 0 else { return }
        let line = ns.substring(with: range)
        let theme = config.theme

        if inFence {
            storage.addAttributes([.font: FontKit.font(size: config.fontSize * 0.9, mono: true),
                                   .backgroundColor: theme.codeBackground], range: range)
            if Self.isFence(line) { marker(storage, range, isCursorLine: isCursorLine) }
            return
        }

        var contentStart = 0

        if let m = headingRE.firstMatch(in: line, range: NSRange(location: 0, length: range.length)) {
            let level = m.range(at: 1).length
            let size = config.fontSize * Self.headingScale[level - 1]
            storage.addAttribute(.font, value: FontKit.font(size: size, bold: true), range: range)
            marker(storage, offset(m.range, range), isCursorLine: isCursorLine)
            contentStart = m.range.length
        } else if hrRE.firstMatch(in: line, range: NSRange(location: 0, length: range.length)) != nil {
            storage.addAttribute(.foregroundColor, value: theme.markerText, range: range)
            return
        } else if let m = quoteRE.firstMatch(in: line, range: NSRange(location: 0, length: range.length)) {
            storage.addAttributes([.font: FontKit.font(size: config.fontSize, italic: true),
                                   .foregroundColor: theme.secondaryText], range: range)
            // Quote bar is always visible in accent (Typora keeps a visual cue even off-line).
            storage.addAttribute(.foregroundColor, value: theme.accent, range: offset(m.range, range))
            contentStart = m.range.length
        } else if let m = listRE.firstMatch(in: line, range: NSRange(location: 0, length: range.length)) {
            storage.addAttribute(.foregroundColor, value: theme.accent, range: offset(m.range, range))
            contentStart = m.range.length
        }

        let content = NSRange(location: contentStart, length: range.length - contentStart)
        guard content.length > 0 else { return }
        styleInline(storage, line: line, lineRange: range, content: content, isCursorLine: isCursorLine)
    }

    private func styleInline(_ storage: NSTextStorage, line: String, lineRange: NSRange, content: NSRange, isCursorLine: Bool) {
        let theme = config.theme

        // Code spans first; remember them so emphasis regexes skip their interiors.
        var codeSpans: [NSRange] = []
        for m in codeRE.matches(in: line, range: content) {
            let whole = offset(m.range, lineRange)
            codeSpans.append(m.range)
            mutateFont(storage, whole) { FontKit.derive($0, mono: true, size: self.config.fontSize * 0.9) }
            storage.addAttribute(.backgroundColor, value: theme.codeBackground, range: whole)
            marker(storage, offset(m.range(at: 1), lineRange), isCursorLine: isCursorLine)
            let close = NSRange(location: NSMaxRange(m.range) - m.range(at: 1).length, length: m.range(at: 1).length)
            marker(storage, offset(close, lineRange), isCursorLine: isCursorLine)
        }
        func insideCode(_ r: NSRange) -> Bool { codeSpans.contains { NSIntersectionRange($0, r).length > 0 } }

        for m in boldRE.matches(in: line, range: content) where !insideCode(m.range) {
            mutateFont(storage, offset(m.range(at: 2), lineRange)) { FontKit.derive($0, bold: true) }
            emphasisMarkers(storage, m, lineRange: lineRange, isCursorLine: isCursorLine)
        }
        for m in italicRE.matches(in: line, range: content) where !insideCode(m.range) {
            mutateFont(storage, offset(m.range(at: 2), lineRange)) { FontKit.derive($0, italic: true) }
            emphasisMarkers(storage, m, lineRange: lineRange, isCursorLine: isCursorLine)
        }
        for m in strikeRE.matches(in: line, range: content) where !insideCode(m.range) {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: offset(m.range(at: 2), lineRange))
            emphasisMarkers(storage, m, lineRange: lineRange, isCursorLine: isCursorLine)
        }
        for m in linkRE.matches(in: line, range: content) where !insideCode(m.range) {
            storage.addAttributes([.foregroundColor: theme.accent, .underlineStyle: NSUnderlineStyle.single.rawValue],
                                  range: offset(m.range(at: 2), lineRange))
            marker(storage, offset(m.range(at: 1), lineRange), isCursorLine: isCursorLine)
            marker(storage, offset(m.range(at: 3), lineRange), isCursorLine: isCursorLine)
        }
    }

    // MARK: - Helpers

    private func emphasisMarkers(_ storage: NSTextStorage, _ m: NSTextCheckingResult, lineRange: NSRange, isCursorLine: Bool) {
        let len = m.range(at: 1).length
        marker(storage, offset(m.range(at: 1), lineRange), isCursorLine: isCursorLine)
        marker(storage, offset(NSRange(location: NSMaxRange(m.range) - len, length: len), lineRange), isCursorLine: isCursorLine)
    }

    /// Syntax markers: raw and readable on the cursor line, dimmed and shrunk elsewhere.
    /// We shrink rather than hide so character offsets stay 1:1 with the model and hit-testing works.
    private func marker(_ storage: NSTextStorage, _ range: NSRange, isCursorLine: Bool) {
        guard range.length > 0 else { return }
        if isCursorLine {
            storage.addAttribute(.foregroundColor, value: config.theme.secondaryText, range: range)
        } else {
            storage.addAttribute(.foregroundColor, value: config.theme.markerText, range: range)
            mutateFont(storage, range) { FontKit.derive($0, size: max(6, $0.pointSize * 0.55)) }
        }
    }

    private func mutateFont(_ storage: NSTextStorage, _ range: NSRange, _ transform: (PlatformFont) -> PlatformFont) {
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let f = (value as? PlatformFont) ?? bodyFont
            storage.addAttribute(.font, value: transform(f), range: sub)
        }
    }

    private func offset(_ r: NSRange, _ line: NSRange) -> NSRange {
        NSRange(location: line.location + r.location, length: r.length)
    }
}
