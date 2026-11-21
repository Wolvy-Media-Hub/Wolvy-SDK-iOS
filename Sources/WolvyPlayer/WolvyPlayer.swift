import AVFoundation
import UIKit

/// Plays Wolvy video: HLS with FairPlay through AVPlayer, the account's watermark and look, and
/// the web Player API's methods and events. Show it in a ``WolvyPlayerView``.
///
/// ```swift
/// let player = WolvyPlayer()
/// playerView.player = player
/// player.addListener(self)   // a WolvyPlayerListener: onProgress, onError…
/// try player.load(WolvyVideo(videoId: id, accountId: account, viewerToken: tokenFromYourServer))
/// ```
///
/// iOS itself keeps FairPlay video out of screenshots, recordings and screen mirroring (the
/// picture is black there). Call it on the main thread.
@MainActor
public final class WolvyPlayer: NSObject {
    /// This SDK's version, sent to Wolvy as `X-Wolvy-SDK: wolvy-ios/<version>`.
    public nonisolated static let sdkVersion = "0.2.0"

    let avPlayer = AVPlayer()
    private let source: WolvyPlaybackSource
    private let fetcher: PlaybackFetcher
    private let userAgent: String

    private var listeners: [WeakListener] = []
    private var keys: FairPlayKeys?
    private var video: WolvyVideo?
    private var data: WolvyPlaybackData?
    private var generation = 0
    private var readySent = false
    private var fatal: WolvyError?
    private var released = false
    private var wantPlay = false
    private var rate: Float = 1
    private var userVolume: Float = 1
    private var muted = false
    private var heights: [Int] = []
    private var selectedHeight: Int?
    private var lastQualities: WolvyQualities?
    private var captionLanguage: String?
    private var cues: [Cue] = []
    private var cueText: String?
    private var recovery = RecoveryPolicy()
    private let progress = ProgressTracker()
    private var licenceFailure: FairPlayKeys.Failure?
    private var itemObservations: [NSKeyValueObservation] = []
    private var itemNotes: [NSObjectProtocol] = []
    private var playerNotes: [NSObjectProtocol] = []
    private var timeControlObservation: NSKeyValueObservation?
    private var ticker: Timer?
    private var playingSent: Bool?

