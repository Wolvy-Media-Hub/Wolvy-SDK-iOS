import AVFoundation
import UIKit

/// One line of the on-screen log.
struct LogLine: Identifiable {
    let id = UUID()
    let time: Date
    let text: String
}

/// The parts of `app_render_video`'s answer the spike uses.
struct Playback {
    let token: String
    let sessionId: String
    let serverId: String
    let cdnToken: String?
    let cdnExp: String
    let viewerId: String?
    let watermarkEnabled: Bool
}

enum SpikeError: LocalizedError {
    case badEmbedUrl
    case server(code: String, message: String)
    case http(Int, String)
    case noCertificate

    var errorDescription: String? {
        switch self {
        case .badEmbedUrl: return "That is not an embed_url (https://embed.wolvy.stream/{video}/{account}?vt=…)."
        case let .server(code, message): return "Wolvy refused: \(code) — \(message)"
        case let .http(status, body): return "HTTP \(status) \(body.prefix(120))"
        case .noCertificate: return "No FairPlay certificate."
        }
    }
}

/// Phase 4 step 2: asks `app_render_video` as an iOS app, plays the HLS ladder through the CDN's
/// path form, and answers FairPlay key requests through `process_videos/fairplay` with the
/// licence token, logging every step so a phone run can be read back.
final class SpikePlayer: NSObject, ObservableObject {
    static let sdkHeader = "wolvy-ios-spike/0.0.1"
    static let renderUrl = URL(string: "https://wolvy.net/api/app_render_video")!
    static let certificateUrl = URL(string: "https://wolvy.net/api/process_videos/fairplay.cer")!

    @Published private(set) var log: [LogLine] = []
    @Published private(set) var player: AVPlayer?
    @Published private(set) var watermark: String?
    @Published private(set) var captured = UIScreen.main.isCaptured

    private let keyQueue = DispatchQueue(label: "net.wolvy.spike.keys")
    private var keySession: AVContentKeySession?
    private var certificate: Data?
    private var licenceToken = ""
    private var itemObservers: [NSObjectProtocol] = []
    private var kvo: [NSKeyValueObservation] = []
    private var appObservers: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var startedAt = Date()

