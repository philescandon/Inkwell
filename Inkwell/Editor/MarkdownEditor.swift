// MarkdownEditor.swift — NSTextView/UITextView wrapper. TextKit 1 on both platforms for predictable
// attribute handling. The coordinator owns an EditorCore that decides which paragraphs to restyle.
// Designed and Architected by: Phillip Escandon
import SwiftUI

/// Platform-agnostic incremental restyle logic shared by both coordinators.
@MainActor
final class EditorCore {
    let styler = MarkdownStyler()
    let renderer = BlockRenderer()
    private var lastCursorParagraph = NSRange(location: 0, length: 0)
    private var pendingEdit: NSRange?
    private var needsFullRestyle = true

    init() {
        styler.renderer = renderer
    }

    /// Hooks the renderer to a text view: width tracking and async diagram completion both restyle everything
    /// (block heights change), deferred one runloop turn so we never mutate storage from inside layout.
    func attach(layoutManager lm: NoteMarkerLayoutManager, textView: PlatformTextView) {
        lm.renderer = renderer
        renderer.hostView = textView
        lm.onContentWidthChange = { [weak self, weak textView] w in
            guard let self, let tv = textView, abs(w - renderer.width) > 0.5 else { return }
            renderer.width = w
            Task { @MainActor in
                guard let storage = tv.backingStorage else { return }
                self.fullRestyle(storage: storage, selection: tv.primarySelectedRange)
            }
        }
        renderer.onDiagramReady = { [weak self, weak textView] in
            guard let self, let tv = textView, let storage = tv.backingStorage else { return }
            self.fullRestyle(storage: storage, selection: tv.primarySelectedRange)
        }
    }

    func configChanged(_ config: StyleConfig) -> Bool {
        guard config != styler.config else { return false }
        styler.config = config
        renderer.theme = config.theme
        renderer.fontSize = config.fontSize
        needsFullRestyle = true
        return true
    }

    /// Called from shouldChangeText: remember what will change so didChange can restyle just that.
    func willChange(storage: NSTextStorage, range: NSRange, replacement: String) {
        let old = (storage.string as NSString).substring(with: NSIntersectionRange(range, NSRange(location: 0, length: storage.length)))
        // Fence markers change block state for everything below them → full pass.
        if old.contains("```") || old.contains("~~~") || replacement.contains("```") || replacement.contains("~~~") {
            needsFullRestyle = true
        }
        pendingEdit = NSRange(location: range.location, length: replacement.utf16.count)
    }

    func didChange(storage: NSTextStorage, selection: NSRange) {
        let ns = storage.string as NSString
        if needsFullRestyle {
            styler.restyleAll(storage, cursor: selection)
            needsFullRestyle = false
        } else {
            // Union of the edited paragraphs, the caret's paragraph, and the previous caret paragraph
            // (which may need its markers dimmed again).
            var r = pendingEdit ?? selection
            r = NSUnionRange(r, selection)
            let full = NSRange(location: 0, length: ns.length)
            if NSIntersectionRange(lastCursorParagraph, full).length > 0 || lastCursorParagraph.location < full.length {
                r = NSUnionRange(r, NSIntersectionRange(lastCursorParagraph, full))
            }
            styler.restyle(storage, editedRange: r, cursor: selection)
        }
        pendingEdit = nil
        lastCursorParagraph = ns.length > 0 ? ns.paragraphRange(for: NSIntersectionRange(selection, NSRange(location: 0, length: ns.length))) : NSRange(location: 0, length: 0)
    }

    func selectionChanged(storage: NSTextStorage, selection: NSRange) {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        let full = NSRange(location: 0, length: ns.length)
        let now = ns.paragraphRange(for: NSIntersectionRange(selection, full))
        guard now != lastCursorParagraph else { return }
        let old = NSIntersectionRange(lastCursorParagraph, full)
        if old.length > 0 { styler.restyle(storage, editedRange: old, cursor: selection) }
        styler.restyle(storage, editedRange: now, cursor: selection)
        lastCursorParagraph = now
    }

    func fullRestyle(storage: NSTextStorage, selection: NSRange) {
        styler.restyleAll(storage, cursor: selection)
        needsFullRestyle = false
        lastCursorParagraph = storage.length > 0 ? (storage.string as NSString).paragraphRange(for: NSIntersectionRange(selection, NSRange(location: 0, length: storage.length))) : NSRange(location: 0, length: 0)
    }

