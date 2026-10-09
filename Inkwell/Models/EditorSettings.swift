// EditorSettings.swift — app-wide preferences backed by UserDefaults.
// Design decision: a single @Observable object (not @AppStorage scattered through views) so the
// AppKit/UIKit editor can read settings without a SwiftUI environment.
// Designed and Architected by: Phillip Escandon
import Foundation
import Observation

@MainActor
@Observable
final class EditorSettings {
    static let shared = EditorSettings()

    private let defaults = UserDefaults.standard

    var theme: EditorTheme { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    var typewriterMode: Bool { didSet { defaults.set(typewriterMode, forKey: "typewriterMode") } }
    var focusMode: Bool { didSet { defaults.set(focusMode, forKey: "focusMode") } }
    var showOutline: Bool { didSet { defaults.set(showOutline, forKey: "showOutline") } }

    private init() {
        theme = EditorTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .light
        let size = defaults.double(forKey: "fontSize")
        fontSize = size == 0 ? 16 : size
        typewriterMode = defaults.bool(forKey: "typewriterMode")
        focusMode = defaults.bool(forKey: "focusMode")
        showOutline = defaults.object(forKey: "showOutline") as? Bool ?? true
    }
}
