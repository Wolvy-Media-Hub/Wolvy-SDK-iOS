import Foundation

/// Decodes standard or URL-safe base64, with or without padding. Nil when it is not base64.
enum Base64Lenient {
    static func decode(_ input: String) -> Data? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("=") { s.removeLast() }
        guard !s.isEmpty, s.count % 4 != 1 else { return nil }
        s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard s.range(of: "^[A-Za-z0-9+/]+$", options: .regularExpression) != nil else { return nil }
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

/// Removes tokens from text before it leaves the SDK in an error: viewer and licence tokens
/// (JWT-like `eyJ….…`), token query parameters (`token=`, `exp=`, `vt=`…), the CDN path form
/// (`/p/<token>/…`) and token headers. AVFoundation errors can carry the media address with its
/// token; an app that sends errors to a crash reporter must not send that along.
enum Scrub {
    private static let rules: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}(?:\.[A-Za-z0-9_-]+)?"#), "[token]"),
        (try! NSRegularExpression(pattern: #"([?&](?:token|exp|vt|key|sig|signature)=)[^&\s"'<>]+"#, options: .caseInsensitive), "$1[removed]"),
        (try! NSRegularExpression(pattern: #"(/p/)[^/\s"'<>]+/"#), "$1[removed]/"),
        (try! NSRegularExpression(pattern: #"(X-CDN-Token|X-CDN-Exp|Authorization)(\s*[:=]\s*)[^,\s}\]]+"#, options: .caseInsensitive), "$1$2[removed]"),
    ]

    static func text(_ s: String) -> String {
        rules.reduce(s) { out, rule in
            rule.0.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: rule.1)
        }
    }

    /// The domain, code and scrubbed message of an error and its underlying errors, outermost first.
    static func summary(_ error: Error) -> String {
        var parts: [String] = []
        var current: NSError? = error as NSError
        while let e = current, parts.count < 6 {
            parts.append(text("\(e.domain) \(e.code): \(e.localizedDescription)"))
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " <- ")
    }
}

/// One caption cue, in seconds.
struct Cue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

/// Minimal WebVTT parser, the same as the Android SDK's (ported from Wolvy Player): timed cues
/// only; the WEBVTT header, NOTE blocks and cue ids are skipped and inline tags are removed.
/// Hours are optional and a comma decimal separator is accepted.
enum VttParser {
    private static let timing = try! NSRegularExpression(
        pattern: #"(?:(\d{1,3}):)?(\d{2}):(\d{2})[.,](\d{3})\s*-->\s*(?:(\d{1,3}):)?(\d{2}):(\d{2})[.,](\d{3})"#)
    private static let tag = try! NSRegularExpression(pattern: "<[^>]+>")

    static func parse(_ vtt: String) -> [Cue] {
        let lines = vtt.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        var cues: [Cue] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard let m = timing.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { i += 1; continue }
            func group(_ n: Int) -> String {
                guard let r = Range(m.range(at: n), in: line) else { return "" }
                return String(line[r])
            }
            let start = seconds(group(1), group(2), group(3), group(4))
            let end = seconds(group(5), group(6), group(7), group(8))
            i += 1
            var body: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                body.append(lines[i])
                i += 1
            }
            let joined = body.joined(separator: "\n")
            let text = tag.stringByReplacingMatches(in: joined, range: NSRange(joined.startIndex..., in: joined), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { cues.append(Cue(start: start, end: end, text: text)) }
        }
        return cues
    }

    /// The cue showing at `t` seconds, or nil.
    static func at(_ cues: [Cue], _ t: Double) -> Cue? { cues.first { t >= $0.start && t < $0.end } }

    private static func seconds(_ h: String, _ m: String, _ s: String, _ ms: String) -> Double {
        Double(Int(h) ?? 0) * 3600 + Double(Int(m) ?? 0) * 60 + Double(Int(s) ?? 0) + Double(Int(ms) ?? 0) / 1000
    }
}

/// Seconds actually played, each counted once: the same rule and the same numbers as the web
/// player and the Android SDK, so a course that completes at 90 % on the web completes at 90 %
/// in an app. Call `tick` about every 250 ms with the position; a forward step of at most 2 s
/// marks every second in between, anything else (a seek, a jump back) marks only the second
/// played now.
final class ProgressTracker {
    private var watched = Set<Int>()
    private var lastPos = -1.0
    private var lastPercent = -1.0
    private var lastSentAt = -Double.infinity

    var seconds: Int { watched.count }

    func tick(position: Double, duration: Double, playing: Bool) {
        guard playing, duration > 0 else { lastPos = -1; return }
        if lastPos >= 0, position >= lastPos, position - lastPos <= 2 {
            var s = Int(lastPos.rounded(.down))
            let end = Int(position.rounded(.down))
            while s <= end { mark(s); s += 1 }
        } else {
            mark(Int(position.rounded(.down)))
        }
        lastPos = position
    }

    /// Percent with one decimal, 0 to 100, against the whole seconds of `duration`.
    func percent(duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        let total = max(1, Int(duration.rounded(.down)))
        return min(100, (Double(watched.count) / Double(total) * 1000).rounded() / 10)
    }

    /// Whether a progress event is due: the percent changed, and a second has passed since the
    /// last one, unless `force` (the end) or the video is complete. `now` in seconds.
    func shouldEmit(duration: Double, now: Double, force: Bool) -> Bool {
        let p = percent(duration: duration)
        if p == lastPercent { return false }
        if !force, p < 100, now - lastSentAt < 1 { return false }
        lastPercent = p
        lastSentAt = now
        return true
    }

    func reset() {
        watched.removeAll()
        lastPos = -1
        lastPercent = -1
        lastSentAt = -.infinity
    }

    private func mark(_ s: Int) { if s >= 0 { watched.insert(s) } }
}

/// Where the watermark goes inside the video, as in Wolvy Player and the Android SDK. Moving: a
/// random spot, 2 to 78 % from the left and 4 to 85 % from the top, a new one every 5 s.
/// Static: a corner from the account's setting, 16 points from the edges.
enum WatermarkPlacer {
    static let moveEvery: TimeInterval = 5
    static let margin: Double = 16

    enum Spot: Equatable {
        /// Fractions of the video's width and height for the text's top-left corner.
        case moving(left: Double, top: Double)
        case corner(top: Bool, left: Bool)
    }

    static func place<R: RandomNumberGenerator>(mode: String, position: String, using random: inout R) -> Spot {
        if mode == "moving" {
            return .moving(left: Double(2 + Int.random(in: 0..<77, using: &random)) / 100,
                           top: Double(4 + Int.random(in: 0..<82, using: &random)) / 100)
        }
        let p = position.trimmingCharacters(in: .whitespaces).isEmpty ? "bottom-right" : position
        return .corner(top: p.hasPrefix("top"), left: p.contains("left"))
    }

    static func place(mode: String, position: String) -> Spot {
        var g = SystemRandomNumberGenerator()
        return place(mode: mode, position: position, using: &g)
    }
}

/// What to do when playback fails, as in the Android SDK minus the SD step-down (FairPlay has one
/// key for the whole ladder): fetch fresh playback data for the same session and resume at the
/// same position, up to `maxReloads` times; then give up and report the error. The count starts
/// again after a minute of good playback, so a long video can recover from occasional errors.
final class RecoveryPolicy {
    enum Action: Equatable { case reload, fail }

    private let maxReloads: Int
    private(set) var reloads = 0
    private var reloadBase = 0.0

    init(maxReloads: Int = 3) { self.maxReloads = maxReloads }

    func onError() -> Action {
        guard reloads < maxReloads else { return .fail }
        reloads += 1
        return .reload
    }

    /// Where the last reload resumed, in seconds.
    func onReload(position: Double) { reloadBase = position }

    func onPosition(_ position: Double) {
        if reloads > 0, position > reloadBase + 60 { reloads = 0 }
    }

    /// A manual retry starts the count again.
    func reset() {
        reloads = 0
        reloadBase = 0
    }
}
