import SwiftUI

@main
struct WolvyAttestSpikeApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @StateObject private var spike = AttestSpike()

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Attest") { Task { await spike.attest() } }
                Button("Assert") { Task { await spike.assert() } }
                Button("Copy") { UIPasteboard.general.string = spike.report }
                Button("Reset") { spike.resetKey(); spike.describe() }
            }
            .buttonStyle(.bordered)
            .disabled(spike.busy)
            if spike.busy { ProgressView() }
            List(Array(spike.lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
            .listStyle(.plain)
        }
        .padding(.top)
    }
}
