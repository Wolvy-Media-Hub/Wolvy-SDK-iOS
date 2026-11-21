import XCTest
@testable import WolvyPlayer

/// Builds a viewer token with the given expiry (the signature is never checked by the SDK).
func token(exp: Int64) -> String {
    let payload = Data("{\"vid\":\"student-1\",\"exp\":\(exp)}".utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    return "\(payload).c2ln"
}

let sampleAnswer: [String: Any] = [
    "status": "success", "platform": "sdk",
    "session_id": "5a0d57254ab7a7f8b899a650a234fc35",
    "token": "eyJhbGciOiJIUzI1NiJ9.eyJzcmMiOiJzZGsifQ.sig/+=",
    "expires_in": 300,
    "poster": "https://cdn.example/poster.jpg",
    "server_id": 25001,
    "duration": "81.5",
    "captions": [["language_code": "en", "label": "English"], ["language_code": "ar", "label": ""], ["label": "no code"]],
    "chapters": [["start": 40, "end": 81, "title": "Two"], ["start": 0, "end": 40, "title": "One"]],
    "moments": [["timestamp": 12.5, "label": "Key point"]],
    "cdn_token": "AbC-123_x", "cdn_exp": 1_795_278_353,
    "player_color": "#FF0055",
    "viewer_id": "spike-test",
    "watermark": ["enabled": true, "mode": "static", "position": "top-left", "opacity": 140],
    "app_only_l3": false,
]

final class VideoAndDataTests: XCTestCase {
    func testVideoValidatesItsValues() throws {
        XCTAssertNoThrow(try WolvyVideo(videoId: "abc_DEF-1", accountId: 33, viewerToken: "t"))
        XCTAssertThrowsError(try WolvyVideo(videoId: "bad id", accountId: 33, viewerToken: "t"))
        XCTAssertThrowsError(try WolvyVideo(videoId: "v", accountId: 0, viewerToken: "t"))
        XCTAssertThrowsError(try WolvyVideo(videoId: "v", accountId: 33, viewerToken: "  ")) { error in
            XCTAssertEqual((error as? WolvyError)?.code, .invalidArgument)
        }
    }

    func testVideoReadsTheEmbedUrl() throws {
        let v = try WolvyVideo.fromEmbedUrl("https://embed.wolvy.stream/457d8021e1d871389d84/MzM=?vt=abc.def")
        XCTAssertEqual(v.videoId, "457d8021e1d871389d84")
        XCTAssertEqual(v.accountId, 33)
        XCTAssertEqual(v.viewerToken, "abc.def")
        XCTAssertEqual(try WolvyVideo.fromEmbedUrl(" https://embed.wolvy.stream/v/MzM?vt=x ").accountId, 33)
        XCTAssertThrowsError(try WolvyVideo.fromEmbedUrl("https://embed.wolvy.stream/v/MzM"))
        XCTAssertThrowsError(try WolvyVideo.fromEmbedUrl("https://embed.wolvy.stream/v?vt=x"))
        XCTAssertThrowsError(try WolvyVideo.fromEmbedUrl("https://embed.wolvy.stream/v/bm90YW51bWJlcg==?vt=x"))
    }

    func testTokenExpiryIsReadFromThePayloadAndNeverPrinted() throws {
        let v = try WolvyVideo(videoId: "v", accountId: 1, viewerToken: token(exp: 1_800_000_000))
        XCTAssertEqual(v.tokenExpiresAt, 1_800_000_000)
        XCTAssertNil(try WolvyVideo(videoId: "v", accountId: 1, viewerToken: "garbage").tokenExpiresAt)
        XCTAssertFalse(v.description.contains(v.viewerToken))
    }

    func testPlaybackDataReadsTheAnswer() throws {
        let d = try WolvyPlaybackData.fromJSON(sampleAnswer)
        XCTAssertEqual(d.serverId, "25001")
        XCTAssertEqual(d.sessionId, "5a0d57254ab7a7f8b899a650a234fc35")
        XCTAssertEqual(d.duration, 81.5)
        XCTAssertEqual(d.captions, [WolvyCaptionTrack(language: "en", label: "English"), WolvyCaptionTrack(language: "ar", label: "ar")])
        XCTAssertEqual(d.chapters.map(\.title), ["One", "Two"])
        XCTAssertEqual(d.moments, [WolvyMoment(timestamp: 12.5, label: "Key point")])
        XCTAssertEqual(d.playerColor, "#FF0055")
        XCTAssertEqual(d.viewerId, "spike-test")
        XCTAssertEqual(d.watermark, WolvyWatermark(enabled: true, mode: "static", position: "top-left", opacity: 100))
        XCTAssertFalse(d.appOnly)
    }

    func testPlaybackDataBuildsTheAddresses() throws {
        let d = try WolvyPlaybackData.fromJSON(sampleAnswer)
        let v = try WolvyVideo(videoId: "457d8021e1d871389d84", accountId: 33, viewerToken: "t")
        XCTAssertEqual(d.playlistUrl(v).absoluteString,
                       "https://25001.wolvy-cdn.net/p/AbC-123_x/1795278353/5a0d57254ab7a7f8b899a650a234fc35/33/457d8021e1d871389d84/hls/playlist.m3u8")
        XCTAssertEqual(d.licenceUrl.absoluteString,
                       "https://wolvy.net/api/process_videos/fairplay?token=eyJhbGciOiJIUzI1NiJ9.eyJzcmMiOiJzZGsifQ.sig%2F%2B%3D")
        XCTAssertEqual(d.certificateUrl.absoluteString, "https://wolvy.net/api/process_videos/fairplay.cer")
        XCTAssertEqual(d.captionUrl(v, language: "en").absoluteString, "https://25001.wolvy-cdn.net/33/457d8021e1d871389d84/captions/en.vtt")

        var noSession = sampleAnswer
        noSession["session_id"] = ""
        XCTAssertEqual(try WolvyPlaybackData.fromJSON(noSession).playlistUrl(v).absoluteString,
                       "https://25001.wolvy-cdn.net/p/AbC-123_x/1795278353/33/457d8021e1d871389d84/hls/playlist.m3u8")
    }

    func testPlaybackDataDefaultsAndRefusals() throws {
        let minimal = try WolvyPlaybackData.fromJSON(["token": "t", "server_id": "25002", "player_color": "red"])
        XCTAssertEqual(minimal.watermark, WolvyWatermark(enabled: false, mode: "moving", position: "bottom-right", opacity: 40))
        XCTAssertNil(minimal.playerColor)
        XCTAssertEqual(minimal.licenceTokenTtlSeconds, 300)
        XCTAssertThrowsError(try WolvyPlaybackData.fromJSON(["server_id": "1"])) { error in
            XCTAssertEqual((error as? WolvyError)?.reason, "bad_answer")
        }
    }

    func testServerRefusalsMapToTheWebCodes() {
        XCTAssertEqual(WolvyError.fromServer(status: 403, serverCode: "app_not_allowed", message: "Add the app").code, .playbackError)
        XCTAssertEqual(WolvyError.fromServer(status: 429, serverCode: "rate_limited", message: nil).code, .networkError)
        XCTAssertEqual(WolvyError.fromServer(status: 502, serverCode: nil, message: nil).code, .networkError)
        XCTAssertEqual(WolvyError.fromServer(status: 400, serverCode: nil, message: nil).reason, "http_400")
        XCTAssertEqual(WolvyError.fromServer(status: 400, serverCode: nil, message: nil).code, .failed)
    }

    func testErrorDetailIsScrubbed() {
        let e = WolvyError(.failed, "x", detail: "GET https://a/b?token=secret")
        XCTAssertEqual(e.detail, "GET https://a/b?token=[removed]")
    }
}

// MARK: - The app endpoint over a stubbed network

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.lastBody = String(decoding: data, as: UTF8.self)
        } else {
            Self.lastBody = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
        }
        do {
            let (status, body) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class SourceTests: XCTestCase {
    private func source() -> WolvyAppRenderVideoSource {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return WolvyAppRenderVideoSource(appId: "net.wolvy.sample", sdk: "wolvy-ios/0.1.0",
                                         apiBase: URL(string: "https://wolvy.net/api")!, session: URLSession(configuration: config))
    }

    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    func testAsksAsAnIosAppAndReadsTheAnswer() async throws {
        StubProtocol.handler = { _ in (200, self.json(sampleAnswer)) }
        let video = try WolvyVideo(videoId: "457d8021e1d871389d84", accountId: 33, viewerToken: "a+b/c=")
        let data = try await source().fetch(video: video, sessionId: "5a0d57254ab7a7f8b899a650a234fc35")
        XCTAssertEqual(data.serverId, "25001")
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://wolvy.net/api/app_render_video")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Wolvy-Platform"), "ios")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Wolvy-App-Id"), "net.wolvy.sample")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Wolvy-SDK"), "wolvy-ios/0.1.0")
        XCTAssertEqual(StubProtocol.lastBody,
                       "user_id=33&video_id=457d8021e1d871389d84&vt=a%2Bb%2Fc%3D&session_id=5a0d57254ab7a7f8b899a650a234fc35")
    }

    func testRefusalsBecomeWolvyErrors() async throws {
        let video = try WolvyVideo(videoId: "v", accountId: 33, viewerToken: "t")
        StubProtocol.handler = { _ in (403, self.json(["status": "error", "code": "app_not_allowed", "message": "Add the app."])) }
        do { _ = try await source().fetch(video: video, sessionId: nil); XCTFail() } catch let e as WolvyError {
            XCTAssertEqual(e.code, .playbackError)
            XCTAssertEqual(e.reason, "app_not_allowed")
            XCTAssertEqual(e.message, "Add the app.")
        }
        StubProtocol.handler = { _ in (502, Data("<html>bad gateway</html>".utf8)) }
        do { _ = try await source().fetch(video: video, sessionId: nil); XCTFail() } catch let e as WolvyError {
            XCTAssertEqual(e.code, .networkError)
            XCTAssertEqual(e.reason, "http_502")
        }
        StubProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await source().fetch(video: video, sessionId: nil); XCTFail() } catch let e as WolvyError {
            XCTAssertEqual(e.code, .networkError)
            XCTAssertEqual(e.reason, "network")
        }
    }
}

