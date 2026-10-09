// MarkdownHTML.swift — small dependency-free markdown → HTML converter for preview/export.
// Scope: headings, paragraphs, fenced code, mermaid diagrams, GFM pipe tables, blockquotes,
// lists (one nesting level via indent), hr, inline code/bold/italic/strike/links/images.
// Not a full CommonMark implementation.
// Designed and Architected by: Phillip Escandon
import Foundation

enum MarkdownHTML {
    /// Pinned mermaid release. The same version is vendored at Resources/mermaid.min.js and referenced from the CDN
    /// on export, so a diagram renders identically in the in-app preview and in an exported file.
    static let mermaidVersion = "11.17.2"

    /// How the mermaid runtime reaches the page. The app sandbox carries no network entitlement, so the in-app
    /// preview must inline the bundled copy; an exported file is opened in a real browser and can use the CDN.
    enum ScriptSource {
        case bundled   // inline the vendored mermaid.min.js (~3.5 MB) into the document
        case cdn       // <script src="https://cdn.jsdelivr.net/npm/mermaid@…"> (needs a network connection when viewed)
    }

    static func document(from markdown: String, title: String, css: String,
                         scripts: ScriptSource = .cdn, mermaidTheme: String = "default") -> String {
        let html = body(from: markdown)
        // Only ship the runtime when the document actually has a diagram.
        let mermaid = html.contains("<pre class=\"mermaid\">") ? mermaidScripts(scripts, theme: mermaidTheme) : ""
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>\(css)</style></head>
        <body>
        \(html)
        \(mermaid)
        </body></html>
        """
    }

    private static func mermaidScripts(_ source: ScriptSource, theme: String) -> String {
        let runtime: String
        switch source {
        case .bundled:
            if let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
               let js = try? String(contentsOf: url, encoding: .utf8) {
                runtime = "<script>\(js)</script>"
            } else {
                // Resource missing from the bundle (misconfigured build): fall back to the CDN rather than show nothing.
                runtime = cdnTag
            }
        case .cdn:
            runtime = cdnTag
        }
        // `theme` is one of mermaid's built-in names (default/dark/neutral/forest), chosen from the editor theme.
        return runtime + "\n<script>mermaid.initialize({ startOnLoad: true, theme: \"\(escape(theme))\", securityLevel: \"strict\" });</script>"
    }

    private static var cdnTag: String {
        "<script src=\"https://cdn.jsdelivr.net/npm/mermaid@\(mermaidVersion)/dist/mermaid.min.js\"></script>"
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

            // Fenced code (``` or ~~~). A ```mermaid fence becomes a diagram container instead of a code block.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !(lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") || lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("~~~")) {
                    code.append(lines[i]); i += 1
                }
                let source = escape(code.joined(separator: "\n"))
                if lang.lowercased() == "mermaid" {
                    // Escaping is correct here: mermaid reads the element's textContent, so `&lt;br/&gt;` comes
                    // back as `<br/>` for the renderer while never being parsed as HTML by the page itself.
                    out.append("<pre class=\"mermaid\">\(source)</pre>")
                } else {
                    let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                    out.append("<pre><code\(cls)>\(source)</code></pre>")
                }
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

            // GFM table: a header row followed by a delimiter row with the same cell count.
            if i + 1 < lines.count, let table = renderTable(lines, &i) {
                flushParagraph()
                out.append(table)
                continue
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

    // MARK: Tables

    private enum Align { case none, left, center, right
        var attr: String {
            switch self { case .none: ""; case .left: " style=\"text-align:left\""; case .center: " style=\"text-align:center\""; case .right: " style=\"text-align:right\"" }
        }
    }

    /// Splits a pipe-table row into cells. Handles an optional leading/trailing pipe, `\|` escapes,
    /// and pipes inside backtick code spans (common in technical docs: `a|b`).
    static func tableCells(_ line: String) -> [String]? {
        var t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|") else { return nil }
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var cur = ""
        var inCode = false
        var escaped = false
        for ch in t {
            if escaped { cur.append(ch == "|" ? "|" : "\\\(ch)"); escaped = false; continue }
            switch ch {
            case "\\": escaped = true
            case "`": inCode.toggle(); cur.append(ch)
            case "|" where !inCode: cells.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            default: cur.append(ch)
            }
        }
        if escaped { cur.append("\\") }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// Delimiter row like `| --- | :---: | ---: |`. Returns per-column alignment, or nil if the line is not one.
    private static func delimiterAlignments(_ line: String) -> [Align]? {
        guard let cells = tableCells(line), !cells.isEmpty else { return nil }
        var result: [Align] = []
        for c in cells {
            guard c.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else { return nil }
            switch (c.hasPrefix(":"), c.hasSuffix(":")) {
            case (true, true): result.append(.center)
            case (true, false): result.append(.left)
            case (false, true): result.append(.right)
            default: result.append(.none)
            }
        }
        return result
    }

    /// Renders a table starting at `lines[i]` (header) if `lines[i+1]` is a matching delimiter row.
    /// Body rows run until a blank line or a line without a pipe. Short rows are padded, long rows truncated (GFM).
    private static func renderTable(_ lines: [String], _ i: inout Int) -> String? {
        guard let header = tableCells(lines[i]),
              let aligns = delimiterAlignments(lines[i + 1]),
              header.count == aligns.count else { return nil }
        let n = header.count
        var html = "<table>\n<thead><tr>"
        for (c, a) in zip(header, aligns) { html += "<th\(a.attr)>\(inline(c))</th>" }
        html += "</tr></thead>\n<tbody>\n"
        i += 2
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, var cells = tableCells(lines[i]) else { break }
            if cells.count < n { cells += Array(repeating: "", count: n - cells.count) }
            html += "<tr>"
            for (c, a) in zip(cells.prefix(n), aligns) { html += "<td\(a.attr)>\(inline(c))</td>" }
            html += "</tr>\n"
            i += 1
        }
        return html + "</tbody>\n</table>"
    }

    // MARK: Lists

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
        // ICU regex syntax: `\x{0}` is the NUL placeholder. (A raw string's `\u{0000}` is not an ICU escape, so the
        // pattern failed to compile and every code span used to leak its placeholder into the output.)
        s = replace(s, #"\x{0}(\d+)\x{0}"#) { codeSpans[Int($0[1]) ?? 0] }
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
