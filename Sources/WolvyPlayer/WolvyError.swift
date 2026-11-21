import Foundation

/// An error from the player. `code` is one of the web Player API's codes, so the same handling
/// works in every Wolvy SDK; `reason` says more, for logs and support.
///
/// Reasons from the server are its own codes: `app_not_allowed` (add the app's bundle id in the
/// dashboard: Settings → Protection → Allowed apps, platform iOS), `viewer_token_required`
/// (missing, expired or wrongly signed token), `update_required` (this SDK version is too old),
/// `video_not_found`, `video_not_ready`, `multi_drm_required`, `ip_not_allowed`,
/// `country_not_allowed`, `viewer_link_locked`, `rate_limited`, `not_available`. Reasons from the
/// device: `licence_refused`, `playback_failed`, `network`, `token_provider_failed`.
///
/// Messages never contain tokens.
public struct WolvyError: Error, LocalizedError, CustomStringConvertible, Equatable, Sendable {
    /// The web Player API's error codes, with the same meaning.
    public enum Code: String, Sendable {
        /// The video could not be loaded: no connection, or the server refused (see `reason`).
        case networkError = "network_error"
        /// The video could not be played (see `reason`).
        case playbackError = "playback_error"
        /// App-Only is on for the account and this device has no hardware DRM (never on iPhone).
        case deviceNotSupported = "device_not_supported"
        /// The call needs the video loaded first (seek, setQuality).
        case notReady = "not_ready"
        /// A setter got a value that is not on offer.
        case invalidArgument = "invalid_argument"
        /// release() was called.
        case destroyed = "destroyed"
        /// Something failed in a way the SDK did not name.
        case failed = "failed"
    }

    public let code: Code
    public let message: String
    public let reason: String?
    /// What went wrong underneath, in words, with tokens removed.
    public let detail: String?

    public init(_ code: Code, _ message: String, reason: String? = nil, detail: String? = nil) {
        self.code = code
        self.message = message
        self.reason = reason
        self.detail = detail.map(Scrub.text)
    }

    public var errorDescription: String? { message }

    public var description: String {
        "WolvyError(\(code.rawValue)\(reason.map { ", \($0)" } ?? "")): \(message)"
    }

    static let networkish: Set<String> = ["rate_limited", "not_available"]

    /// Maps a refusal of the playback endpoint.
    static func fromServer(status: Int, serverCode: String?, message: String?) -> WolvyError {
        let text = (message?.isEmpty == false) ? message! : "The server refused the video (HTTP \(status))."
        let code: Code
        if let serverCode, networkish.contains(serverCode) || status >= 500 {
            code = .networkError
        } else if serverCode == nil && status >= 500 {
            code = .networkError
        } else if serverCode != nil {
            code = .playbackError
        } else {
            code = .failed
        }
        return WolvyError(code, text, reason: serverCode ?? "http_\(status)")
    }
}