// MARK: - Short tokens: the fetcher and the provider

actor FakeSource: WolvyPlaybackSource {
    var tokensSeen: [String] = []
    let refuse: Set<String>

    init(refuse: Set<String>) { self.refuse = refuse }

    func fetch(video: WolvyVideo, sessionId: String?) async throws -> WolvyPlaybackData {
        tokensSeen.append(video.viewerToken)
        if refuse.contains(video.viewerToken) {
            throw WolvyError(.playbackError, "Bad token.", reason: "viewer_token_required")
        }
        return try WolvyPlaybackData.fromJSON(sampleAnswer)
    }
}

final class FetcherTests: XCTestCase {
    let now: Int64 = 1_800_000_000

    func testRefreshesATokenAboutToExpireBeforeAsking() async throws {
        let old = token(exp: now + 30)
        let fresh = token(exp: now + 600)
        let source = FakeSource(refuse: [])
        let video = try WolvyVideo(videoId: "v", accountId: 1, viewerToken: old) { _ in fresh }
        XCTAssertTrue(PlaybackFetcher.needsRefresh(video, now: now))
        let (used, _) = try await PlaybackFetcher(source: source).fetch(video, sessionId: nil, now: now)
        XCTAssertEqual(used.viewerToken, fresh)
        let seen = await source.tokensSeen
        XCTAssertEqual(seen, [fresh])
    }

