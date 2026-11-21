import SwiftUI
import UIKit
import WolvyPlayer

@main
struct WolvySampleApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// Owns the player and logs every event, as an app would.
@MainActor
final class SampleModel: ObservableObject, WolvyPlayerListener {
    struct Line: Identifiable {
        let id = UUID()
        let text: String
    }

    let player = WolvyPlayer()
    @Published var log: [Line] = []
    @Published var fullscreen = false

    init() {
        player.addListener(self)
        say("WolvyPlayer \(WolvyPlayer.sdkVersion), iOS \(UIDevice.current.systemVersion), app \(Bundle.main.bundleIdentifier ?? "?")")
    }

    func play(embedUrl: String) {
        do {
            let video = try WolvyVideo.fromEmbedUrl(embedUrl)
            say("load \(video)")
            try player.load(video)
        } catch {
            say("✗ \(error.localizedDescription)")
        }
    }

    func say(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: Date())) \(text)"
        NSLog("[WolvySample] %@", line)   // also in the device log (Sauce Labs shows it)
        log.append(Line(text: line))
    }

    func copyLog() { UIPasteboard.general.string = log.map(\.text).joined(separator: "\n") }

    // WolvyPlayerListener
    func onReady(_ state: WolvyState) { say("ready: \(String(format: "%.1f", state.duration)) s") }
    func onPlay(_ currentTime: Double) { say("play at \(String(format: "%.1f", currentTime))") }
    func onPause(_ currentTime: Double) { say("pause at \(String(format: "%.1f", currentTime))") }
    func onEnded() { say("ended") }
    func onSeeked(_ currentTime: Double) { say("seeked \(String(format: "%.1f", currentTime))") }
    func onProgress(_ progress: WolvyProgress) {
        if Int(progress.percent * 10) % 50 == 0 { say("progress \(progress.percent) % (\(progress.seconds) s)") }
    }
    func onVolumeChange(_ volume: Float, muted: Bool) { say("volume \(volume) muted \(muted)") }
    func onRateChange(_ playbackRate: Float) { say("rate \(playbackRate)") }
    func onQualityChange(_ q: WolvyQualities) {
        say("quality \(q.available) selected \(q.selected.map(String.init) ?? "auto") playing \(q.playing.map(String.init) ?? "-")")
    }
    func onCaptionsChange(_ active: String?) { say("captions \(active ?? "off")") }
    func onFullscreenChange(_ fullscreen: Bool) {
        say("fullscreen \(fullscreen)")
        self.fullscreen = fullscreen
    }
    func onError(_ error: WolvyError) { say("✗ \(error.code.rawValue) \(error.reason ?? "") \(error.message) \(error.detail ?? "")") }
    func onScreenCaptureChange(_ captured: Bool) { say(captured ? "screen capture started" : "screen capture stopped") }
}

/// WolvyPlayerView in SwiftUI.
struct PlayerSurface: UIViewRepresentable {
    let player: WolvyPlayer
    let fullscreen: Bool

    func makeUIView(context: Context) -> WolvyPlayerView {
        let view = WolvyPlayerView()
        view.player = player
        return view
    }

    func updateUIView(_ view: WolvyPlayerView, context: Context) {
        view.isFullscreen = fullscreen
    }
}

struct ContentView: View {
    @StateObject private var model = SampleModel()
    @State private var embedUrl = ""

    var body: some View {
        Group {
            if model.fullscreen {
                // The same player, in a new layout: playback goes on.
                PlayerSurface(player: model.player, fullscreen: true)
                    .ignoresSafeArea()
                    .statusBarHidden()
            } else {
                VStack(spacing: 10) {
                    PlayerSurface(player: model.player, fullscreen: false)
                        .aspectRatio(16 / 9, contentMode: .fit)
                    TextField("Paste an embed_url", text: $embedUrl)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .font(.footnote)
                    HStack {
                        Button("Load") { model.play(embedUrl: embedUrl) }.buttonStyle(.borderedProminent)
                        Button("Seek +30 s") { _ = try? model.player.seek(model.player.currentTime + 30) }.buttonStyle(.bordered)
                        Spacer()
                        Button("Copy log") { model.copyLog() }.buttonStyle(.bordered)
                    }
                    List(model.log.reversed()) { line in
                        Text(line.text).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    }
                    .listStyle(.plain)
                }
                .padding()
            }
        }
        .background(Color.black.opacity(model.fullscreen ? 1 : 0))
    }
}
