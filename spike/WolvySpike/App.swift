import AVKit
import SwiftUI

@main
struct WolvySpikeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @StateObject private var spike = SpikePlayer()
    @State private var embedUrl = ""

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Color.black
                PlayerView(player: spike.player)
                if let watermark = spike.watermark {
                    // A plain overlay, as the SDK will draw it: it is not part of the protected picture.
                    Text(watermark)
                        .font(.caption.bold())
                        .foregroundColor(.white.opacity(0.5))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)

            if spike.captured {
                Text("The screen is being recorded or mirrored")
                    .font(.footnote.bold())
                    .foregroundColor(.red)
            }

            TextField("Paste an embed_url", text: $embedUrl)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .font(.footnote)

            HStack {
                Button("Play") { spike.play(embedUrl: embedUrl) }.buttonStyle(.borderedProminent)
                Button("Stop") { spike.stop() }.buttonStyle(.bordered)
                Spacer()
                Button("Copy log") { spike.copyLog() }.buttonStyle(.bordered)
            }

            List(spike.log.reversed()) { line in
                Text("\(Self.timeFormat.string(from: line.time)) \(line.text)")
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
            .listStyle(.plain)
        }
        .padding()
    }
}

/// The system player view: native controls, fullscreen and AirPlay.
struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
