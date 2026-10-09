// StatusBarView.swift — word/char/reading-time counts and mode indicators.
// Designed and Architected by: Phillip Escandon
import SwiftUI

struct StatusBarView: View {
    let stats: TextStats
    let sourceMode: Bool
    let typewriter: Bool
    let focus: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text("\(stats.words) words")
            Text("\(stats.characters) chars")
            Text(stats.readingLabel)
            Spacer()
            if sourceMode { Text("SOURCE") }
            if typewriter { Text("TYPEWRITER") }
            if focus { Text("FOCUS") }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