    func testAsksOnceMoreWhenTheServerRefusesTheToken() async throws {
        let old = token(exp: now + 600)
        let fresh = token(exp: now + 900)
        let source = FakeSource(refuse: [old])
        let video = try WolvyVideo(videoId: "v", accountId: 1, viewerToken: old) { _ in fresh }
        XCTAssertFalse(PlaybackFetcher.needsRefresh(video, now: now))
        let (used, _) = try await PlaybackFetcher(source: source).fetch(video, sessionId: nil, now: now)
        XCTAssertEqual(used.viewerToken, fresh)
        let seen = await source.tokensSeen
        XCTAssertEqual(seen, [old, fresh])
    }

    func testWithoutAProviderTheRefusalStands() async throws {
        let old = token(exp: now + 600)
        let video = try WolvyVideo(videoId: "v", accountId: 1, viewerToken: old)
        do { _ = try await PlaybackFetcher(source: FakeSource(refuse: [old])).fetch(video, sessionId: nil, now: now); XCTFail() } catch let e as WolvyError {
            XCTAssertEqual(e.reason, "viewer_token_required")
        }
    }

    func testAProviderThatFailsOrGivesNothing() async throws {
        let old = token(exp: now + 10)
        let throwing = try WolvyVideo(videoId: "v", accountId: 1, viewerToken: old) { _ in throw URLError(.timedOut) }
        do { _ = try await PlaybackFetcher(source: FakeSource(refuse: [])).fetch(throwing, sessionId: nil, now: now); XCTFail() } catch let e as WolvyError {
            XCTAssertEqual(e.reason, "token_provider_failed")
            XCTAssertEqual(e.code, .networkError)
        }
        let empty = try WolvyVideo(videoId: "v", accountId: 1, viewerToken: old) { _ in nil }
        do { _ = try await PlaybackFetcher(source: FakeSource(refuse: [])).fetch(empty, sessionId: nil, now: now); XCTFail() } catch let e as WolvyError {
            XCTAssertEqual(e.reason, "viewer_token_required")
        }
    }
}

