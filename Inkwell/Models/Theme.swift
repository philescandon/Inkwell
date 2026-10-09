// Theme.swift — editor color themes. Colors are platform-native so they can go straight into NSAttributedString.
// Designed and Architected by: Phillip Escandon
import SwiftUI

enum EditorTheme: String, CaseIterable, Identifiable, Sendable {
    case light, dark, sepia

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .sepia: "Sepia"
        }
    }

    /// Sepia is a light scheme with warm colors; only `dark` flips the system chrome.
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }

    var background: PlatformColor {
        switch self {
        case .light: rgb(1.0, 1.0, 1.0)
        case .dark: rgb(0.11, 0.11, 0.12)
        case .sepia: rgb(0.96, 0.93, 0.86)
        }
    }

    var text: PlatformColor {
        switch self {
        case .light: rgb(0.13, 0.13, 0.13)
        case .dark: rgb(0.88, 0.88, 0.88)
        case .sepia: rgb(0.30, 0.24, 0.18)
        }
    }

    var secondaryText: PlatformColor { text.withAlphaComponent(0.55) }
    var markerText: PlatformColor { text.withAlphaComponent(0.28) }
    var dimmedText: PlatformColor { text.withAlphaComponent(0.35) }

    var accent: PlatformColor {
        switch self {
        case .light: rgb(0.16, 0.44, 0.85)
        case .dark: rgb(0.45, 0.65, 1.0)
        case .sepia: rgb(0.55, 0.32, 0.12)
        }
    }

    var codeBackground: PlatformColor {
        switch self {
        case .light: rgb(0.95, 0.95, 0.96)
        case .dark: rgb(0.17, 0.17, 0.19)
        case .sepia: rgb(0.91, 0.87, 0.78)
        }
    }

    /// CSS used by the HTML preview/export so it matches the editor.
    var css: String {
        func hex(_ c: PlatformColor) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            #if os(macOS)
            (c.usingColorSpace(.sRGB) ?? c).getRed(&r, green: &g, blue: &b, alpha: &a)
            #else
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            #endif
            return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        }
        return """
        body { font-family: -apple-system, system-ui, sans-serif; line-height: 1.6; max-width: 46em; margin: 2em auto; padding: 0 1.5em;
               background: \(hex(background)); color: \(hex(text)); }
        a { color: \(hex(accent)); }
        code, pre { font-family: ui-monospace, Menlo, monospace; background: \(hex(codeBackground)); border-radius: 4px; }
        code { padding: 0.1em 0.3em; } pre { padding: 0.8em 1em; overflow-x: auto; } pre code { padding: 0; background: none; }
        blockquote { border-left: 3px solid \(hex(accent)); margin-left: 0; padding-left: 1em; opacity: 0.85; }
        hr { border: none; border-top: 1px solid \(hex(markerText)); }
        h1, h2, h3 { line-height: 1.25; }
        table { border-collapse: collapse; margin: 1em 0; display: block; max-width: 100%; overflow-x: auto; font-size: 0.95em; }
        th, td { border: 1px solid \(hex(markerText)); padding: 0.4em 0.8em; text-align: left; vertical-align: top; }
        th { background: \(hex(codeBackground)); font-weight: 600; }
        tbody tr:nth-child(even) { background: color-mix(in srgb, \(hex(codeBackground)) 45%, transparent); }
        pre.mermaid { background: none; padding: 0.5em 0; text-align: center; overflow-x: auto; }
        pre.mermaid svg { max-width: 100%; height: auto; }
        """
    }

    /// Mermaid built-in theme that best matches each editor theme (passed to `mermaid.initialize`).
    var mermaidTheme: String {
        switch self {
        case .light: "default"
        case .dark: "dark"
        case .sepia: "neutral"
        }
    }

    private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> PlatformColor {
        #if os(macOS)
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        #else
        UIColor(red: r, green: g, blue: b, alpha: 1)
        #endif
    }
}
