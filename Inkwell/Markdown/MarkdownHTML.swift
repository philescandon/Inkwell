// MarkdownHTML.swift — small dependency-free markdown → HTML converter for preview/export.
// Scope: headings, paragraphs, fenced code, blockquotes, lists (one nesting level via indent),
// hr, inline code/bold/italic/strike/links/images. Not a full CommonMark implementation.
// Designed and Architected by: Phillip Escandon
import Foundation

enum MarkdownHTML {
    static func document(from markdown: String, title: String, css: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>\(css)</style></head>
        <body>
        \(body(from: markdown))
        </body></html>
        """
    }

    static func body(from markdown: String) -> String {
        var out: [String] = []
        let lines = markdown.components(separatedBy: .newlines)
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !(lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") || lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("~~~")) {
                    code.append(lines[i]); i += 1
                }
                let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                out.append("<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>")
                i += 1
                continue
            }

            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            // Heading
            if let (level, text) = heading(trimmed) {
                flushParagraph()
                out.append("<h\(level) id=\"\(MarkdownAnalysis.slug(text))\">\(inline(text))</h\(level)>")
                i += 1; continue
            }

            // Horizontal rule
            if trimmed.range(of: #"^([-*_])\s*(\1\s*){2,}$"#, options: .regularExpression) != nil {
                flushParagraph(); out.append("<hr>"); i += 1; continue
            }

            // Blockquote: gather consecutive '>' lines and recurse
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var inner: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let l = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    inner.append(l.hasPrefix(" ") ? String(l.dropFirst()) : String(l))
                    i += 1
                }
                out.append("<blockquote>\(body(from: inner.joined(separator: "\n")))</blockquote>")
                continue
            }

            // Lists (unordered/ordered, one nesting level by 2+ space indent)
            if listItem(line) != nil {
                flushParagraph()
                out.append(renderList(lines, &i))
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return out.joined(separator: "\n")
    }

    // MARK: - Blocks

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
        return (hashes.count, text)
    }

    private struct ListLine { let indent: Int; let ordered: Bool; let text: String }

    private static func listItem(_ line: String) -> ListLine? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        if let r = rest.range(of: #"^([-*+])\s+"#, options: .regularExpression) {
            return ListLine(indent: indent, ordered: false, text: String(rest[r.upperBound...]))
        }
        if let r = rest.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            return ListLine(indent: indent, ordered: true, text: String(rest[r.upperBound...]))
        }
        return nil
    }

    private static func renderList(_ lines: [String], _ i: inout Int) -> String {
        guard let first = listItem(lines[i]) else { return "" }
        let baseIndent = first.indent
        let tag = first.ordered ? "ol" : "ul"
        var out = "<\(tag)>"
        while i < lines.count, let item = listItem(lines[i]), item.indent >= baseIndent {
            if item.indent > baseIndent {
                // Nested list: render recursively inside the previous <li>
                let nested = renderList(lines, &i)
                if out.hasSuffix("</li>") { out.removeLast(5); out += nested + "</li>" } else { out += "<li>" + nested + "</li>" }
                continue
            }
            let text = item.text
            // Task list checkbox
            if let r = text.range(of: #"^\[( |x|X)\]\s+"#, options: .regularExpression) {
                let checked = text[r].lowercased().contains("x")
                out += "<li><input type=\"checkbox\" disabled\(checked ? " checked" : "")> \(inline(String(text[r.upperBound...])))</li>"
            } else {
                out += "<li>\(inline(text))</li>"
            }
            i += 1
        }
        return out + "</\(tag)>"
    }

    // MARK: - Inline

    static func inline(_ raw: String) -> String {
        // Protect code spans first so markup inside backticks is not formatted.
        var codeSpans: [String] = []
        var s = replace(raw, #"`([^`]+)`"#) { m in
            codeSpans.append("<code>\(escape(m[1]))</code>")
            return "\u{0000}\(codeSpans.count - 1)\u{0000}"
        }
        s = escape(s)
        s = replace(s, #"!\[([^\]]*)\]\(([^)\s]+)\)"#) { "<img alt=\"\($0[1])\" src=\"\($0[2])\">" }
        s = replace(s, #"\[([^\]]+)\]\(([^)\s]+)\)"#) { "<a href=\"\($0[2])\">\($0[1])</a>" }
        s = replace(s, #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#) { "<strong>\($0[2])</strong>" }
        s = replace(s, #"(?<![\w*])(\*|_)(?=\S)(.+?)(?<=\S)\1(?![\w*])"#) { "<em>\($0[2])</em>" }
        s = replace(s, #"~~(?=\S)(.+?)(?<=\S)~~"#) { "<del>\($0[1])</del>" }
        s = replace(s, #"\u{0000}(\d+)\u{0000}"#) { codeSpans[Int($0[1]) ?? 0] }
        return s
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Regex replace with a closure receiving capture groups (index 0 = whole match).
    private static func replace(_ s: String, _ pattern: String, _ body: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String] = []
            for g in 0..<m.numberOfRanges {
                let r = m.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += body(groups)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
