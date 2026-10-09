// SettingsView.swift — theme, font size, writing modes. Same view backs the macOS Settings scene and the iPad sheet.
// Designed and Architected by: Phillip Escandon
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = EditorSettings.shared

    var body: some View {
        Form {
            Picker("Theme", selection: $settings.theme) {
                ForEach(EditorTheme.allCases) { Text($0.label).tag($0) }
            }
            Stepper("Font size: \(Int(settings.fontSize)) pt", value: $settings.fontSize, in: 11...32)
            Toggle("Typewriter mode", isOn: $settings.typewriterMode)
            Toggle("Focus mode", isOn: $settings.focusMode)
            Toggle("Show outline", isOn: $settings.showOutline)
            #if !os(macOS)
            Button("Done") { dismiss() }
            #endif
        }
        .formStyle(.grouped)
        .frame(minWidth: 360, minHeight: 240)
        .navigationTitle("Settings")
    }
}
