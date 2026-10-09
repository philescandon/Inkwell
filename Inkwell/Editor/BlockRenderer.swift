// BlockRenderer.swift — Typora-style inline rendering of pipe tables and mermaid diagrams in the editor.
//
// Design: the text storage is never mutated (the 1:1 character/offset invariant stands). When the caret
// is outside a block, the styler makes the block's source invisible (clear color, near-zero line height)
// and gives the block's FIRST line a line height equal to the rendered content; the layout manager then
// paints the table or diagram over that line. Caret enters the block → source comes back, like Typora.
//
// This object is the shared state between the styler (which decides heights and which blocks are
// collapsed) and the layout manager (which draws). It caches table layouts and diagram bitmaps.
// Designed and Architected by: Phillip Escandon
import SwiftUI

/// One collapsed (rendered) block, published by the styler after each restyle.
struct RenderedBlock: Equatable {
    enum Kind: Equatable { case table, mermaid }
    var range: NSRange        // whole block incl. fence lines / all rows
    var kind: Kind
    var payload: String       // mermaid source, or table rows joined by "\n"
    var height: CGFloat
}

@MainActor
final class BlockRenderer {
    nonisolated static let padding: CGFloat = 8
    nonisolated static let cellPadX: CGFloat = 10
    nonisolated static let cellPadY: CGFloat = 6

    /// Width available for rendered content (text container width minus the gutter), set by the editor.
    var width: CGFloat = 0
    var theme: EditorTheme = .light
    var fontSize: CGFloat = 16
    /// Blocks currently collapsed, as of the last restyle. Read by the layout manager.
    var blocks: [RenderedBlock] = []
    /// Fired when an async diagram finishes so the host can restyle (heights change). Debounced by caller.
    var onDiagramReady: (() -> Void)?
    /// The editor view; the offscreen mermaid web view is parked inside it (see MermaidRenderer).
    weak var hostView: PlatformView?

    private var mermaid: MermaidRenderer?
    private var diagrams: [String: MermaidRenderer.Result] = [:]
    private var diagramErrors: [String: String] = [:]
    private var inFlight: Set<String> = []
    private var tableCache: [String: TableLayout] = [:]

    /// Fallback width before the first layout pass so heights are not zero.
    private var layoutWidth: CGFloat { width > 40 ? width : 600 }

    // MARK: - Tables

    struct TableLayout {
        var columns: [CGFloat]
        var rowHeights: [CGFloat]
        var cells: [[NSAttributedString]]   // [row][col], row 0 = header
        var aligns: [NSTextAlignment]
        var height: CGFloat { rowHeights.reduce(0, +) + BlockRenderer.padding * 2 }
        var tableWidth: CGFloat { columns.reduce(0, +) }
    }

    static func tableKey(_ rows: [String], width: CGFloat, theme: EditorTheme, size: CGFloat) -> String {
        "\(Int(width))|\(theme.rawValue)|\(size)|" + rows.joined(separator: "\n")
    }

    func tableLayout(rows: [String]) -> TableLayout {
        let key = Self.tableKey(rows, width: layoutWidth, theme: theme, size: fontSize)
        if let cached = tableCache[key] { return cached }
        let layout = buildTable(rows: rows)
        if tableCache.count > 200 { tableCache.removeAll() }
        tableCache[key] = layout
        return layout
    }