    /// Installs a new set of note highlights and restyles only the paragraphs whose highlight changed.
    /// Called after every resolve (offsets shift while typing), so it must stay cheap.
    func setHighlights(_ new: [NoteHighlight], storage: NSTextStorage, selection: NSRange) {
        let old = styler.highlights
        guard old != new else { return }
        styler.highlights = new
        let oldSet = Set(old.map { "\($0.id)|\($0.range)|\($0.status)" })
        let newSet = Set(new.map { "\($0.id)|\($0.range)|\($0.status)" })
        let changed = old.filter { !newSet.contains("\($0.id)|\($0.range)|\($0.status)") }.map(\.range)
            + new.filter { !oldSet.contains("\($0.id)|\($0.range)|\($0.status)") }.map(\.range)
        let full = NSRange(location: 0, length: storage.length)
        for r in changed {
            let clipped = NSIntersectionRange(r, full)
            // A range that no longer exists (text deleted) still needs its old paragraph cleared.
            let target = clipped.length > 0 ? clipped : NSRange(location: min(r.location, full.length), length: 0)
            styler.restyle(storage, editedRange: target, cursor: selection)
        }
    }

    /// Briefly tints `range` (stronger than the resting highlight), then restores it via a restyle.
    func flash(_ range: NSRange, storage: NSTextStorage, selection: NSRange, theme: EditorTheme) {
        let r = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard r.length > 0 else { return }
        storage.addAttribute(.backgroundColor, value: theme.accent.withAlphaComponent(0.45), range: r)
        let styler = self.styler
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            let full = NSRange(location: 0, length: storage.length)
            styler.restyle(storage, editedRange: NSIntersectionRange(r, full), cursor: selection)
        }
    }
}

struct MarkdownEditor {
    /// Inset outside the container; together with the in-container gutter the text starts ~40pt in.
    static let sideInset: CGFloat = 12

    @Binding var text: String
    let controller: EditorController
    let config: StyleConfig
    let typewriter: Bool
    /// Annotated paragraphs; drawn as margin dots by NoteMarkerLayoutManager.
    var markers: [NoteMarker] = []
    /// Quoted ranges; tinted by the styler and badged by the layout manager.
    var highlights: [NoteHighlight] = []
    var flash: EditorController.FlashRequest?
}

