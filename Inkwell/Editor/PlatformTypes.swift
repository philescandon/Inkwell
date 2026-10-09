// PlatformTypes.swift — thin AppKit/UIKit aliases so the styler and editor share one code path.
// Designed and Architected by: Phillip Escandon
import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias PlatformTextView = NSTextView
#else
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias PlatformTextView = UITextView
#endif

extension PlatformTextView {
    /// Uniform accessor for the raw string on both platforms.
    var plainText: String {
        #if os(macOS)
        return string
        #else
        return text ?? ""
        #endif
    }

    /// First selected range (macOS supports multiple selections; we only style around the first).
    var primarySelectedRange: NSRange {
        #if os(macOS)
        return selectedRanges.first?.rangeValue ?? NSRange(location: 0, length: 0)
        #else
        return selectedRange
        #endif
    }

    var backingStorage: NSTextStorage? {
        #if os(macOS)
        return textStorage
        #else
        return textStorage
        #endif
    }

    /// Undo-aware replacement. Both platforms route through their text-input machinery so Cmd+Z works.
    func replaceUndoable(_ range: NSRange, with string: String) {
        #if os(macOS)
        guard shouldChangeText(in: range, replacementString: string) else { return }
        textStorage?.replaceCharacters(in: range, with: string)
        didChangeText()
        #else
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return }
        replace(textRange, withText: string)
        #endif
    }

    func setSelection(_ range: NSRange) {
        #if os(macOS)
        setSelectedRange(range)
        scrollRangeToVisible(range)
        #else
        selectedRange = range
        scrollRangeToVisible(range)
        #endif
    }
}

enum FontKit {
    /// Builds a system font with the given traits. Italic is applied via the descriptor because
    /// `systemFont(ofSize:weight:)` has no italic variant.
    static func font(size: CGFloat, bold: Bool = false, italic: Bool = false, mono: Bool = false) -> PlatformFont {
        let base: PlatformFont = mono
            ? .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
            : .systemFont(ofSize: size, weight: bold ? .bold : .regular)
        guard italic else { return base }
        #if os(macOS)
        let desc = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: desc, size: size) ?? base
        #else
        guard let desc = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitItalic)) else { return base }
        return UIFont(descriptor: desc, size: size)
        #endif
    }

    /// Re-derives a font keeping unspecified traits. Used to stack bold/italic/code inside headings etc.
    static func derive(_ f: PlatformFont, bold: Bool? = nil, italic: Bool? = nil, mono: Bool? = nil, size: CGFloat? = nil) -> PlatformFont {
        let t = f.fontDescriptor.symbolicTraits
        #if os(macOS)
        let isBold = t.contains(.bold), isItalic = t.contains(.italic), isMono = t.contains(.monoSpace)
        #else
        let isBold = t.contains(.traitBold), isItalic = t.contains(.traitItalic), isMono = t.contains(.traitMonoSpace)
        #endif
        return font(size: size ?? f.pointSize, bold: bold ?? isBold, italic: italic ?? isItalic, mono: mono ?? isMono)
    }
}