    override init() {
        super.init()
        let center = NotificationCenter.default
        appObservers.append(center.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            let isCaptured = UIScreen.main.isCaptured
            self?.captured = isCaptured
            self?.say(isCaptured ? "screen capture started (recording or mirroring)" : "screen capture stopped")
        })
        appObservers.append(center.addObserver(forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main) { [weak self] _ in
            self?.say("screenshot taken")
        })
        say("iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model), app \(Bundle.main.bundleIdentifier ?? "?")")
    }

    // MARK: - Log

    func say(_ text: String) {
        let line = LogLine(time: Date(), text: Self.redact(text))
        // Also in the device's system log, where remote device clouds (Sauce Labs) show it.
        NSLog("[WolvySpike] %@", line.text)
        if Thread.isMainThread {
            log.append(line)
        } else {
            DispatchQueue.main.async { self.log.append(line) }
        }
    }

    func copyLog() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        UIPasteboard.general.string = log.map { "\(formatter.string(from: $0.time)) \($0.text)" }.joined(separator: "\n")
    }

    /// Tokens never go into the log: the CDN token in the path and any token= value.
    static func redact(_ text: String) -> String {
        var out = text
        for pattern in ["/p/[^/]+/", "token=[^&\\s]+", "vt=[^&\\s]+"] {
            out = out.replacingOccurrences(of: pattern, with: pattern.hasPrefix("/p/") ? "/p/…/" : String(pattern.prefix(while: { $0 != "=" })) + "=…", options: .regularExpression)
        }
        return out
    }

    // MARK: - Play

    func play(embedUrl: String) {
        stop()
        startedAt = Date()
        Task {
            do {
                let (videoId, accountId, vt) = try Self.parse(embedUrl: embedUrl.trimmingCharacters(in: .whitespacesAndNewlines))
                say("video \(videoId), account \(accountId)")
                let playback = try await fetchPlayback(videoId: videoId, accountId: accountId, vt: vt)
                say("app_render_video: session \(playback.sessionId.isEmpty ? "(none)" : String(playback.sessionId.prefix(8)) + "…"), server \(playback.serverId), viewer \(playback.viewerId ?? "-")")
                licenceToken = playback.token
                if certificate == nil {
                    certificate = try await fetchCertificate()
                }
                let url = Self.hlsUrl(playback: playback, accountId: accountId, videoId: videoId)
                say("playlist \(url.absoluteString)")
                await MainActor.run {
                    self.watermark = playback.watermarkEnabled ? playback.viewerId : nil
                    self.start(url: url)
                }
            } catch {
                say("✗ \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers = []
        kvo.forEach { $0.invalidate() }
        kvo = []
        keySession = nil
        player = nil
        watermark = nil
    }

    // MARK: - Steps

    static func parse(embedUrl: String) throws -> (String, String, String) {
        guard let components = URLComponents(string: embedUrl), components.host?.hasSuffix("wolvy.stream") == true else {
            throw SpikeError.badEmbedUrl
        }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 2,
              let vt = components.queryItems?.first(where: { $0.name == "vt" })?.value, !vt.isEmpty else {
            throw SpikeError.badEmbedUrl
        }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let account = String(data: data, encoding: .utf8),
              !account.isEmpty, account.allSatisfy(\.isNumber) else {
            throw SpikeError.badEmbedUrl
        }
        return (parts[0], account, vt)
    }

    private func fetchPlayback(videoId: String, accountId: String, vt: String) async throws -> Playback {
        var request = URLRequest(url: Self.renderUrl)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("ios", forHTTPHeaderField: "X-Wolvy-Platform")
        request.setValue(Bundle.main.bundleIdentifier ?? "", forHTTPHeaderField: "X-Wolvy-App-Id")
        request.setValue(Self.sdkHeader, forHTTPHeaderField: "X-Wolvy-SDK")
        request.httpBody = Self.form(["user_id": accountId, "video_id": videoId, "vt": vt])
        let (body, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw SpikeError.http(status, String(data: body, encoding: .utf8) ?? "")
        }
        guard json["status"] as? String == "success", let token = Self.string(json["token"]) else {
            throw SpikeError.server(code: Self.string(json["code"]) ?? "HTTP \(status)", message: Self.string(json["message"]) ?? "")
        }
        let watermark = json["watermark"] as? [String: Any]
        return Playback(
            token: token,
            sessionId: Self.string(json["session_id"]) ?? "",
            serverId: Self.string(json["server_id"]) ?? "25001",
            cdnToken: Self.string(json["cdn_token"]),
            cdnExp: Self.string(json["cdn_exp"]) ?? "0",
            viewerId: Self.string(json["viewer_id"]),
            watermarkEnabled: (watermark?["enabled"] as? Bool) ?? false
        )
    }

    private func fetchCertificate() async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: Self.certificateUrl)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        say("certificate: HTTP \(status), \(data.count) bytes")
        guard status == 200, !data.isEmpty else { throw SpikeError.http(status, "certificate") }
        return data
    }

    /// The Apple path form the Worker builds for Safari:
    /// /p/{cdn_token}/{exp}/{session}/{account}/{video}/hls/playlist.m3u8 on {server}.wolvy-cdn.net.
    static func hlsUrl(playback: Playback, accountId: String, videoId: String) -> URL {
        var prefix = ""
        if let cdnToken = playback.cdnToken, !cdnToken.isEmpty {
            let encoded = cdnToken.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? cdnToken
            prefix = "/p/\(encoded)/\(playback.cdnExp)" + (playback.sessionId.isEmpty ? "" : "/\(playback.sessionId)")
        }
        return URL(string: "https://\(playback.serverId).wolvy-cdn.net\(prefix)/\(accountId)/\(videoId)/hls/playlist.m3u8")!
    }

    private func start(url: URL) {
        let asset = AVURLAsset(url: url)
        let session = AVContentKeySession(keySystem: .fairPlayStreaming)
        session.setDelegate(self, queue: keyQueue)
        session.addContentKeyRecipient(asset)
        keySession = session

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        observe(item: item, player: player)
        self.player = player
        player.play()
    }

    // MARK: - Observing playback

    private func observe(item: AVPlayerItem, player: AVPlayer) {
        kvo.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            switch item.status {
            case .readyToPlay:
                self.say(String(format: "ready to play, %.0f s, after %.1f s", item.duration.seconds, Date().timeIntervalSince(self.startedAt)))
            case .failed:
                self.say("✗ item failed: \(Self.describe(item.error))")
            default:
                break
            }
        })
        kvo.append(item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            let size = item.presentationSize
            if size.width > 0 { self?.say("picture \(Int(size.width))×\(Int(size.height))") }
        })
        kvo.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            switch player.timeControlStatus {
            case .playing: self?.say("playing at \(String(format: "%.1f", player.currentTime().seconds)) s")
            case .paused: self?.say("paused")
            case .waitingToPlayAtSpecifiedRate: self?.say("waiting: \(player.reasonForWaitingToPlay?.rawValue ?? "-")")
            @unknown default: break
            }
        })
        // Every 5 s of playback: the position and the picture, so a run can be read with the video black
        // (a captured screen blanks FairPlay video) and a network drop shows where playback went on from.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self, weak player] time in
            guard let player, player.timeControlStatus == .playing else { return }
            let size = player.currentItem?.presentationSize ?? .zero
            self?.say(String(format: "at %.1f s, %d×%d, rate %.1f", time.seconds, Int(size.width), Int(size.height), player.rate))
        }
        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main) { [weak self] _ in
            guard let event = item.errorLog()?.events.last else { return }
            self?.say("error log: \(event.errorStatusCode) \(event.errorDomain) \(event.errorComment ?? "") \(event.uri ?? "")")
        })
        itemObservers.append(center.addObserver(forName: .AVPlayerItemNewAccessLogEntry, object: item, queue: .main) { [weak self] _ in
            guard let event = item.accessLog()?.events.last else { return }
            self?.say(String(format: "access log: indicated %.0f kbit/s, observed %.0f kbit/s, stalls %d", event.indicatedBitrate / 1000, event.observedBitrate / 1000, event.numberOfStalls))
        })
        itemObservers.append(center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            self?.say("stalled")
        })
        itemObservers.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            self?.say("✗ failed to play to end: \(Self.describe(note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error))")
        })
        itemObservers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.say("ended")
        })
    }

    // MARK: - Helpers

    static func describe(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "unknown" }
        var text = "\(error.domain) \(error.code) \(error.localizedDescription)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " ← \(underlying.domain) \(underlying.code) \(underlying.localizedDescription)"
        }
        return text
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)!
    }
}

