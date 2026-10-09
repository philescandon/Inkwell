// SidebarView.swift — folder tree; clicking a file opens it as a new document via openDocument.
// Designed and Architected by: Phillip Escandon
import SwiftUI

struct SidebarView: View {
    let store: FolderBookmarkStore
    @Binding var showFolderPicker: Bool
    // OpenDocumentAction is macOS-only; on iOS a DocumentGroup app opens a file URL through openURL.
    #if os(macOS)
    @Environment(\.openDocument) private var openDocument
    #else
    @Environment(\.openURL) private var openURL
    #endif
    @State private var openError: String?

    var body: some View {
        Group {
            if store.rootURL == nil {
                ContentUnavailableView {
                    Label("No Folder", systemImage: "folder")
                } description: {
                    Text("Choose a folder to browse its Markdown files.")
                } actions: {
                    Button("Choose Folder…") { showFolderPicker = true }
                    // Bookmark/permission failures were previously swallowed; show them here so a
                    // folder that "does nothing" at least explains itself.
                    if let message = store.errorMessage {
                        Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                }
            } else {
                List(store.tree, children: \.children) { node in
                    if node.isDirectory {
                        Label(node.name, systemImage: "folder")
                    } else {
                        Button {
                            open(node.id)
                        } label: {
                            Label(node.name, systemImage: "doc.text")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle(store.rootURL?.lastPathComponent ?? "Files")
        .toolbar {
            ToolbarItemGroup {
                Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(store.rootURL == nil)
                Menu {
                    Button("Choose Folder…") { showFolderPicker = true }
                    Button("Forget Folder", role: .destructive) { store.clear() }.disabled(store.rootURL == nil)
                } label: { Label("Folder", systemImage: "folder.badge.gearshape") }
            }
        }
        .alert("Could Not Open", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button("OK") {}
        } message: { Text(openError ?? "") }
    }

    private func open(_ url: URL) {
        #if os(macOS)
        Task {
            do { try await openDocument(at: url) } catch { openError = error.localizedDescription }
        }
        #else
        openURL(url) { accepted in
            if !accepted { openError = "The system declined to open \(url.lastPathComponent)." }
        }
        #endif
    }
}
