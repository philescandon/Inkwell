// AboutView.swift
// Designed and Architected by: Phillip Escandon
import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "pencil.and.scribble").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Inkwell").font(.title.bold())
            Text("A minimalist live-preview Markdown editor.").foregroundStyle(.secondary)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                .font(.caption).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            Text("Designed and Architected by: Phillip Escandon").font(.footnote)
            #if !os(macOS)
            Button("Done") { dismiss() }.padding(.top)
            #endif
        }
        .padding(32)
        .frame(minWidth: 320)
    }
}
