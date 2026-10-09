// MarkdownDocument.swift — FileDocument holding raw markdown text. The text IS the model;
// all styling is a view-layer overlay, which keeps files byte-faithful.
// Designed and Architected by: Phillip Escandon
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// The system has no built-in `.markdown`; we import net.daringfireball.markdown (declared in Info.plist).
    static let markdownDocument = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

struct MarkdownDocument: FileDocument {
    var text: String

    static let readableContentTypes: [UTType] = [.markdownDocument, .plainText]
    static let writableContentTypes: [UTType] = [.markdownDocument, .plainText]

    init(text: String = "# Untitled\n\n") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Fall back to ISO Latin 1 so a stray non-UTF8 file still opens rather than failing.
        text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Lightweight document used only by the HTML export sheet.
struct HTMLExportDocument: FileDocument {
    var html: String
    static let readableContentTypes: [UTType] = [.html]

    init(html: String) { self.html = html }
    init(configuration: ReadConfiguration) throws {
        html = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(html.utf8))
    }
}

/// Plain-text document used by the notes export sheets (inline comments / questions list).
struct MarkdownExportDocument: FileDocument {
    var text: String
    static let readableContentTypes: [UTType] = [.markdownDocument, .plainText]
    static let writableContentTypes: [UTType] = [.markdownDocument, .plainText]

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