    /// - Parameter source: where playback data comes from; by default `app_render_video` with this app's bundle id.
    public init(source: WolvyPlaybackSource = WolvyAppRenderVideoSource()) {
        self.source = source
        fetcher = PlaybackFetcher(source: source)
        let app = Bundle.main.bundleIdentifier ?? "app"
        userAgent = "wolvy-ios/\(Self.sdkVersion) (iOS \(UIDevice.current.systemVersion); \(app))"
        super.init()
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        timeControlObservation = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.onTimeControl(status) }
        }
        let center = NotificationCenter.default
        playerNotes.append(center.addObserver(forName: AVPlayer.rateDidChangeNotification, object: avPlayer, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVPlayer.rateDidChangeReasonKey] as? AVPlayer.RateDidChangeReason
            Task { @MainActor in self?.onRateChanged(reason) }
        })
        playerNotes.append(center.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { [weak self] note in
            let captured = (note.object as? UIScreen)?.isCaptured ?? false
            Task { @MainActor in self?.emit { $0.onScreenCaptureChange(captured) } }
        })
    }

    deinit {
        ticker?.invalidate()
        playerNotes.forEach(NotificationCenter.default.removeObserver)
        itemNotes.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Loading

    /// Loads `video` (and stops whatever was playing). Playback starts when the video is ready, if `autoplay`.
    public func load(_ video: WolvyVideo, autoplay: Bool = true) throws {
        if released { throw Self.destroyed }
        self.video = video
        data = nil
        fatal = nil
        readySent = false
        playingSent = nil
        wantPlay = autoplay
        recovery = RecoveryPolicy()
        progress.reset()
        heights = []
        selectedHeight = nil
        lastQualities = nil
        licenceFailure = nil
        clearCaptions()
        tearDownItem()
        generation += 1
        let gen = generation
        fetch(gen, sessionId: nil) { [weak self] d in
            self?.data = d
            self?.prepare(start: 0)
        }
    }

    /// After an error: try again from where playback stopped.
    public func retry() throws {
        if released { throw Self.destroyed }
        guard let video else { return }
        guard data != nil else { try load(video, autoplay: wantPlay); return }
        fatal = nil
        recovery.reset()
        reload()
    }

    private func fetch(_ gen: Int, sessionId: String?, then: @escaping (WolvyPlaybackData) -> Void) {
        guard let video else { return }
        let fetcher = self.fetcher
        Task { [weak self] in
            let result: Result<(WolvyVideo, WolvyPlaybackData), WolvyError>
            do {
                result = .success(try await fetcher.fetch(video, sessionId: sessionId, now: Int64(Date().timeIntervalSince1970)))
            } catch let error as WolvyError {
                result = .failure(error)
            } catch {
                result = .failure(WolvyError(.failed, "Playback data could not be read.", reason: "source_failed", detail: Scrub.summary(error)))
            }
            guard let self, !self.released, gen == self.generation else { return }
            switch result {
            case let .success((usedVideo, d)):
                self.video = usedVideo   // keep the token that worked (it may be a fresh one) for the next reload
                then(d)
            case let .failure(error):
                self.fail(error)
            }
        }
    }

    private func prepare(start: Double) {
        guard let video, let data else { return }
        configureAudioSession()
        tearDownItem()
        licenceFailure = nil
        let asset = AVURLAsset(url: data.playlistUrl(video))
        let keys = FairPlayKeys(licenceUrl: data.licenceUrl, certificateUrl: data.certificateUrl, userAgent: userAgent,
                                licenceHeaders: { data.licenceHeaders() }) { [weak self] failure in
            Task { @MainActor in self?.licenceFailure = failure }
        }
        keys.attach(asset)
        self.keys = keys
        let item = AVPlayerItem(asset: asset)
        item.preferredMaximumResolution = Self.ceiling(selectedHeight)
        observe(item)
        avPlayer.replaceCurrentItem(with: item)
        if start > 0 {
            avPlayer.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        applyVolume()
        if wantPlay { avPlayer.rate = rate }
        loadQualities(asset)
        startTicker()
    }

    private func reload() {
        let position = currentTime
        recovery.onReload(position: position)
        fetch(generation, sessionId: data?.sessionId) { [weak self] d in
            self?.data = d
            self?.prepare(start: position)
        }
    }

    private func tearDownItem() {
        itemObservations.forEach { $0.invalidate() }
        itemObservations = []
        itemNotes.forEach(NotificationCenter.default.removeObserver)
        itemNotes = []
        avPlayer.replaceCurrentItem(with: nil)
        keys = nil
    }

    /// A video player's audio should play with the silent switch on; an app that set its own category keeps it.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        if session.category == .soloAmbient {
            try? session.setCategory(.playback, mode: .moviePlayback)
        }
    }

    // MARK: - Observing

    private func observe(_ item: AVPlayerItem) {
        itemObservations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error
            Task { @MainActor in self?.onItemStatus(status, error: error) }
        })
        itemObservations.append(item.observe(\.presentationSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.emitQuality() }
        })
        let center = NotificationCenter.default
        itemNotes.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onEnded() }
        })
        itemNotes.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in self?.onPlaybackError(error) }
        })
    }

    private func onItemStatus(_ status: AVPlayerItem.Status, error: Error?) {
        switch status {
        case .readyToPlay:
            if !readySent, data != nil {
                readySent = true
                let state = getState()
                emit { $0.onReady(state) }
                emitQuality()
            }
        case .failed:
            onPlaybackError(error)
        default:
            break
        }
    }

    private func onTimeControl(_ status: AVPlayer.TimeControlStatus) {
        guard readySent else { return }
        switch status {
        case .playing where playingSent != true:
            playingSent = true
            let t = currentTime
            emit { $0.onPlay(t) }
        case .paused where playingSent == true:
            playingSent = false
            let t = currentTime
            emit { $0.onPause(t) }
        default:
            break
        }
    }

    /// The system paused (an interruption, the app went to the background): the player is now paused.
    private func onRateChanged(_ reason: AVPlayer.RateDidChangeReason?) {
        guard avPlayer.rate == 0, let reason else { return }
        if reason == .audioSessionInterrupted || reason == .appBackgrounded { wantPlay = false }
    }

    private func onEnded() {
        wantPlay = false
        emitProgress(force: true)
        emit { $0.onEnded() }
    }

    // MARK: - Errors and recovery

    private func onPlaybackError(_ error: Error?) {
        guard fatal == nil else { return }
        let detail = error.map(Scrub.summary) ?? "unknown"
        guard data != nil else {
            fail(WolvyError(.failed, "Playback failed.", reason: "playback_failed", detail: detail))
            return
        }
        let licence = licenceFailure
        switch recovery.onError() {
        case .reload:
            // A licence token or CDN token that ran out, or a network drop AVPlayer did not ride out:
            // fresh playback data for the same session, then resume at the same position.
            reload()
        case .fail:
            let network = licence == nil && Self.isNetwork(error)
            fail(WolvyError(network ? .networkError : .playbackError,
                            "This video could not be played on this device.",
                            reason: licence != nil ? "licence_refused" : (network ? "network" : "playback_failed"),
                            detail: licence.map { "licence HTTP \($0.status): \($0.detail)" } ?? detail))
        }
    }

    static func isNetwork(_ error: Error?) -> Bool {
        var current = error as NSError?
        while let e = current {
            if e.domain == NSURLErrorDomain { return true }
            if e.domain == "CoreMediaErrorDomain", (-12999 ... -12000).contains(e.code) { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private func fail(_ error: WolvyError) {
        guard fatal == nil else { return }
        fatal = error
        avPlayer.pause()
        NSLog("[WolvyPlayer] %@", error.description)
        emit { $0.onError(error) }
    }

    // MARK: - Qualities

    /// The heights on offer, from the HLS master playlist.
    private func loadQualities(_ asset: AVURLAsset) {
        let gen = generation
        asset.loadValuesAsynchronously(forKeys: ["variants"]) { [weak self] in
            guard asset.statusOfValue(forKey: "variants", error: nil) == .loaded else { return }
            let found = Set(asset.variants.compactMap { variant -> Int? in
                guard let h = variant.videoAttributes?.presentationSize.height, h > 0 else { return nil }
                return Int(h.rounded())
            })
            Task { @MainActor in
                guard let self, gen == self.generation, !found.isEmpty else { return }
                self.heights = found.sorted(by: >)
                self.emitQuality()
            }
        }
    }

    static func ceiling(_ height: Int?) -> CGSize {
        guard let height else { return .zero }
        return CGSize(width: 10_000, height: height)
    }

    private func emitQuality() {
        let q = getQualities()
        guard q != lastQualities else { return }
        lastQualities = q
        emit { $0.onQualityChange(q) }
    }

    // MARK: - The tick: timeupdate, progress, captions

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard readySent, !released else { return }
        let t = currentTime
        let d = duration
        let playing = avPlayer.timeControlStatus == .playing
        progress.tick(position: t, duration: d, playing: playing)
        recovery.onPosition(t)
        if playing { emit { $0.onTimeUpdate(t, duration: d) } }
        emitProgress(force: false)
        updateCue(t)
    }

    private func emitProgress(force: Bool) {
        let d = duration
        guard progress.shouldEmit(duration: d, now: ProcessInfo.processInfo.systemUptime, force: force) else { return }
        let p = WolvyProgress(percent: progress.percent(duration: d), seconds: progress.seconds, duration: d)
        emit { $0.onProgress(p) }
    }

    private func updateCue(_ t: Double) {
        let text = captionLanguage == nil ? nil : VttParser.at(cues, t)?.text
        guard text != cueText else { return }
        cueText = text
        emit { $0.onCaptionCue(text) }
    }

    private func clearCaptions() {
        captionLanguage = nil
        cues = []
        if cueText != nil {
            cueText = nil
            emit { $0.onCaptionCue(nil) }
        }
    }

    // MARK: - The web Player API

    public func play() throws {
        try checkUsable()
        wantPlay = true
        if duration > 0, currentTime >= duration - 0.25 {
            avPlayer.seek(to: .zero)
        }
        avPlayer.rate = rate
    }

    public func pause() throws {
        try checkUsable()
        wantPlay = false
        avPlayer.pause()
    }

    /// Jumps to `seconds` (clamped to the video). Returns the time jumped to.
    @discardableResult
    public func seek(_ seconds: Double) throws -> Double {
        try checkUsable()
        let d = duration
        guard readySent, d > 0 else { throw WolvyError(.notReady, "The video's length is not known yet.") }
        guard !seconds.isNaN else { throw WolvyError(.invalidArgument, "seconds must be a number.") }
        let t = min(max(seconds, 0), d)
        avPlayer.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor in self?.emit { $0.onSeeked(t) } }
        }
        return t
    }

    public func mute() throws {
        try checkUsable()
        muted = true
        applyVolume()
        let v = userVolume
        emit { $0.onVolumeChange(v, muted: true) }
    }

    public func unmute() throws {
        try checkUsable()
        muted = false
        applyVolume()
        let v = userVolume
        emit { $0.onVolumeChange(v, muted: false) }
    }

    /// `volume` from 0 to 1.
    public func setVolume(_ volume: Float) throws {
        try checkUsable()
        guard !volume.isNaN, (0 ... 1).contains(volume) else {
            throw WolvyError(.invalidArgument, "volume must be between 0 and 1.")
        }
        userVolume = volume
        applyVolume()
        let m = muted
        emit { $0.onVolumeChange(volume, muted: m) }
    }

    /// One of ``wolvyPlaybackRates``: 0.5, 0.75, 1, 1.25, 1.5, 2.
    public func setPlaybackRate(_ rate: Float) throws {
        try checkUsable()
        guard wolvyPlaybackRates.contains(rate) else {
            throw WolvyError(.invalidArgument, "rate must be one of \(wolvyPlaybackRates).")
        }
        self.rate = rate
        if avPlayer.rate != 0 { avPlayer.rate = rate }
        emit { $0.onRateChange(rate) }
    }

    /// A height from ``getQualities()`` `available`, or nil for automatic. On iOS this is a
    /// ceiling: AVPlayer picks the best quality up to it, as Safari does.
    public func setQuality(_ height: Int?) throws {
        try checkUsable()
        guard !heights.isEmpty else { throw WolvyError(.notReady, "The qualities are not known yet.") }
        if let height, !heights.contains(height) {
            throw WolvyError(.invalidArgument, "\(height) is not one of \(heights).")
        }
        selectedHeight = height
        avPlayer.currentItem?.preferredMaximumResolution = Self.ceiling(height)
        emitQuality()
    }

    /// A language from ``getCaptions()`` `available`, or nil (or "off") to turn captions off.
    public func setCaptions(_ language: String?) throws {
        try checkUsable()
        guard let data, let video else { throw WolvyError(.notReady, "The video is not loaded yet.") }
        guard let language, language != "off" else {
            if captionLanguage != nil {
                clearCaptions()
                emit { $0.onCaptionsChange(nil) }
            }
            return
        }
        guard data.captions.contains(where: { $0.language == language }) else {
            throw WolvyError(.invalidArgument, "\"\(language)\" is not one of the video's captions.")
        }
        clearCaptions()
        captionLanguage = language
        let url = data.captionUrl(video, language: language)
        let gen = generation
        let agent = userAgent
        Task { [weak self] in
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
            var parsed: [Cue] = []
            if let (body, response) = try? await URLSession.shared.data(for: request),
               let status = (response as? HTTPURLResponse)?.statusCode, (200 ... 299).contains(status) {
                parsed = VttParser.parse(String(decoding: body, as: UTF8.self))
            }
            guard let self, !self.released, gen == self.generation, self.captionLanguage == language else { return }
            self.cues = parsed
        }
        emit { $0.onCaptionsChange(language) }
    }

    public var currentTime: Double {
        let t = avPlayer.currentTime().seconds
        return t.isFinite ? max(0, t) : 0
    }

    /// In seconds; 0 until known.
    public var duration: Double {
        if let d = avPlayer.currentItem?.duration.seconds, d.isFinite, d > 0 { return d }
        return data?.duration ?? 0
    }

    public var paused: Bool { !wantPlay }
    public var isMuted: Bool { muted }
    public var volume: Float { userVolume }
    public var playbackRate: Float { rate }

    /// Whether the screen is being recorded, mirrored or captured right now.
    public var isScreenCaptured: Bool {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.contains { $0.isCaptured }
    }

    public func getState() -> WolvyState {
        WolvyState(currentTime: currentTime, duration: duration, paused: paused, muted: muted, volume: userVolume, playbackRate: rate,
                   attested: data?.attested == true)
    }

    public func getQualities() -> WolvyQualities {
        let h = avPlayer.currentItem?.presentationSize.height ?? 0
        return WolvyQualities(available: heights, selected: selectedHeight, playing: h > 0 ? Int(h.rounded()) : nil)
    }

    public func getCaptions() -> WolvyCaptions { WolvyCaptions(available: data?.captions ?? [], active: captionLanguage) }

    public func getProgress() -> WolvyProgress {
        let d = duration
        return WolvyProgress(percent: progress.percent(duration: d), seconds: progress.seconds, duration: d)
    }

    /// Chapters, highlights, the viewer id and the account's player look, once loaded; nil before.
    public var videoInfo: WolvyVideoInfo? {
        guard let data else { return nil }
        return WolvyVideoInfo(chapters: data.chapters, moments: data.moments, viewerId: data.viewerId,
                              watermark: data.watermark, playerColor: data.playerColor, poster: data.poster)
    }

    public func addListener(_ listener: WolvyPlayerListener) {
        listeners.removeAll { $0.value == nil || $0.value === listener }
        listeners.append(WeakListener(listener))
    }

    public func removeListener(_ listener: WolvyPlayerListener) {
        listeners.removeAll { $0.value == nil || $0.value === listener }
    }

    /// Stops and frees the player. Every call after this throws `destroyed`.
    public func release() {
        guard !released else { return }
        released = true
        generation += 1
        ticker?.invalidate()
        ticker = nil
        tearDownItem()
        listeners.removeAll()
    }

    // MARK: - For WolvyPlayerView

    var lastError: WolvyError? { fatal }

    func emitFullscreen(_ fullscreen: Bool) { emit { $0.onFullscreenChange(fullscreen) } }

    // MARK: - Helpers

    private static let destroyed = WolvyError(.destroyed, "release() was called on this player.")

    private func checkUsable() throws {
        if released { throw Self.destroyed }
        if let fatal { throw fatal }
    }

    private func applyVolume() {
        avPlayer.volume = userVolume
        avPlayer.isMuted = muted
    }

    private func emit(_ call: (WolvyPlayerListener) -> Void) {
        for listener in listeners.compactMap(\.value) { call(listener) }
    }
}

private final class WeakListener {
    weak var value: WolvyPlayerListener?
    init(_ value: WolvyPlayerListener) { self.value = value }
}
