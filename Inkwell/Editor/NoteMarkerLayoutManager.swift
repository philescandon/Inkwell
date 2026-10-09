// NoteMarkerLayoutManager.swift — draws a numbered, status-colored dot in the left margin of every
// annotated paragraph, plus a small number badge at the start of each highlighted quote.
//
// Design decision: markers live in the layout manager, not in the text storage. The styler calls
// setAttributes() on every restyle, which would wipe a custom attribute; and a text attachment would
// shift character offsets, breaking the 1:1 model/offset invariant the editor relies on. The quote
// highlight itself IS a storage attribute (background color) because the styler owns it and re-applies
// it on every restyle; see MarkdownStyler.highlights.
//
// Both platforms build a manual TextKit 1 stack (NSTextStorage → this class → NSTextContainer) so the
// subclass is guaranteed to be the one drawing; macOS 15 otherwise defaults NSTextView to TextKit 2.
// Designed and Architected by: Phillip Escandon
import SwiftUI

struct NoteMarker: Equatable, Sendable {
    /// Paragraph start (UTF-16 offset).
    var location: Int
    var status: NoteStatus
    var count: Int
    /// Per-document number of the first note on this paragraph (creation order, 1-based).
    var number: Int
    /// Tooltip text: "1 · question".
    var summary: String
}

/// Exact quoted range of one note, applied by the styler as a tinted background and drawn here as a badge.
struct NoteHighlight: Equatable, Sendable {
    var id: UUID
    var range: NSRange
    var status: NoteStatus
    var number: Int
    var summary: String
}

extension NoteStatus {
    var markerColor: PlatformColor {
        switch self {
        case .open: PlatformColor.systemOrange
        case .answered: PlatformColor.systemGreen
        case .dropped: PlatformColor.systemGray
        }
    }

    /// Subtle, theme-aware background for the quoted range.
    func highlightColor(for theme: EditorTheme) -> PlatformColor {
        markerColor.withAlphaComponent(theme == .dark ? 0.30 : 0.20)
    }
}

final class NoteMarkerLayoutManager: NSLayoutManager {
    static let dotSize: CGFloat = 15
    /// Width of the gutter reserved inside the text container (via lineFragmentPadding). Drawing must stay
    /// inside the container: AppKit clips layout-manager background drawing to it, so a dot placed in the
    /// textContainerInset area is never visible.
    static let gutterWidth: CGFloat = 28
    /// Distance from the container's left edge to the dot's left edge.
    static let dotInset: CGFloat = 4

    /// Inline table/diagram renderer shared with the styler; `renderer.blocks` is what gets drawn.
    var renderer: BlockRenderer?
    /// Called with the width available to rendered blocks whenever the container is resized.
    var onContentWidthChange: ((CGFloat) -> Void)?

    override func textContainerChangedGeometry(_ container: NSTextContainer) {
        super.textContainerChangedGeometry(container)
        onContentWidthChange?(container.size.width - container.lineFragmentPadding * 2)
    }

    #if os(macOS)
    /// Spell-check squiggles are temporary attributes; drop them inside collapsed blocks so hidden source
    /// (mermaid keywords, table cells) does not leave red marks under a rendered diagram or table.
    override func addTemporaryAttribute(_ attrName: NSAttributedString.Key, value: Any, forCharacterRange charRange: NSRange) {
        if attrName == .spellingState, intersectsRenderedBlock(charRange) { return }
        super.addTemporaryAttribute(attrName, value: value, forCharacterRange: charRange)
    }

    override func addTemporaryAttributes(_ attrs: [NSAttributedString.Key: Any], forCharacterRange charRange: NSRange) {
        if attrs[.spellingState] != nil, intersectsRenderedBlock(charRange) { return }
        super.addTemporaryAttributes(attrs, forCharacterRange: charRange)
    }

    private func intersectsRenderedBlock(_ r: NSRange) -> Bool {
        guard let renderer else { return false }
        return MainActor.assumeIsolated { renderer.blocks.contains { NSIntersectionRange($0.range, r).length > 0 } }
    }
    #endif

