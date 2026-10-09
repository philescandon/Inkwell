// HTMLPreviewView.swift — WKWebView rendering of the built-in converter's output.
// Designed and Architected by: Phillip Escandon
import SwiftUI
import WebKit

struct HTMLPreviewView: View {
    let html: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebView(html: html)
                .navigationTitle("Preview")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}

private struct WebView {
    let html: String
}

#if os(macOS)
extension WebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { WKWebView() }
    func updateNSView(_ view: WKWebView, context: Context) { view.loadHTMLString(html, baseURL: nil) }
}
#else
extension WebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { WKWebView() }
    func updateUIView(_ view: WKWebView, context: Context) { view.loadHTMLString(html, baseURL: nil) }
}
#endif