// MARK: - The player's contract before a video plays

@MainActor
final class Recorder: WolvyPlayerListener {
    var errors: [WolvyError] = []
    var rates: [Float] = []
    func onError(_ error: WolvyError) { errors.append(error) }
    func onRateChange(_ playbackRate: Float) { rates.append(playbackRate) }
}

struct RefusingSource: WolvyPlaybackSource {
    func fetch(video: WolvyVideo, sessionId: String?) async throws -> WolvyPlaybackData {
        throw WolvyError(.playbackError, "Add the app.", reason: "app_not_allowed")
    }
}

@MainActor
final class PlayerTests: XCTestCase {
    func testARefusalIsReportedAndThenThrownByEveryControl() async throws {
        let player = WolvyPlayer(source: RefusingSource())
        let recorder = Recorder()
        player.addListener(recorder)
        try player.load(WolvyVideo(videoId: "v", accountId: 1, viewerToken: "t"))
        for _ in 0 ..< 50 where recorder.errors.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(recorder.errors.map(\.reason), ["app_not_allowed"])
        XCTAssertThrowsError(try player.play()) { XCTAssertEqual(($0 as? WolvyError)?.reason, "app_not_allowed") }
    }

    func testControlsCheckTheirArguments() throws {
        let player = WolvyPlayer(source: RefusingSource())
        let recorder = Recorder()
        player.addListener(recorder)
        XCTAssertThrowsError(try player.setPlaybackRate(3)) { XCTAssertEqual(($0 as? WolvyError)?.code, .invalidArgument) }
        try player.setPlaybackRate(1.5)
        XCTAssertEqual(recorder.rates, [1.5])
        XCTAssertEqual(player.playbackRate, 1.5)
        XCTAssertThrowsError(try player.setVolume(2)) { XCTAssertEqual(($0 as? WolvyError)?.code, .invalidArgument) }
        XCTAssertThrowsError(try player.seek(10)) { XCTAssertEqual(($0 as? WolvyError)?.code, .notReady) }
        XCTAssertThrowsError(try player.setQuality(720)) { XCTAssertEqual(($0 as? WolvyError)?.code, .notReady) }
        XCTAssertThrowsError(try player.setCaptions("en")) { XCTAssertEqual(($0 as? WolvyError)?.code, .notReady) }
        XCTAssertEqual(player.getState(), WolvyState(currentTime: 0, duration: 0, paused: true, muted: false, volume: 1, playbackRate: 1.5))
        XCTAssertNil(player.videoInfo)
    }

    func testReleaseMakesEveryCallThrowDestroyed() throws {
        let player = WolvyPlayer(source: RefusingSource())
        player.release()
        XCTAssertThrowsError(try player.play()) { XCTAssertEqual(($0 as? WolvyError)?.code, .destroyed) }
        XCTAssertThrowsError(try player.load(WolvyVideo(videoId: "v", accountId: 1, viewerToken: "t"))) {
            XCTAssertEqual(($0 as? WolvyError)?.code, .destroyed)
        }
    }

    func testListenersAreHeldWeakly() throws {
        let player = WolvyPlayer(source: RefusingSource())
        var recorder: Recorder? = Recorder()
        weak var weakRecorder: Recorder?
        weakRecorder = recorder
        player.addListener(recorder!)
        recorder = nil
        XCTAssertNil(weakRecorder)
        try player.setPlaybackRate(2)   // no crash with the listener gone
    }
}
