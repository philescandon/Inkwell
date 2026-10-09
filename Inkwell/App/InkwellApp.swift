// InkwellApp.swift — DocumentGroup scene plus all menu commands. Commands reach the front document
// through @FocusedValue so a single menu bar serves every window.
// Designed and Architected by: Phillip Escandon
import SwiftUI

@main
struct InkwellApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            ContentView(document: file.$document, fileURL: file.fileURL)
        }
        .modelContainer(NoteStore.container)
        .commands {
            FormatCommands()
            ViewCommands()
            NotesCommands()
            AICommands()
            #if os(macOS)
            CommandGroup(replacing: .appInfo) { AboutButton() }
            #endif
        }

        #if os(macOS)
        Window("About Inkwell", id: "about") { AboutView() }
            .windowResizability(.contentSize)
        Window("Questions", id: "questions") { QuestionsInboxView() }
            .modelContainer(NoteStore.container)
            .keyboardShortcut("q", modifiers: [.command, .shift])
            .defaultSize(width: 640, height: 480)
        Settings { SettingsView() }
        #endif
    }
}

#if os(macOS)
private struct AboutButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("About Inkwell") { openWindow(id: "about") } }
}
#endif

private struct FormatCommands: Commands {
    @FocusedValue(\.editorController) private var controller
    @FocusedValue(\.documentTitle) private var title

    var body: some Commands {
        CommandMenu("Format") {
            Button("Bold") { controller?.toggleBold() }.keyboardShortcut("b", modifiers: .command)
            Button("Italic") { controller?.toggleItalic() }.keyboardShortcut("i", modifiers: .command)
            Button("Inline Code") { controller?.toggleCode() }.keyboardShortcut("e", modifiers: .command)
            Button("Strikethrough") { controller?.toggleStrike() }.keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Link") { controller?.insertLink() }.keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Paragraph") { controller?.setHeading(level: 0) }.keyboardShortcut("0", modifiers: [.command, .shift])
            ForEach(1...6, id: \.self) { level in
                Button("Heading \(level)") { controller?.setHeading(level: level) }
                    .keyboardShortcut(KeyEquivalent(Character("\(level)")), modifiers: [.command, .shift])
            }
            Divider()
            Button("Insert Table of Contents") { controller?.insertTableOfContents() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }

        CommandGroup(after: .saveItem) {
            Button("Export HTML…") { controller?.showExporter = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Copy as HTML") { controller?.copyAsHTML(title: title ?? "Untitled") }
                .keyboardShortcut("c", modifiers: [.command, .shift, .option])
        }
    }
}

private struct ViewCommands: Commands {
    @FocusedValue(\.editorController) private var controller
    private var settings = EditorSettings.shared

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(controller?.sourceMode == true ? "Live Preview" : "Source Mode") { controller?.sourceMode.toggle() }
                .keyboardShortcut("/", modifiers: .command)
            Button("HTML Preview") { controller?.showPreview = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Toggle("Typewriter Mode", isOn: Bindable(settings).typewriterMode)
                .keyboardShortcut("t", modifiers: [.command, .option])
            Toggle("Focus Mode", isOn: Bindable(settings).focusMode)
                .keyboardShortcut("f", modifiers: [.command, .option])
            Toggle("Show Outline", isOn: Bindable(settings).showOutline)
                .keyboardShortcut("o", modifiers: [.command, .option])
            Divider()
            Picker("Theme", selection: Bindable(settings).theme) {
                ForEach(EditorTheme.allCases) { Text($0.label).tag($0) }
            }
            Button("Bigger Text") { settings.fontSize = min(32, settings.fontSize + 1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller Text") { settings.fontSize = max(11, settings.fontSize - 1) }
                .keyboardShortcut("-", modifiers: .command)
        }
    }
}

/// Notes menu: add, show panel, and the two markdown exports. Items act on the front document.
private struct NotesCommands: Commands {
    @FocusedValue(\.editorController) private var controller
    private var settings = EditorSettings.shared

    var body: some Commands {
        CommandMenu("Notes") {
            Button("Add Note…") { controller?.beginAddNote() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(controller == nil)
            Button("Show Notes") {
                controller?.inspectorTab = .notes
                controller?.revealParagraph = nil
                settings.showOutline = true
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(controller == nil)
            Divider()
            Button("Export Notes to Markdown…") { controller?.showNotesExporter = true }
                .disabled(controller == nil)
            Button("Export All Questions…") { controller?.showAllQuestionsExporter = true }
                .disabled(controller == nil)
        }
    }
}

/// Disabled until a real AIProvider replaces NoopAIProvider (see Services/AIService.swift).
private struct AICommands: Commands {
    var body: some Commands {
        // Commands has no .disabled; each item is gated individually.
        let enabled = AIService.provider.isAvailable
        CommandMenu("AI") {
            Button("Summarize") {}.disabled(!enabled)
            Button("Rewrite…") {}.disabled(!enabled)
            Button("Continue Writing") {}.disabled(!enabled)
            Button("Ask…") {}.disabled(!enabled)
            Divider()
            Text("Provider: \(AIService.provider.displayName)")
        }
    }
}