    private func buildTable(rows: [String]) -> TableLayout {
        let parsed = rows.map { MarkdownHTML.tableCells($0) ?? [] }
        guard parsed.count >= 2 else { return TableLayout(columns: [], rowHeights: [], cells: [], aligns: []) }
        let n = parsed[0].count
        let aligns: [NSTextAlignment] = parsed[1].map { c in
            switch (c.hasPrefix(":"), c.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .right
            default: .left
            }
        } + Array(repeating: .left, count: max(0, n - parsed[1].count))
        // Row 1 is the delimiter row: skip it. Pad/truncate every row to the header's column count (GFM).
        var cells: [[NSAttributedString]] = []
        for (ri, raw) in parsed.enumerated() where ri != 1 {
            var r = raw.prefix(n).map { $0 }
            if r.count < n { r += Array(repeating: "", count: n - r.count) }
            let font = FontKit.font(size: fontSize * 0.92, bold: ri == 0)
            cells.append(r.map { InlineAttributed.make($0, font: font, theme: theme) })
        }
        // Natural (single-line) width per column, then shrink proportionally if the table is too wide.
        let avail = layoutWidth - Self.padding * 2
        var natural = [CGFloat](repeating: 0, count: n)
        for row in cells { for (ci, c) in row.enumerated() { natural[ci] = max(natural[ci], ceil(c.size().width) + Self.cellPadX * 2) } }
        let total = natural.reduce(0, +)
        var columns = natural
        if total > avail {
            let minW: CGFloat = 56
            // Shrink only the columns that have room, so narrow columns don't collapse below their content.
            var remaining = avail, flexible = natural.indices.map { $0 }
            while true {
                let flexTotal = flexible.reduce(0) { $0 + natural[$1] }
                let scale = max(0, (remaining - CGFloat(n - flexible.count) * minW)) / max(flexTotal, 1)
                let pinned = flexible.filter { natural[$0] * scale < minW }
                if pinned.isEmpty || flexible.count == pinned.count {
                    for i in flexible { columns[i] = max(minW, natural[i] * scale) }
                    break
                }
                for i in pinned { columns[i] = minW; flexible.removeAll { $0 == i } }
                remaining = avail
            }
        } else {
            // Stretch to the full width (Typora-style) in proportion to natural widths.
            let extra = avail - total
            columns = natural.map { $0 + extra * ($0 / max(total, 1)) }
        }
        var rowHeights: [CGFloat] = []
        for row in cells {
            var h: CGFloat = 0
            for (ci, c) in row.enumerated() {
                let box = c.boundingRect(with: CGSize(width: columns[ci] - Self.cellPadX * 2, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                h = max(h, ceil(box.height))
            }
            rowHeights.append(h + Self.cellPadY * 2)
        }
        return TableLayout(columns: columns, rowHeights: rowHeights, cells: cells, aligns: aligns)
    }

    func drawTable(_ layout: TableLayout, in rect: CGRect) {
        guard !layout.columns.isEmpty, let ctx = currentContext else { return }
        let x0 = rect.minX + Self.padding, y0 = rect.minY + Self.padding
        let w = layout.tableWidth
        // Header fill + zebra rows.
        var y = y0
        for (ri, rh) in layout.rowHeights.enumerated() {
            if ri == 0 || ri % 2 == 0 {
                ctx.setFillColor((ri == 0 ? theme.codeBackground : theme.codeBackground.withAlphaComponent(0.45)).cgColor)
                ctx.fill(CGRect(x: x0, y: y, width: w, height: rh))
            }
            y += rh
        }
        // Grid.
        ctx.setStrokeColor(theme.markerText.cgColor); ctx.setLineWidth(1)
        let totalH = layout.rowHeights.reduce(0, +)
        y = y0
        for rh in layout.rowHeights { ctx.move(to: CGPoint(x: x0, y: y + 0.5)); ctx.addLine(to: CGPoint(x: x0 + w, y: y + 0.5)); y += rh }
        ctx.move(to: CGPoint(x: x0, y: y + 0.5)); ctx.addLine(to: CGPoint(x: x0 + w, y: y + 0.5))
        var x = x0
        for cw in layout.columns { ctx.move(to: CGPoint(x: x + 0.5, y: y0)); ctx.addLine(to: CGPoint(x: x + 0.5, y: y0 + totalH)); x += cw }
        ctx.move(to: CGPoint(x: x + 0.5, y: y0)); ctx.addLine(to: CGPoint(x: x + 0.5, y: y0 + totalH))
        ctx.strokePath()
        // Text.
        y = y0
        for (ri, row) in layout.cells.enumerated() {
            x = x0
            for (ci, c) in row.enumerated() {
                let cell = CGRect(x: x + Self.cellPadX, y: y + Self.cellPadY,
                                  width: layout.columns[ci] - Self.cellPadX * 2, height: layout.rowHeights[ri] - Self.cellPadY * 2)
                let m = NSMutableAttributedString(attributedString: c)
                let ps = NSMutableParagraphStyle(); ps.alignment = layout.aligns[ci]; ps.lineBreakMode = .byWordWrapping
                m.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: m.length))
                m.draw(with: cell, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                x += layout.columns[ci]
            }
            y += layout.rowHeights[ri]
        }
    }

    // MARK: - Mermaid

    static func diagramKey(_ source: String, theme: EditorTheme) -> String { theme.rawValue + "|" + source }

    /// Height the block should occupy now. Kicks off a render the first time a source is seen.
    func diagramHeight(source: String) -> CGFloat {
        let key = Self.diagramKey(source, theme: theme)
        if let r = diagrams[key] { return fittedSize(r.size).height + Self.padding * 2 }
        if diagramErrors[key] != nil { return fontSize * 2.2 + Self.padding * 2 }
        requestRender(source: source, key: key)
        return fontSize * 2.2 + Self.padding * 2   // placeholder "Rendering…" strip
    }

    private func fittedSize(_ natural: CGSize) -> CGSize {
        let avail = layoutWidth - Self.padding * 2
        guard natural.width > avail, natural.width > 0 else { return natural }
        return CGSize(width: avail, height: natural.height * avail / natural.width)
    }

    private func requestRender(source: String, key: String) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        if mermaid == nil { mermaid = MermaidRenderer(host: hostView) }
        let renderer = mermaid!
        let theme = self.theme.mermaidTheme
        #if os(macOS)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        #else
        let scale = UIScreen.main.scale
        #endif
        Task { @MainActor in
            do {
                let r = try await renderer.render(source, theme: theme, scale: scale)
                diagrams[key] = r
            } catch {
                // WKError wraps the JS exception's message; keep the first line for the inline notice.
                let msg = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                diagramErrors[key] = msg.components(separatedBy: "\n").first ?? "Diagram error"
            }
            inFlight.remove(key)
            onDiagramReady?()
        }
    }

