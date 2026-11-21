import Foundation

/// Where playback data comes from. The default, ``WolvyAppRenderVideoSource``, asks
/// `https://wolvy.net/api/app_render_video`.
public protocol WolvyPlaybackSource: Sendable {
    /// Returns playback data for `video`.
    ///
    /// - Parameter sessionId: set when the player asks again during the same viewing (a fresh
    ///   licence or CDN token after an error); send it back so the viewing stays one session.
    /// - Throws: ``WolvyError`` when the video cannot be played.
    func fetch(video: WolvyVideo, sessionId: String?) async throws -> WolvyPlaybackData
}

/// The SDK's own source: `POST {apiBase}/app_render_video` as an iOS app, with the app's bundle id.
/// The bundle id must be on the account's Allowed apps (Settings → Protection, platform iOS).
///
/// With `appProtection` (the default), it also proves the app is genuine when the account has set
/// up app protection for it (the dashboard's Protection panel: the Apple team id), with Apple's
/// App Attest. A proven app signs its requests and is treated like Wolvy Player. Without the
/// setup, or when the proof fails, it plays unproven, as before, unless the account only allows
/// proven apps.
public struct WolvyAppRenderVideoSource: WolvyPlaybackSource {
    /// The bundle id sent as X-Wolvy-App-Id.
    public let appId: String
    /// The SDK's name and version, sent as X-Wolvy-SDK (the wrappers send their own).
    public let sdk: String
    public let apiBase: URL
    let session: URLSession
    let attestor: AppAttestor?
    let clock: @Sendable () -> Int64

    public init(appId: String = Bundle.main.bundleIdentifier ?? "",
                sdk: String = "wolvy-ios/\(WolvyPlayer.sdkVersion)",
                apiBase: URL = WolvyPlaybackData.defaultApiBase,
                appProtection: Bool = true) {
        let attestor = appProtection
            ? AppAttestor(appId: appId, sdk: sdk, apiBase: apiBase, service: AppleAppAttest(),
                          store: KeychainAttestKeyStore(appId: appId), post: wolvyPostForm(session: .shared))
            : nil
        self.init(appId: appId, sdk: sdk, apiBase: apiBase, session: .shared, attestor: attestor)
    }

    init(appId: String, sdk: String, apiBase: URL, session: URLSession, attestor: AppAttestor? = nil,
         clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.appId = appId
        self.sdk = sdk
        self.apiBase = apiBase
        self.session = session
        self.attestor = attestor
        self.clock = clock
    }

    public func fetch(video: WolvyVideo, sessionId: String?) async throws -> WolvyPlaybackData {
        do {
            return try await once(video: video, sessionId: sessionId)
        } catch let error as WolvyError where attestor != nil && (error.reason == "app_key_expired" || error.reason == "app_key_invalid") {
            // Wolvy no longer takes the app key: prove the app again, once.
            await attestor?.invalidate()
            return try await once(video: video, sessionId: sessionId)
        }
    }

    private func once(video: WolvyVideo, sessionId: String?) async throws -> WolvyPlaybackData {
        let key = await attestor?.keyFor(video.accountId)
        var request = URLRequest(url: apiBase.appendingPathComponent("app_render_video"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ios", forHTTPHeaderField: "X-Wolvy-Platform")
        request.setValue(appId, forHTTPHeaderField: "X-Wolvy-App-Id")
        request.setValue(sdk, forHTTPHeaderField: "X-Wolvy-SDK")
        if let key {
            let ts = clock()
            request.setValue(key.keyId, forHTTPHeaderField: "X-Wolvy-App-Key-Id")
            request.setValue(String(ts), forHTTPHeaderField: "X-Wolvy-App-Timestamp")
            request.setValue(AppSigning.renderSignature(key: key.key, videoId: video.videoId, accountId: video.accountId, timestamp: ts),
                             forHTTPHeaderField: "X-Wolvy-App-Signature")
        }
        var fields = [
            "user_id=\(video.accountId)",
            "video_id=\(WolvyPlaybackData.encode(video.videoId))",
            "vt=\(WolvyPlaybackData.encode(video.viewerToken))",
        ]
        if let sessionId, !sessionId.isEmpty { fields.append("session_id=\(WolvyPlaybackData.encode(sessionId))") }
        request.httpBody = fields.joined(separator: "&").data(using: .utf8)

        let body: Data
        let status: Int
        do {
            let (data, response) = try await session.data(for: request)
            body = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw WolvyError(.networkError, "Could not reach Wolvy.", reason: "network", detail: Scrub.summary(error))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw WolvyError(status >= 500 ? .networkError : .failed, "Wolvy answered HTTP \(status) without JSON.", reason: "http_\(status)")
        }
        guard WolvyPlaybackData.string(json["status"]) == "success" else {
            let code = WolvyPlaybackData.string(json["code"]).flatMap { $0.isEmpty ? nil : $0 }
            // The account only allows proven apps, and Wolvy refused this app's proof: say why.
            if code == "attestation_required", let refusal = await attestor?.refusal() { throw refusal }
            throw WolvyError.fromServer(status: status, serverCode: code, message: WolvyPlaybackData.string(json["message"]))
        }
        var data = try WolvyPlaybackData.fromJSON(json, apiBase: apiBase)
        if let key, data.attested {
            data.licenceKey = key.key
            data.clock = clock
        }
        return data
    }
}

/// Asks the source, refreshing the viewer token through the video's provider when it is about to
/// expire, and once more when the server refuses it. Returns the video with the token that
/// worked, so the next reload uses it.
struct PlaybackFetcher {
    /// Refresh when the token has this little time left: covers the request and a slow network.
    static let refreshMargin: Int64 = 60

    let source: WolvyPlaybackSource

    static func needsRefresh(_ video: WolvyVideo, now: Int64) -> Bool {
        guard video.tokenProvider != nil, let exp = video.tokenExpiresAt else { return false }
        return exp - now <= refreshMargin
    }

    func fetch(_ video: WolvyVideo, sessionId: String?, now: Int64) async throws -> (WolvyVideo, WolvyPlaybackData) {
        var current = video
        var refreshed = false
        if Self.needsRefresh(current, now: now) {
            current = try await refresh(current)
            refreshed = true
        }
        do {
            return (current, try await source.fetch(video: current, sessionId: sessionId))
        } catch let error as WolvyError {
            guard error.reason == "viewer_token_required", current.tokenProvider != nil, !refreshed else { throw error }
            current = try await refresh(current)
            return (current, try await source.fetch(video: current, sessionId: sessionId))
        }
    }

    private func refresh(_ video: WolvyVideo) async throws -> WolvyVideo {
        guard let provider = video.tokenProvider else { return video }
        let token: String?
        do {
            token = try await provider(video)
        } catch {
            throw WolvyError(.networkError, "A fresh viewer token could not be fetched.",
                             reason: "token_provider_failed", detail: Scrub.summary(error))
        }
        guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WolvyError(.playbackError, "No fresh viewer token was given.", reason: "viewer_token_required")
        }
        return try video.withToken(token)
    }
}