// MARK: - FairPlay

extension SpikePlayer: AVContentKeySessionDelegate {
    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        answer(keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        say("renewing key request")
        answer(keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession, contentKeyRequest keyRequest: AVContentKeyRequest, didFailWithError err: Error) {
        say("✗ key request failed: \(Self.describe(err))")
    }

    func contentKeySession(_ session: AVContentKeySession, shouldRetry keyRequest: AVContentKeyRequest,
                           reason retryReason: AVContentKeyRequest.RetryReason) -> Bool {
        say("key request retry asked: \(retryReason.rawValue)")
        return retryReason == .timedOut || retryReason == .receivedResponseWithExpiredLease || retryReason == .receivedObsoleteContentKey
    }

    private func answer(_ keyRequest: AVContentKeyRequest) {
        let identifier = keyRequest.identifier as? String ?? String(describing: keyRequest.identifier)
        // skd://<videoId>: the asset id is what follows the scheme.
        var assetId = identifier.hasPrefix("skd://") ? String(identifier.dropFirst(6)) : identifier
        if let cut = assetId.firstIndex(where: { $0 == "?" || $0 == "/" }) { assetId = String(assetId[..<cut]) }
        say("key request \(identifier) (asset id \(assetId))")

        guard let certificate else {
            keyRequest.processContentKeyResponseError(SpikeError.noCertificate)
            return
        }
        keyRequest.makeStreamingContentKeyRequestData(forApp: certificate, contentIdentifier: Data(assetId.utf8),
                                                      options: [AVContentKeyRequestProtocolVersionsKey: [1]]) { [weak self] spc, error in
            guard let self else { return }
            guard let spc else {
                self.say("✗ SPC not made: \(Self.describe(error))")
                keyRequest.processContentKeyResponseError(error ?? SpikeError.noCertificate)
                return
            }
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            let token = self.licenceToken.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            var request = URLRequest(url: URL(string: "https://wolvy.net/api/process_videos/fairplay?token=\(token)")!)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = spc
            let sentAt = Date()
            URLSession.shared.dataTask(with: request) { data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = data ?? Data()
                self.say(String(format: "licence: HTTP %d, %d bytes, SPC %d bytes, %.2f s", status, body.count, spc.count, Date().timeIntervalSince(sentAt))
                    + (error.map { " ✗ \(Self.describe($0))" } ?? ""))
                if status == 200, !body.isEmpty {
                    keyRequest.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: body))
                } else {
                    keyRequest.processContentKeyResponseError(SpikeError.http(status, String(data: body, encoding: .utf8) ?? ""))
                }
            }.resume()
        }
    }
}