    func drawDiagram(source: String, in rect: CGRect) {
        let key = Self.diagramKey(source, theme: theme)
        let inner = rect.insetBy(dx: Self.padding, dy: Self.padding)
        if let r = diagrams[key] {
            let size = fittedSize(r.size)
            let origin = CGPoint(x: inner.minX + (inner.width - size.width) / 2, y: inner.minY)
            let target = CGRect(origin: origin, size: size)
            #if os(macOS)
            r.image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            #else
            r.image.draw(in: target)
            #endif
            return
        }
        let text = diagramErrors[key].map { "Mermaid: \($0)" } ?? "Rendering diagram…"
        let color: PlatformColor = diagramErrors[key] == nil ? theme.secondaryText : .systemRed
        let s = NSAttributedString(string: text, attributes: [.font: FontKit.font(size: fontSize * 0.9, italic: true), .foregroundColor: color])
        s.draw(with: CGRect(x: inner.minX, y: inner.minY + (inner.height - s.size().height) / 2, width: inner.width, height: s.size().height),
               options: [.usesLineFragmentOrigin], context: nil)
    }

    private var currentContext: CGContext? {
        #if os(macOS)
        NSGraphicsContext.current?.cgContext
        #else
        UIGraphicsGetCurrentContext()
        #endif
    }
}

/// Minimal inline markdown → attributed string for table cells (code, bold, italic, strike, links).
/// Markers are removed here, which is fine because a cell is drawn, never edited, in rendered mode.
enum InlineAttributed {
    @MainActor
    static func make(_ raw: String, font: PlatformFont, theme: EditorTheme) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func append(_ s: String, bold: Bool = false, italic: Bool = false, mono: Bool = false, strike: Bool = false, link: Bool = false) {
            var attrs: [NSAttributedString.Key: Any] = [.font: FontKit.derive(font, bold: bold ? true : nil, italic: italic ? true : nil, mono: mono ? true : nil,
                                                                            size: mono ? font.pointSize * 0.92 : nil),
                                                       .foregroundColor: link ? theme.accent : theme.text]
            if mono { attrs[.backgroundColor] = theme.codeBackground }
            if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if link { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: s, attributes: attrs))
        }
        // Tokenize: code spans are atomic; the rest goes through a small ordered marker scan.
        let pattern = #"`([^`]+)`|\*\*(.+?)\*\*|__(.+?)__|~~(.+?)~~|\[([^\]]+)\]\([^)]*\)|(?<![\w*])\*([^*\s][^*]*?)\*(?![\w*])|(?<![\w_])_([^_\s][^_]*?)_(?![\w_])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { append(raw); return out }
        let ns = raw as NSString
        var last = 0
        for m in re.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { append(ns.substring(with: NSRange(location: last, length: m.range.location - last))) }
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            if let s = g(1) { append(s, mono: true) }
            else if let s = g(2) ?? g(3) { append(s, bold: true) }
            else if let s = g(4) { append(s, strike: true) }
            else if let s = g(5) { append(s, link: true) }
            else if let s = g(6) ?? g(7) { append(s, italic: true) }
            last = NSMaxRange(m.range)
        }
        if last < ns.length { append(ns.substring(from: last)) }
        return out
    }
}