    var markers: [NoteMarker] = [] {
        didSet { if markers != oldValue { redrawAll() } }
    }
    var highlights: [NoteHighlight] = [] {
        didSet { if highlights != oldValue { redrawAll() } }
    }

    /// Dots and badges are drawn outside the glyph rects (in the gutter / above the line), so
    /// invalidateDisplay(forCharacterRange:) alone leaves a newly added note's dot half-painted until
    /// something else redraws the view. Mark the whole text view dirty as well.
    private func redrawAll() {
        invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0))
        #if os(macOS)
        firstTextView?.needsDisplay = true
        #else
        hostView?.setNeedsDisplay()   // UIKit's NSLayoutManager has no firstTextView
        #endif
    }
    #if !os(macOS)
    /// The UITextView drawing this layout manager; set by MarkdownEditor.makeUIView.
    weak var hostView: UITextView?
    #endif

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        drawRenderedBlocks(intersecting: chars, at: origin)
        guard !(markers.isEmpty && highlights.isEmpty) else { return }

        for m in markers where m.location >= chars.location && m.location <= NSMaxRange(chars) {
            guard let line = lineRect(forCharacterAt: m.location, storageLength: storage.length) else { continue }
            let size = Self.dotSize
            let x = origin.x + Self.dotInset
            // Vertically centered on the first line's x-height region rather than the whole fragment.
            let y = origin.y + line.minY + (min(line.height, 28) - size) / 2 + 2
            let rect = CGRect(x: x, y: y, width: size, height: size)
            m.status.markerColor.setFill()
            fillOval(rect)
            let label = m.count > 1 ? "\(m.number)+" : "\(m.number)"
            drawLabel(label, in: rect, color: .white, size: m.count > 1 ? 7.5 : 9)
        }

        // Number badge just above the first character of each quote, dimmed so it reads as metadata.
        for h in highlights where h.range.length > 0 && NSIntersectionRange(h.range, chars).length > 0 {
            let glyph = glyphIndexForCharacter(at: h.range.location)
            guard glyph < numberOfGlyphs else { continue }
            let frag = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let gx = location(forGlyphAt: glyph).x
            let rect = CGRect(x: origin.x + frag.minX + gx - 2, y: origin.y + frag.minY - 1, width: 11, height: 11)
            h.status.markerColor.withAlphaComponent(0.55).setFill()
            fillOval(rect)
            drawLabel("\(h.number)", in: rect, color: .white, size: 7)
        }
    }

    private func fillOval(_ rect: CGRect) {
        #if os(macOS)
        NSBezierPath(ovalIn: rect).fill()
        #else
        UIBezierPath(ovalIn: rect).fill()
        #endif
    }

    private func drawLabel(_ text: String, in rect: CGRect, color: PlatformColor, size: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: PlatformFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: color]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        s.draw(at: CGPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
    }

    /// Line fragment for a character index, handling the empty trailing paragraph.
    func lineRect(forCharacterAt location: Int, storageLength: Int) -> CGRect? {
        if location >= storageLength {
            return extraLineFragmentRect == .zero ? nil : extraLineFragmentRect
        }
        let glyph = glyphIndexForCharacter(at: location)
        guard glyph < numberOfGlyphs else { return nil }
        return lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    /// Marker whose line contains the given y (in text-container coordinates).
    func marker(atContainerY y: CGFloat) -> NoteMarker? {
        guard let storage = textStorage else { return nil }
        return markers.first { m in
            guard let r = lineRect(forCharacterAt: m.location, storageLength: storage.length) else { return false }
            return y >= r.minY && y <= r.maxY
        }
    }

    /// Paints each collapsed table/diagram over the tall first line the styler gave its block.
    private func drawRenderedBlocks(intersecting chars: NSRange, at origin: CGPoint) {
        // NSLayoutManager draws on the main thread but is not actor-annotated; the renderer is.
        guard let renderer, let tc = textContainers.first else { return }
        let pad = tc.lineFragmentPadding
        // Geometry comes from the (nonisolated) layout manager; only the draw calls hop onto the renderer's actor.
        let blocks = MainActor.assumeIsolated { renderer.blocks }
        for b in blocks where NSIntersectionRange(b.range, chars).length > 0 {
            let glyph = glyphIndexForCharacter(at: b.range.location)
            guard glyph < numberOfGlyphs else { continue }
            let frag = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let rect = CGRect(x: origin.x + frag.minX + pad, y: origin.y + frag.minY, width: frag.width - pad * 2, height: b.height)
            MainActor.assumeIsolated {
                switch b.kind {
                case .table: renderer.drawTable(renderer.tableLayout(rows: b.payload.components(separatedBy: "\n")), in: rect)
                case .mermaid: renderer.drawDiagram(source: b.payload, in: rect)
                }
            }
        }
    }

    /// Highlight containing a character index, if any.
    func highlight(atCharacter index: Int) -> NoteHighlight? {
        highlights.first { NSLocationInRange(index, $0.range) }
    }

    /// Character index under a point in text-container coordinates, or nil when the point is past the text.
    func characterIndex(atContainerPoint p: CGPoint, in container: NSTextContainer) -> Int? {
        guard numberOfGlyphs > 0 else { return nil }
        var fraction: CGFloat = 0
        let idx = characterIndex(for: p, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        // Points in the empty area to the right of a line report the last glyph on the line; reject those.
        let glyph = glyphIndexForCharacter(at: idx)
        guard glyph < numberOfGlyphs else { return nil }
        let bounds = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return bounds.insetBy(dx: -2, dy: -2).contains(p) ? idx : nil
    }
}

#if os(macOS)
/// NSTextView subclass that hit-tests marker clicks in the margin, click-to-reveal on highlighted
/// quotes, hover tooltips on the gutter dots, and adds "Show Notes" to the context menu.
final class InkwellTextView: NSTextView {
    var onRevealNotes: ((Int) -> Void)?
    /// Called with the note id when a dot or a highlighted quote is clicked.
    var onRevealNote: ((UUID) -> Void)?

    private var markerLayoutManager: NoteMarkerLayoutManager? { layoutManager as? NoteMarkerLayoutManager }
    private var gutterToolTip: NSView.ToolTipTag?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        installGutterToolTip()
    }

    /// One tooltip rect over the whole gutter; the owner callback resolves which dot is under the pointer.
    private func installGutterToolTip() {
        if let t = gutterToolTip { removeToolTip(t) }
        let w = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        gutterToolTip = addToolTip(NSRect(x: 0, y: 0, width: w, height: bounds.height), owner: self, userData: nil)
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let lm = markerLayoutManager, let m = lm.marker(atContainerY: point.y - textContainerInset.height) else { return "" }
        return m.summary
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let lm = markerLayoutManager, let tc = textContainer {
            if p.x < textContainerInset.width + tc.lineFragmentPadding, let m = lm.marker(atContainerY: p.y - textContainerInset.height) {
                reveal(paragraph: m.location, lm: lm)
                return
            }
            // A plain single click inside a quote places the caret as usual and also surfaces the note.
            if event.clickCount == 1, !event.modifierFlags.contains(.shift),
               let idx = lm.characterIndex(atContainerPoint: CGPoint(x: p.x - textContainerInset.width, y: p.y - textContainerInset.height), in: tc),
               let h = lm.highlight(atCharacter: idx) {
                super.mouseDown(with: event)
                onRevealNote?(h.id)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func reveal(paragraph: Int, lm: NoteMarkerLayoutManager) {
        // Prefer the first note whose quote starts in this paragraph so the panel selects a specific note.
        let ns = string as NSString
        let full = NSRange(location: 0, length: ns.length)
        let para = ns.length > 0 ? ns.paragraphRange(for: NSIntersectionRange(NSRange(location: paragraph, length: 0), full)) : full
        if let h = lm.highlights.first(where: { NSLocationInRange($0.range.location, para) || $0.range.location == para.location }) {
            onRevealNote?(h.id)
        } else {
            onRevealNotes?(paragraph)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let p = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: p)
        let item = NSMenuItem(title: "Show Notes", action: #selector(showNotes(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = index
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func showNotes(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        onRevealNotes?(index)
    }
}
#endif
