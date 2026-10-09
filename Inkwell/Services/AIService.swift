// AIService.swift — AI hook. The protocol is the seam for a future Claude-backed provider;
// nothing here performs network I/O. The AI menu stays disabled while the provider is Noop.
// Designed and Architected by: Phillip Escandon
import Foundation

enum AIRewriteStyle: String, CaseIterable, Sendable {
    case clearer, shorter, formal, casual
}

struct AIRequestContext: Sendable {
    /// Full document text; providers may window this themselves.
    var document: String
    /// Currently selected text, if any.
    var selection: String?
}

protocol AIProvider: Sendable {
    var displayName: String { get }
    /// False for placeholder providers; drives the AI menu's enabled state.
    var isAvailable: Bool { get }

    func summarize(_ context: AIRequestContext) async throws -> String
    func rewrite(_ context: AIRequestContext, style: AIRewriteStyle) async throws -> String
    func continueWriting(_ context: AIRequestContext) async throws -> String
    func ask(_ question: String, context: AIRequestContext) async throws -> String
    /// Notes feature: answer a reader's question given the anchored paragraph plus surrounding text.
    func answer(question: String, context: String) async throws -> String
}

enum AIError: Error, LocalizedError {
    case unavailable
    case notConfigured
    var errorDescription: String? {
        switch self {
        case .unavailable: "No AI provider is configured."
        case .notConfigured: "AI is not configured. Add a provider in Services/AIService.swift."
        }
    }
}

/// Placeholder that keeps the app fully functional without any AI backend.
struct NoopAIProvider: AIProvider {
    let displayName = "None"
    let isAvailable = false

    func summarize(_ context: AIRequestContext) async throws -> String { throw AIError.unavailable }
    func rewrite(_ context: AIRequestContext, style: AIRewriteStyle) async throws -> String { throw AIError.unavailable }
    func continueWriting(_ context: AIRequestContext) async throws -> String { throw AIError.unavailable }
    func ask(_ question: String, context: AIRequestContext) async throws -> String { throw AIError.unavailable }
    func answer(question: String, context: String) async throws -> String { throw AIError.notConfigured }
}

/// Single injection point. Swap `provider` for a `ClaudeAIProvider` later and the menu enables itself.
enum AIService {
    static let provider: any AIProvider = NoopAIProvider()
}
