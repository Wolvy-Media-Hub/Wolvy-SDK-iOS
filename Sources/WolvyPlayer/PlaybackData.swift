import Foundation

/// Everything the player needs to play one video, as the playback endpoint answers it.
/// A custom ``WolvyPlaybackSource`` builds it with ``fromJSON(_:apiBase:)`` from an answer of the same shape.
public struct WolvyPlaybackData: Sendable {
    public static let cdnDomain = "wolvy-cdn.net"
    public static let defaultApiBase = URL(string: "https://wolvy.net/api")!

    /// The playback session. In every media address (the path form) and sent back when asking again.
    public let sessionId: String?
    /// The licence token. Not readable outside the SDK, so it cannot end up in an app's logs.
    let licenceToken: String
    public let licenceTokenTtlSeconds: Int
    /// The media server, e.g. "25001".
    public let serverId: String
    let cdnToken: String?
    let cdnExpires: Int64?
    public let poster: URL?
    public let duration: Double?
    public let captions: [WolvyCaptionTrack]
    public let chapters: [WolvyChapter]
    public let moments: [WolvyMoment]
    /// The account's player colour, "#RRGGBB", or nil.
    public let playerColor: String?
    /// The verified viewer id from the token, for the watermark.
    public let viewerId: String?
    public let watermark: WolvyWatermark
    /// App-Only is on for the account (iPhones always have hardware DRM, so it does not block them).
    public let appOnly: Bool
    let apiBase: URL

    /// The FairPlay licence address, with the licence token.
    var licenceUrl: URL {
        var c = URLComponents(url: apiBase.appendingPathComponent("process_videos/fairplay"), resolvingAgainstBaseURL: false)!
        c.percentEncodedQuery = "token=" + Self.encode(licenceToken)
        return c.url!
    }

    /// The FairPlay application certificate.
    var certificateUrl: URL { apiBase.appendingPathComponent("process_videos/fairplay.cer") }

    /// The HLS playlist of `video` on this media server, in the CDN's path form (as the Worker
    /// builds it for Safari): `/p/{cdn_token}/{exp}/{session}/{account}/{video}/hls/playlist.m3u8`.
    /// Every segment address inherits the token and the session id from it.
    func playlistUrl(_ video: WolvyVideo) -> URL {
        var prefix = ""
        if let cdnToken, !cdnToken.isEmpty {
            prefix = "/p/\(Self.encode(cdnToken))/\(cdnExpires.map(String.init) ?? "0")"
            if let sessionId, !sessionId.isEmpty { prefix += "/\(sessionId)" }
        }
        return URL(string: "https://\(serverId).\(Self.cdnDomain)\(prefix)/\(video.accountId)/\(Self.encode(video.videoId))/hls/playlist.m3u8")!
    }

    /// The WebVTT file of one caption language.
    public func captionUrl(_ video: WolvyVideo, language: String) -> URL {
        URL(string: "https://\(serverId).\(Self.cdnDomain)/\(video.accountId)/\(Self.encode(video.videoId))/captions/\(Self.encode(language)).vtt")!
    }

    /// Reads an answer of the playback endpoint (`app_render_video`). `apiBase` is where the
    /// licence proxy lives.
    ///
    /// - Throws: ``WolvyError`` when a required field is missing.
    public static func fromJSON(_ json: [String: Any], apiBase: URL = defaultApiBase) throws -> WolvyPlaybackData {
        guard let token = string(json["token"]), !token.isEmpty,
              let server = string(json["server_id"]), !server.isEmpty else {
            throw WolvyError(.failed, "The playback answer has no licence token or media server.", reason: "bad_answer")
        }
        let wm = json["watermark"] as? [String: Any]
        let captions: [WolvyCaptionTrack] = (json["captions"] as? [[String: Any]] ?? []).compactMap {
            guard let lang = string($0["language_code"]), !lang.isEmpty else { return nil }
            let label = string($0["label"]) ?? ""
            return WolvyCaptionTrack(language: lang, label: label.isEmpty ? lang : label)
        }
        let chapters = (json["chapters"] as? [[String: Any]] ?? []).map {
            WolvyChapter(start: double($0["start"]) ?? 0, end: double($0["end"]) ?? 0, title: string($0["title"]) ?? "")
        }.sorted { $0.start < $1.start }
        let moments = (json["moments"] as? [[String: Any]] ?? []).map {
            WolvyMoment(timestamp: double($0["timestamp"]) ?? 0, label: string($0["label"]) ?? "")
        }
        let color = string(json["player_color"]).flatMap {
            $0.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil ? $0 : nil
        }
        let ttl = Int(double(json["expires_in"]) ?? 300)
        return WolvyPlaybackData(
            sessionId: string(json["session_id"]).flatMap { $0.isEmpty ? nil : $0 },
            licenceToken: token,
            licenceTokenTtlSeconds: ttl > 0 ? ttl : 300,
            serverId: server,
            cdnToken: string(json["cdn_token"]).flatMap { $0.isEmpty ? nil : $0 },
            cdnExpires: double(json["cdn_exp"]).map { Int64($0) },
            poster: string(json["poster"]).flatMap { $0.isEmpty ? nil : URL(string: $0) },
            duration: double(json["duration"]).flatMap { $0 > 0 ? $0 : nil },
            captions: captions,
            chapters: chapters,
            moments: moments,
            playerColor: color,
            viewerId: string(json["viewer_id"]).flatMap { $0.isEmpty ? nil : $0 },
            watermark: WolvyWatermark(
                enabled: (wm?["enabled"] as? Bool) ?? ((wm?["enabled"] as? NSNumber)?.boolValue ?? false),
                mode: string(wm?["mode"]).flatMap { $0.isEmpty ? nil : $0 } ?? "moving",
                position: string(wm?["position"]).flatMap { $0.isEmpty ? nil : $0 } ?? "bottom-right",
                opacity: min(100, max(0, Int(double(wm?["opacity"]) ?? 40)))
            ),
            appOnly: (json["app_only_l3"] as? Bool) ?? ((json["app_only_l3"] as? NSNumber)?.boolValue ?? false),
            apiBase: apiBase
        )
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
