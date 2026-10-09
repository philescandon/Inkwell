// OutlineView.swift — heading list; indentation reflects heading level.
// Designed and Architected by: Phillip Escandon
import SwiftUI

struct OutlineView: View {
    let headings: [HeadingItem]
    let onSelect: (HeadingItem) -> Void

    var body: some View {
        List {
            if headings.isEmpty {
                Text("No headings").foregroundStyle(.secondary).font(.caption)
            }
            ForEach(headings) { h in
                Button { onSelect(h) } label: {
                    Text(h.title)
                        .font(h.level == 1 ? .subheadline.bold() : .subheadline)
                        .lineLimit(1)
                        .padding(.leading, CGFloat(h.level - 1) * 12)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}
