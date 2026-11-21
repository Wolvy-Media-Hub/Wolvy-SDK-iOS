import XCTest
@testable import WolvyPlayer

/// The pure logic, held to the same numbers as the Android SDK's tests.
final class LogicTests: XCTestCase {
    // MARK: Base64Lenient

    func testBase64AcceptsStandardUrlSafeAndUnpadded() {
        XCTAssertEqual(Base64Lenient.decode("MzM="), Data("33".utf8))
        XCTAssertEqual(Base64Lenient.decode("MzM"), Data("33".utf8))
        XCTAssertEqual(Base64Lenient.decode("-_8"), Data([0xFB, 0xFF]))
        XCTAssertNil(Base64Lenient.decode(""))
        XCTAssertNil(Base64Lenient.decode("a"))
        XCTAssertNil(Base64Lenient.decode("not base64!"))
    }

    // MARK: Scrub

    func testScrubRemovesTokensFromText() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJ2aWQiOiJ4In0.c2lnbmF0dXJl"
        XCTAssertEqual(Scrub.text("token \(jwt) end"), "token [token] end")
        XCTAssertEqual(Scrub.text("https://x/a?token=abc&exp=123&s=sid"), "https://x/a?token=[removed]&exp=[removed]&s=sid")
        XCTAssertEqual(Scrub.text("https://25001.wolvy-cdn.net/p/AbC-123_x/1795278353/sid/33/v/hls/playlist.m3u8"),
                       "https://25001.wolvy-cdn.net/p/[removed]/1795278353/sid/33/v/hls/playlist.m3u8")
        XCTAssertEqual(Scrub.text("X-CDN-Token: secret, other"), "X-CDN-Token: [removed], other")
    }

    func testScrubSummaryWalksUnderlyingErrors() {
        let inner = NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [NSLocalizedDescriptionKey: "offline at https://x/p/TOKEN/1/"])
        let outer = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: inner, NSLocalizedDescriptionKey: "failed"])
        let summary = Scrub.summary(outer)
        XCTAssertTrue(summary.hasPrefix("AVFoundationErrorDomain -11800: failed <- NSURLErrorDomain -1009"))
        XCTAssertFalse(summary.contains("TOKEN"))
    }

    // MARK: VttParser

    func testVttParsesTimedCuesOnly() {
        let vtt = """
        WEBVTT

        NOTE a comment
        that spans lines

        1
        00:00:01.000 --> 00:00:02.500
        <v Speaker>Hello</v> <b>world</b>

        00:03,000 --> 00:04,000
        Second line one
        Second line two

        01:00:00.000 --> 01:00:01.000
        An hour in
        """
        let cues = VttParser.parse(vtt)
        XCTAssertEqual(cues, [
            Cue(start: 1, end: 2.5, text: "Hello world"),
            Cue(start: 3, end: 4, text: "Second line one\nSecond line two"),
            Cue(start: 3600, end: 3601, text: "An hour in"),
        ])
        XCTAssertEqual(VttParser.at(cues, 1.2)?.text, "Hello world")
        XCTAssertNil(VttParser.at(cues, 2.5))
        XCTAssertNil(VttParser.at(cues, 0))
    }

    func testVttHandlesCarriageReturnsAndEmptyCues() {
        let cues = VttParser.parse("WEBVTT\r\n\r\n00:00:00.000 --> 00:00:01.000\r\n<i></i>\r\n\r\n00:00:01.000 --> 00:00:02.000\r\nok\r\n")
        XCTAssertEqual(cues, [Cue(start: 1, end: 2, text: "ok")])
    }

    // MARK: ProgressTracker (same cases as the Android SDK)

    func testContinuousPlaybackMarksEverySecondOnce() {
        let p = ProgressTracker()
        var t = 0.0
        while t <= 10 { p.tick(position: t, duration: 100, playing: true); t += 0.25 }
        XCTAssertEqual(p.seconds, 11)
        XCTAssertEqual(p.percent(duration: 100), 11)
        t = 0
        while t <= 10 { p.tick(position: t, duration: 100, playing: true); t += 0.25 }
        XCTAssertEqual(p.seconds, 11)
    }

    func testASeekMarksOnlyTheSecondPlayedNow() {
        let p = ProgressTracker()
        p.tick(position: 1, duration: 100, playing: true)
        p.tick(position: 50.2, duration: 100, playing: true)
        XCTAssertEqual(p.seconds, 2)
        p.tick(position: 51.9, duration: 100, playing: true)
        XCTAssertEqual(p.seconds, 3)
    }

    func testPausedOrUnknownDurationMarksNothing() {
        let p = ProgressTracker()
        p.tick(position: 5, duration: 100, playing: false)
        p.tick(position: 5, duration: 0, playing: true)
        XCTAssertEqual(p.seconds, 0)
        XCTAssertEqual(p.percent(duration: 0), 0)
    }

    func testPercentHasOneDecimalAndUsesWholeSeconds() {
        let p = ProgressTracker()
        p.tick(position: 0, duration: 3.9, playing: true)
        XCTAssertEqual(p.percent(duration: 3.9), 33.3)
        p.tick(position: 1, duration: 3.9, playing: true)
        p.tick(position: 2, duration: 3.9, playing: true)
        p.tick(position: 3, duration: 3.9, playing: true)
        XCTAssertEqual(p.percent(duration: 3.9), 100)
    }

    func testEmitsWhenThePercentChangesAtMostOncePerSecond() {
        let p = ProgressTracker()
        p.tick(position: 0, duration: 10, playing: true)
        XCTAssertTrue(p.shouldEmit(duration: 10, now: 5, force: false))
        XCTAssertFalse(p.shouldEmit(duration: 10, now: 5.1, force: false))
        p.tick(position: 0.5, duration: 10, playing: true)
        p.tick(position: 1.2, duration: 10, playing: true)
        XCTAssertFalse(p.shouldEmit(duration: 10, now: 5.5, force: false))
        XCTAssertTrue(p.shouldEmit(duration: 10, now: 6.001, force: false))
        p.tick(position: 2, duration: 10, playing: true)
        XCTAssertTrue(p.shouldEmit(duration: 10, now: 6.1, force: true))
    }

    // MARK: WatermarkPlacer

    func testStaticWatermarkUsesTheCorner() {
        XCTAssertEqual(WatermarkPlacer.place(mode: "static", position: "top-left"), .corner(top: true, left: true))
        XCTAssertEqual(WatermarkPlacer.place(mode: "static", position: "bottom-left"), .corner(top: false, left: true))
        XCTAssertEqual(WatermarkPlacer.place(mode: "static", position: ""), .corner(top: false, left: false))
    }

    func testMovingWatermarkStaysInItsRanges() {
        for _ in 0 ..< 500 {
            guard case let .moving(left, top) = WatermarkPlacer.place(mode: "moving", position: "x") else { return XCTFail() }
            XCTAssertTrue((0.02 ... 0.78).contains(left))
            XCTAssertTrue((0.04 ... 0.85).contains(top))
        }
    }

    // MARK: RecoveryPolicy

    func testRecoveryReloadsThreeTimesThenFails() {
        let r = RecoveryPolicy()
        XCTAssertEqual(r.onError(), .reload)
        XCTAssertEqual(r.onError(), .reload)
        XCTAssertEqual(r.onError(), .reload)
        XCTAssertEqual(r.onError(), .fail)
        r.reset()
        XCTAssertEqual(r.onError(), .reload)
    }

    func testRecoveryCountStartsAgainAfterAMinuteOfPlayback() {
        let r = RecoveryPolicy()
        _ = r.onError()
        r.onReload(position: 30)
        r.onPosition(89)
        XCTAssertEqual(r.reloads, 1)
        r.onPosition(91)
        XCTAssertEqual(r.reloads, 0)
    }

    // MARK: FairPlay key ids and error kinds

    func testAssetIdComesFromTheSkdAddress() {
        XCTAssertEqual(FairPlayKeys.assetId(fromKeyIdentifier: "skd://457d8021e1d871389d84"), "457d8021e1d871389d84")
        XCTAssertEqual(FairPlayKeys.assetId(fromKeyIdentifier: "skd://abc?x=1"), "abc")
        XCTAssertEqual(FairPlayKeys.assetId(fromKeyIdentifier: "plain"), "plain")
    }

    @MainActor
    func testNetworkErrorsAreRecognisedThroughUnderlyingErrors() {
        let url = NSError(domain: NSURLErrorDomain, code: -1009)
        XCTAssertTrue(WolvyPlayer.isNetwork(NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: url])))
        XCTAssertTrue(WolvyPlayer.isNetwork(NSError(domain: "CoreMediaErrorDomain", code: -12660)))
        XCTAssertFalse(WolvyPlayer.isNetwork(NSError(domain: "CoreMediaErrorDomain", code: -42800)))
        XCTAssertFalse(WolvyPlayer.isNetwork(nil))
    }

    @MainActor
    func testQualityCeiling() {
        XCTAssertEqual(WolvyPlayer.ceiling(nil), .zero)
        XCTAssertEqual(WolvyPlayer.ceiling(720), CGSize(width: 10_000, height: 720))
    }

    @MainActor
    func testTimeFormat() {
        XCTAssertEqual(WolvyPlayerView.format(0), "0:00")
        XCTAssertEqual(WolvyPlayerView.format(81.7), "1:21")
        XCTAssertEqual(WolvyPlayerView.format(3725), "1:02:05")
        XCTAssertEqual(WolvyPlayerView.format(.nan), "0:00")
        XCTAssertEqual(WolvyPlayerView.rateText(1.25), "1.25")
        XCTAssertEqual(WolvyPlayerView.rateText(2), "2")
        XCTAssertNotNil(WolvyPlayerView.color(hex: "#7C3AED"))
        XCTAssertNil(WolvyPlayerView.color(hex: "7C3AED"))
    }
}
