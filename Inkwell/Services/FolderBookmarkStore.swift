// FolderBookmarkStore.swift — remembers the user's chosen notes folder via a security-scoped bookmark
// and builds the sidebar file tree. Only .md/.markdown/.txt files are listed; empty folders are pruned.
// Designed and Architected by: Phillip Escandon
import Foundation
import Observation

struct FileNode: Identifiable, Hashable, Sendable {
    let id: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?   // nil for files so List(children:) renders them as leaves
}

@MainActor
@Observable
final class FolderBookmarkStore {
    private(set) var rootURL: URL?
    private(set) var tree: [FileNode] = []
    private(set) var errorMessage: String?

    private let key = "notesFolderBookmark"
    private var accessedURL: URL?

    init() { restore() }

    func choose(_ url: URL) {
        // A URL from SwiftUI's fileImporter is security-scoped but not yet opened; in the sandbox,
        // bookmarkData(.withSecurityScope) fails unless access is started first. Balanced below:
        // activate() starts its own long-lived access, so this temporary one is stopped once the
        // bookmark exists.
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            #if os(macOS)
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            #else
            let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            #endif
            UserDefaults.standard.set(data, forKey: key)
            activate(url)
        } catch {
            errorMessage = "Could not bookmark folder: \(error.localizedDescription)"
        }
    }

    func restore() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        var stale = false
        do {
            #if os(macOS)
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            #else
            let url = try URL(resolvingBookmarkData: data, relativeTo: nil, bookmarkDataIsStale: &stale)
            #endif
            activate(url)
            if stale { choose(url) }   // refresh the bookmark data in place
        } catch {
            errorMessage = "Folder bookmark no longer valid."
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func clear() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        rootURL = nil
        tree = []
        UserDefaults.standard.removeObject(forKey: key)
    }

    func refresh() {
        guard let rootURL else { return }
        tree = Self.scan(rootURL, depth: 0) ?? []
    }

    private func activate(_ url: URL) {
        accessedURL?.stopAccessingSecurityScopedResource()
        // Access stays open for the app's lifetime so files inside can be opened later without re-prompting.
        _ = url.startAccessingSecurityScopedResource()
        accessedURL = url
        rootURL = url
        errorMessage = nil
        refresh()
    }

    private static let extensions: Set<String> = ["md", "markdown", "mdown", "txt"]

    private static func scan(_ dir: URL, depth: Int) -> [FileNode]? {
        guard depth < 8 else { return nil }
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        var nodes: [FileNode] = []
        for url in items {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if let kids = scan(url, depth: depth + 1), !kids.isEmpty {
                    nodes.append(FileNode(id: url, name: url.lastPathComponent, isDirectory: true, children: kids))
                }
            } else if extensions.contains(url.pathExtension.lowercased()) {
                nodes.append(FileNode(id: url, name: url.lastPathComponent, isDirectory: false, children: nil))
            }
        }
        return nodes.sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }
}