#if os(macOS)
extension MarkdownEditor: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Manual TextKit 1 stack. `NSTextView.scrollableTextView()` builds a TextKit 2 view on macOS 15;
        // wiring the storage → NoteMarkerLayoutManager → container ourselves guarantees our subclass draws.
        let storage = NSTextStorage()
        let lm = NoteMarkerLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        tc.lineFragmentPadding = NoteMarkerLayoutManager.gutterWidth   // in-container gutter for note dots
        lm.addTextContainer(tc)
        let tv = InkwellTextView(frame: .zero, textContainer: tc)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = tv

        context.coordinator.core.attach(layoutManager: lm, textView: tv)
        tv.onRevealNotes = { [controller] in controller.revealNotes(atParagraph: $0) }
        tv.onRevealNote = { [controller] in controller.revealNote(id: $0) }
        tv.delegate = context.coordinator
        tv.allowsUndo = true
        tv.isRichText = false
        tv.usesFontPanel = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.textContainerInset = NSSize(width: Self.sideInset, height: 24)
        tv.string = text
        controller.textView = tv
        context.coordinator.apply(config: config, typewriter: typewriter, to: tv, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, let storage = tv.textStorage else { return }
        let c = context.coordinator
        c.parent = self
        if tv.string != text {
            // External change (e.g. undo via document, revert): replace and restyle everything.
            c.isProgrammatic = true
            let sel = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
            c.isProgrammatic = false
            c.core.fullRestyle(storage: storage, selection: tv.selectedRange())
        }
        c.apply(config: config, typewriter: typewriter, to: tv, force: false)
        c.core.setHighlights(highlights, storage: storage, selection: tv.selectedRange())
        if let lm = tv.layoutManager as? NoteMarkerLayoutManager {
            lm.markers = markers        // didSet invalidates display only on change
            lm.highlights = highlights
        }
        if let flash, flash != c.lastFlash {
            c.lastFlash = flash
            c.core.flash(flash.range, storage: storage, selection: tv.selectedRange(), theme: config.theme)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        let core = EditorCore()
        var isProgrammatic = false
        var lastFlash: EditorController.FlashRequest?
        private var typewriter = false

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func apply(config: StyleConfig, typewriter: Bool, to tv: NSTextView, force: Bool) {
            let changed = core.configChanged(config)
            if changed || force {
                tv.backgroundColor = config.theme.background
                tv.insertionPointColor = config.theme.accent
                tv.textColor = config.theme.text
                tv.font = core.styler.bodyFont
                tv.typingAttributes = core.styler.baseAttributes
                core.fullRestyle(storage: tv.textStorage!, selection: tv.selectedRange())
            }
            if self.typewriter != typewriter || force {
                self.typewriter = typewriter
                let h = tv.enclosingScrollView?.contentSize.height ?? 0
                tv.textContainerInset = NSSize(width: MarkdownEditor.sideInset, height: typewriter ? max(24, h / 2) : 24)
                if typewriter { centerCaret(tv) }
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if let storage = textView.textStorage {
                core.willChange(storage: storage, range: affectedCharRange, replacement: replacementString ?? "")
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammatic, let tv = notification.object as? NSTextView, let storage = tv.textStorage else { return }
            core.didChange(storage: storage, selection: tv.selectedRange())
            tv.typingAttributes = core.styler.baseAttributes
            parent.text = tv.string
            if typewriter { centerCaret(tv) }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isProgrammatic, let tv = notification.object as? NSTextView, let storage = tv.textStorage else { return }
            core.selectionChanged(storage: storage, selection: tv.selectedRange())
            if typewriter { centerCaret(tv) }
        }

        private func centerCaret(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let scroll = tv.enclosingScrollView else { return }
            let glyph = lm.glyphIndexForCharacter(at: tv.selectedRange().location)
            var rect = lm.lineFragmentRect(forGlyphAt: min(glyph, max(0, lm.numberOfGlyphs - 1)), effectiveRange: nil)
            if lm.numberOfGlyphs == 0 { rect = .zero }
            let y = rect.midY + tv.textContainerInset.height - scroll.contentSize.height / 2
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
#else
extension MarkdownEditor: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        // Manual TextKit 1 stack (same as macOS side) so the marker-drawing layout manager is in place from the start.
        let storage = NSTextStorage()
        let lm = NoteMarkerLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        tc.lineFragmentPadding = NoteMarkerLayoutManager.gutterWidth   // in-container gutter for note dots
        lm.addTextContainer(tc)
        let tv = UITextView(frame: .zero, textContainer: tc)
        lm.hostView = tv
        context.coordinator.core.attach(layoutManager: lm, textView: tv)
        tv.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.noteTapped(_:)))
        tap.delegate = context.coordinator
        tv.addGestureRecognizer(tap)
        tv.alwaysBounceVertical = true
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.autocorrectionType = .default
        tv.textContainerInset = UIEdgeInsets(top: 24, left: Self.sideInset, bottom: 24, right: 12)
        tv.text = text
        controller.textView = tv
        context.coordinator.apply(config: config, typewriter: typewriter, to: tv, force: true)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if tv.text != text {
            c.isProgrammatic = true
            let sel = tv.selectedRange
            tv.text = text
            tv.selectedRange = NSRange(location: min(sel.location, (text as NSString).length), length: 0)
            c.isProgrammatic = false
            c.core.fullRestyle(storage: tv.textStorage, selection: tv.selectedRange)
        }
        c.apply(config: config, typewriter: typewriter, to: tv, force: false)
        c.core.setHighlights(highlights, storage: tv.textStorage, selection: tv.selectedRange)
        if let lm = tv.layoutManager as? NoteMarkerLayoutManager {
            lm.markers = markers        // didSet invalidates display only on change
            lm.highlights = highlights
        }
        if let flash, flash != c.lastFlash {
            c.lastFlash = flash
            c.core.flash(flash.range, storage: tv.textStorage, selection: tv.selectedRange, theme: config.theme)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: MarkdownEditor
        let core = EditorCore()
        var isProgrammatic = false
        var lastFlash: EditorController.FlashRequest?
        private var typewriter = false

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func apply(config: StyleConfig, typewriter: Bool, to tv: UITextView, force: Bool) {
            let changed = core.configChanged(config)
            if changed || force {
                tv.backgroundColor = config.theme.background
                tv.tintColor = config.theme.accent
                tv.textColor = config.theme.text
                tv.font = core.styler.bodyFont
                tv.typingAttributes = core.styler.baseAttributes
                core.fullRestyle(storage: tv.textStorage, selection: tv.selectedRange)
            }
            if self.typewriter != typewriter || force {
                self.typewriter = typewriter
                let h = tv.bounds.height
                tv.textContainerInset.top = typewriter ? max(24, h / 2) : 24
                tv.textContainerInset.bottom = typewriter ? max(24, h / 2) : 24
            }
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            core.willChange(storage: textView.textStorage, range: range, replacement: text)
            return true
        }

        func textViewDidChange(_ tv: UITextView) {
            guard !isProgrammatic else { return }
            // Don't restyle mid-IME composition; attribute churn breaks marked text.
            if tv.markedTextRange == nil {
                core.didChange(storage: tv.textStorage, selection: tv.selectedRange)
                tv.typingAttributes = core.styler.baseAttributes
            }
            parent.text = tv.text ?? ""
            if typewriter { centerCaret(tv) }
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            guard !isProgrammatic, tv.markedTextRange == nil else { return }
            core.selectionChanged(storage: tv.textStorage, selection: tv.selectedRange)
            if typewriter { centerCaret(tv) }
        }

        // MARK: Notes

        /// Adds "Show Notes" to the edit menu (long-press / right-click) for the tapped paragraph.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            let controller = parent.controller
            let show = UIAction(title: "Show Notes", image: UIImage(systemName: "text.bubble")) { _ in
                controller.revealNotes(atParagraph: range.location)
            }
            return UIMenu(children: [show] + suggestedActions)
        }

        /// Claim touches in the left margin and on highlighted quotes; everything else stays with the text view.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let tv = gestureRecognizer.view as? UITextView else { return false }
            let p = touch.location(in: tv)
            if p.x < tv.textContainerInset.left + tv.textContainer.lineFragmentPadding { return true }
            return highlight(at: p, in: tv) != nil
        }

        /// Let the tap coexist with the text view's own recognizers so a tap on a quote still moves the caret.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        private func highlight(at p: CGPoint, in tv: UITextView) -> NoteHighlight? {
            guard let lm = tv.layoutManager as? NoteMarkerLayoutManager else { return nil }
            let cp = CGPoint(x: p.x - tv.textContainerInset.left, y: p.y - tv.textContainerInset.top)
            guard let idx = lm.characterIndex(atContainerPoint: cp, in: tv.textContainer) else { return nil }
            return lm.highlight(atCharacter: idx)
        }

        @objc func noteTapped(_ g: UITapGestureRecognizer) {
            guard let tv = g.view as? UITextView, let lm = tv.layoutManager as? NoteMarkerLayoutManager else { return }
            let p = g.location(in: tv)
            if p.x < tv.textContainerInset.left + tv.textContainer.lineFragmentPadding {
                if let m = lm.marker(atContainerY: p.y - tv.textContainerInset.top) {
                    let ns = tv.text as NSString
                    let para = ns.paragraphRange(for: NSRange(location: min(m.location, ns.length), length: 0))
                    if let h = lm.highlights.first(where: { NSLocationInRange($0.range.location, para) || $0.range.location == para.location }) {
                        parent.controller.revealNote(id: h.id)
                    } else {
                        parent.controller.revealNotes(atParagraph: m.location)
                    }
                }
            } else if let h = highlight(at: p, in: tv) {
                parent.controller.revealNote(id: h.id)
            }
        }

        private func centerCaret(_ tv: UITextView) {
            guard let pos = tv.selectedTextRange?.end else { return }
            let rect = tv.caretRect(for: pos)
            let y = rect.midY - tv.bounds.height / 2
            tv.setContentOffset(CGPoint(x: 0, y: max(-tv.adjustedContentInset.top, y)), animated: false)
        }
    }
}
#endif
