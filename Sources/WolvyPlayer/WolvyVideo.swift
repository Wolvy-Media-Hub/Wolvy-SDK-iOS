import Foundation

/// Gets a fresh viewer token from **your server** when the player needs one. With it, tokens can
/// be short-lived (minutes): a leaked token is then worth little.
///
/// The player calls it:
/// - before asking Wolvy, when the token it has expires within a minute (the expiry is read from
///   the token; only Wolvy's server verifies it);
/// - once more if Wolvy refuses the token (`viewer_token_required`).
///
/// Sign the token on your server (`POST /v1/videos/{id}/playback-tokens`, or the server SDKs'
/// `signViewerToken`). Never sign it in the app: that needs the account's signing secret.
/// Return nil when there is none (the player then reports the error).
public typealias WolvyViewerTokenProvider = @Sendable (WolvyVideo) async throws -> String?

/// The three values a playback needs, the same ones the embed URL carries.
public struct WolvyVideo: CustomStringConvertible, Sendable {
    /// The video's id.
    public let videoId: String
    /// Your Wolvy account id.
    public let accountId: Int64
    /// The signed viewer token (`vt`), made on **your server**. Never put a signing secret in the app.
    public let viewerToken: String
    /// Optional: asked for a fresh token when this one is about to expire or is refused.
    public let tokenProvider: WolvyViewerTokenProvider?

    /// - Throws: ``WolvyError`` (`invalid_argument`) when a value is malformed.
    public init(videoId: String, accountId: Int64, viewerToken: String, tokenProvider: WolvyViewerTokenProvider? = nil) throws {
        guard videoId.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw WolvyError(.invalidArgument, "videoId must be 1 to 64 letters, digits, '-' or '_'.")
        }
        guard accountId > 0 else {
            throw WolvyError(.invalidArgument, "accountId must be a positive number.")
        }
        let token = viewerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw WolvyError(.invalidArgument, "viewerToken is required: sign it on your server.")
        }
        self.videoId = videoId
        self.accountId = accountId
        self.viewerToken = token
        self.tokenProvider = tokenProvider
    }

    /// When the token expires (Unix seconds), read from its payload; nil when it cannot be read.
    /// Not a verification: only Wolvy's server checks the signature.
    public var tokenExpiresAt: Int64? {
        let payload = viewerToken.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        guard let data = Base64Lenient.decode(payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (json["exp"] as? NSNumber)?.int64Value, exp > 0 else { return nil }
        return exp
    }

    /// The same video with another token (and the same provider).
    func withToken(_ token: String) throws -> WolvyVideo {
        try WolvyVideo(videoId: videoId, accountId: accountId, viewerToken: token, tokenProvider: tokenProvider)
    }

    /// No token: safe to log.
    public var description: String { "WolvyVideo(videoId: \(videoId), accountId: \(accountId))" }

    /// Reads the three values from an embed URL with a viewer token, as
    /// `POST /v1/videos/{id}/playback-tokens` returns it in `embed_url`:
    /// `https://embed.wolvy.stream/{videoId}/{base64 accountId}?vt=…`.
    ///
    /// - Throws: ``WolvyError`` (`invalid_argument`) when it is not such a URL.
    public static func fromEmbedUrl(_ url: String, tokenProvider: WolvyViewerTokenProvider? = nil) throws -> WolvyVideo {
        guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw WolvyError(.invalidArgument, "Not a URL.")
        }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else {
            throw WolvyError(.invalidArgument, "Expected https://embed.wolvy.stream/{videoId}/{base64 accountId}?vt=…")
        }
        guard let data = Base64Lenient.decode(parts[1].removingPercentEncoding ?? parts[1]),
              let text = String(data: data, encoding: .utf8),
              let account = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw WolvyError(.invalidArgument, "The second part of the path is not a base64 account id.")
        }
        guard let vt = components.queryItems?.first(where: { $0.name == "vt" })?.value, !vt.isEmpty else {
            throw WolvyError(.invalidArgument, "The URL has no vt (viewer token).")
        }
        return try WolvyVideo(videoId: parts[0], accountId: account, viewerToken: vt, tokenProvider: tokenProvider)
    }
}
