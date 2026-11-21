import AVFoundation
import UIKit

/// Shows a ``WolvyPlayer``: the video, the viewer watermark and captions inside the picture, and
/// (unless `showControls` is false) controls in the account's colour, with quality, captions and
/// speed in a menu and chapter marks on the seek bar.
///
/// iOS keeps the FairPlay picture out of screenshots, recordings and mirroring by itself. The
/// fullscreen button reports ``WolvyPlayerListener/onFullscreenChange(_:)``; the app resizes the view.
@MainActor
public final class WolvyPlayerView: UIView {
    static let defaultAccent = UIColor(red: 0x7C / 255, green: 0x3A / 255, blue: 0xED / 255, alpha: 1)

    public override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    /// The player to show. Setting another one detaches the previous.
    public var player: WolvyPlayer? {
        didSet {
            guard oldValue !== player else { return }
            if let oldValue { detach(oldValue) }
            if let player { attach(player) }
        }
    }

    /// False for a bare player: no controls, no menu (draw your own with the player's methods).
    public var showControls = true {
        didSet { controls.isHidden = !showControls; setNeedsLayout() }
    }

    /// Whether the fullscreen button shows the "exit" state. The app sets it when it changes the layout itself.
    public var isFullscreen = false {
        didSet { updateFullscreenIcon() }
    }

    private lazy var events = Events(view: self)
    private let videoBox = UIView()
    private let watermark = UILabel()
    private let caption = PaddedLabel()
    private let message = UILabel()
    private let controls = UIView()
    private let scrim = UIView()
    private let centerButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    private let bar = UIView()
    private let timeLabel = UILabel()
    private let durationLabel = UILabel()
    private let slider = UISlider()
    private let marks = UIView()
    private let settingsButton = UIButton(type: .system)
    private let fullscreenButton = UIButton(type: .system)
    private var accent = WolvyPlayerView.defaultAccent
    private var watermarkTimer: Timer?
    private var hideTimer: Timer?
    private var scrubbing = false
    private var controlsShown = true
    private var timeControlObservation: NSKeyValueObservation?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        backgroundColor = .black
        clipsToBounds = true
        playerLayer.videoGravity = .resizeAspect

        videoBox.isUserInteractionEnabled = false
        videoBox.clipsToBounds = true
        addSubview(videoBox)
        watermark.textColor = .white
        watermark.font = .boldSystemFont(ofSize: 13)
        watermark.layer.shadowColor = UIColor.black.cgColor
        watermark.layer.shadowRadius = 2
        watermark.layer.shadowOpacity = 1
        watermark.layer.shadowOffset = .zero
        watermark.isHidden = true
        videoBox.addSubview(watermark)
        caption.textColor = .white
        caption.font = .systemFont(ofSize: 16)
        caption.backgroundColor = UIColor.black.withAlphaComponent(0.63)
        caption.numberOfLines = 0
        caption.textAlignment = .center
        caption.isHidden = true
        videoBox.addSubview(caption)

        addSubview(controls)
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        scrim.isUserInteractionEnabled = false
        controls.addSubview(scrim)
        centerButton.tintColor = .white
        centerButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 44), forImageIn: .normal)
        centerButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)
        centerButton.accessibilityLabel = "Play"
        controls.addSubview(centerButton)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        controls.addSubview(spinner)

        controls.addSubview(bar)
        for label in [timeLabel, durationLabel] {
            label.textColor = .white
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.text = "0:00"
            bar.addSubview(label)
        }
        durationLabel.textAlignment = .right
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.setThumbImage(Self.thumb(), for: .normal)
        slider.minimumTrackTintColor = accent
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.35)
        slider.addTarget(self, action: #selector(scrubBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubMoved), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        slider.accessibilityLabel = "Position"
        bar.addSubview(slider)
        marks.isUserInteractionEnabled = false
        bar.addSubview(marks)
        settingsButton.setImage(UIImage(systemName: "gearshape.fill"), for: .normal)
        settingsButton.tintColor = .white
        settingsButton.showsMenuAsPrimaryAction = true
        settingsButton.accessibilityLabel = "Quality, captions and speed"
        settingsButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.menuItems() ?? [])
        }])
        bar.addSubview(settingsButton)
        fullscreenButton.tintColor = .white
        fullscreenButton.addTarget(self, action: #selector(toggleFullscreen), for: .touchUpInside)
        bar.addSubview(fullscreenButton)
        updateFullscreenIcon()

        message.textColor = .white
        message.font = .systemFont(ofSize: 15)
        message.numberOfLines = 0
        message.textAlignment = .center
        message.isHidden = true
        message.isUserInteractionEnabled = true
        message.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(retryTapped)))
        addSubview(message)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleControls)))
        updatePlayIcon(playing: false)
        controls.isHidden = true
    }

    // MARK: - Attaching

    private func attach(_ player: WolvyPlayer) {
        playerLayer.player = player.avPlayer
        player.addListener(events)
        timeControlObservation = player.avPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] avPlayer, _ in
            let status = avPlayer.timeControlStatus
            Task { @MainActor in self?.onTimeControl(status) }
        }
        controls.isHidden = !showControls
        if let error = player.lastError { show(error) }
        if player.videoInfo != nil { applyLook() }
    }

    private func detach(_ player: WolvyPlayer) {
        player.removeListener(events)
        timeControlObservation = nil
        playerLayer.player = nil
        watermarkTimer?.invalidate()
        watermark.isHidden = true
        caption.isHidden = true
        message.isHidden = true
    }

    public override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            watermarkTimer?.invalidate()
            hideTimer?.invalidate()
        } else if player?.videoInfo != nil {
            applyLook()
        }
    }

    // MARK: - Events from the player

    @MainActor
    private final class Events: WolvyPlayerListener {
        weak var view: WolvyPlayerView?
        init(view: WolvyPlayerView) { self.view = view }

        func onReady(_ state: WolvyState) {
            guard let view else { return }
            view.message.isHidden = true
            view.controls.isHidden = !view.showControls
            view.applyLook()
            view.updateTimes(state.currentTime, state.duration)
        }
        func onTimeUpdate(_ currentTime: Double, duration: Double) { view?.updateTimes(currentTime, duration) }
        func onSeeked(_ currentTime: Double) { view?.updateTimes(currentTime, view?.player?.duration ?? 0) }
        func onCaptionCue(_ text: String?) {
            guard let view else { return }
            view.caption.text = text
            view.caption.isHidden = (text ?? "").isEmpty
            view.setNeedsLayout()
        }
        func onError(_ error: WolvyError) { view?.show(error) }
        func onEnded() { view?.showControlsNow(autoHide: false) }
        func onQualityChange(_ qualities: WolvyQualities) { view?.setNeedsLayout() }
    }

    private func onTimeControl(_ status: AVPlayer.TimeControlStatus) {
        let playing = status != .paused
        updatePlayIcon(playing: playing)
        if status == .waitingToPlayAtSpecifiedRate, player?.lastError == nil { spinner.startAnimating() } else { spinner.stopAnimating() }
        centerButton.isHidden = spinner.isAnimating
        if status == .playing { scheduleHide() } else { showControlsNow(autoHide: false) }
    }

    private func show(_ error: WolvyError) {
        spinner.stopAnimating()
        message.text = error.code == .deviceNotSupported ? error.message : "\(error.message)\nTap to try again."
        message.isHidden = false
        controls.isHidden = true
        setNeedsLayout()
    }

    @objc private func retryTapped() {
        guard player?.lastError?.code != .deviceNotSupported else { return }
        message.isHidden = true
        controls.isHidden = !showControls
        try? player?.retry()
    }

    // MARK: - Look: colour, chapters, watermark

    private func applyLook() {
        guard let info = player?.videoInfo else { return }
        accent = info.playerColor.flatMap(Self.color(hex:)) ?? Self.defaultAccent
        slider.minimumTrackTintColor = accent
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.35)
        watermarkTimer?.invalidate()
        if info.watermark.enabled, let viewer = info.viewerId, !viewer.isEmpty {
            watermark.text = viewer
            watermark.alpha = CGFloat(info.watermark.opacity) / 100
            watermark.sizeToFit()
            watermark.isHidden = false
            placeWatermark()
            if info.watermark.mode == "moving" {
                let timer = Timer(timeInterval: WatermarkPlacer.moveEvery, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.placeWatermark() }
                }
                RunLoop.main.add(timer, forMode: .common)
                watermarkTimer = timer
            }
        } else {
            watermark.isHidden = true
        }
        layoutMarks()
        setNeedsLayout()
    }

    private func placeWatermark() {
        guard let wm = player?.videoInfo?.watermark, !watermark.isHidden else { return }
        let box = videoBox.bounds.size
        let size = watermark.bounds.size
        let m = WatermarkPlacer.margin
        switch WatermarkPlacer.place(mode: wm.mode, position: wm.position) {
        case let .corner(top, left):
            watermark.frame.origin = CGPoint(x: left ? m : box.width - size.width - m, y: top ? m : box.height - size.height - m)
        case let .moving(left, top):
            watermark.frame.origin = CGPoint(x: min(left * box.width, max(0, box.width - size.width)),
                                             y: min(top * box.height, max(0, box.height - size.height)))
        }
    }

    private func layoutMarks() {
        marks.subviews.forEach { $0.removeFromSuperview() }
        guard let player, let info = player.videoInfo else { return }
        let d = player.duration
        guard d > 0 else { return }
        let track = slider.trackRect(forBounds: slider.bounds)
        for chapter in info.chapters where chapter.start > 0 && chapter.start < d {
            let mark = UIView(frame: CGRect(x: track.minX + track.width * chapter.start / d - 1, y: 0, width: 2, height: 4))
            mark.backgroundColor = UIColor.white.withAlphaComponent(0.8)
            marks.addSubview(mark)
        }
    }

    // MARK: - Layout: the overlays stay inside the picture

    public override func layoutSubviews() {
        super.layoutSubviews()
        let rect = playerLayer.videoRect
        videoBox.frame = (rect.width > 0 && rect.height > 0) ? rect : bounds
        controls.frame = bounds
        scrim.frame = controls.bounds
        centerButton.frame = CGRect(x: bounds.midX - 36, y: bounds.midY - 36, width: 72, height: 72)
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let safe = safeAreaInsets
        bar.frame = CGRect(x: safe.left + 8, y: bounds.height - safe.bottom - 44, width: bounds.width - safe.left - safe.right - 16, height: 44)
        let w = bar.bounds.width
        timeLabel.frame = CGRect(x: 0, y: 0, width: 52, height: 44)
        fullscreenButton.frame = CGRect(x: w - 36, y: 4, width: 36, height: 36)
        settingsButton.frame = CGRect(x: w - 72, y: 4, width: 36, height: 36)
        durationLabel.frame = CGRect(x: w - 72 - 52, y: 0, width: 50, height: 44)
        slider.frame = CGRect(x: 56, y: 7, width: max(0, w - 72 - 52 - 60), height: 30)
        let track = slider.trackRect(forBounds: slider.bounds)
        marks.frame = CGRect(x: slider.frame.minX, y: slider.frame.minY + track.midY - 2, width: slider.bounds.width, height: 4)
        layoutMarks()
        message.frame = bounds.insetBy(dx: 24, dy: 16)

        let maxCaption = videoBox.bounds.width - 32
        let size = caption.sizeThatFits(CGSize(width: maxCaption, height: .greatestFiniteMagnitude))
        let lift: CGFloat = (showControls && controlsShown) ? 52 : 16
        caption.frame = CGRect(x: (videoBox.bounds.width - min(size.width, maxCaption)) / 2,
                               y: videoBox.bounds.height - size.height - lift,
                               width: min(size.width, maxCaption), height: size.height)
        if !watermark.isHidden { placeWatermark() }
    }

    // MARK: - Controls

    @objc private func togglePlay() {
        guard let player else { return }
        if player.paused { try? player.play() } else { try? player.pause() }
        scheduleHide()
    }

    @objc private func toggleFullscreen() {
        isFullscreen.toggle()
        player?.emitFullscreen(isFullscreen)
    }

    @objc private func toggleControls() {
        guard showControls else { return }
        if controlsShown { hideControls() } else { showControlsNow(autoHide: true) }
    }

    @objc private func scrubBegan() {
        scrubbing = true
        hideTimer?.invalidate()
    }

    @objc private func scrubMoved() {
        guard let d = player?.duration, d > 0 else { return }
        timeLabel.text = Self.format(Double(slider.value) * d)
    }

    @objc private func scrubEnded() {
        scrubbing = false
        if let player, player.duration > 0 { _ = try? player.seek(Double(slider.value) * player.duration) }
        scheduleHide()
    }

    private func updateTimes(_ t: Double, _ d: Double) {
        durationLabel.text = Self.format(d)
        guard !scrubbing else { return }
        timeLabel.text = Self.format(t)
        slider.value = d > 0 ? Float(t / d) : 0
        if marks.subviews.isEmpty, d > 0 { layoutMarks() }
    }

    private func updatePlayIcon(playing: Bool) {
        centerButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill"), for: .normal)
        centerButton.accessibilityLabel = playing ? "Pause" : "Play"
    }

    private func updateFullscreenIcon() {
        fullscreenButton.setImage(UIImage(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"), for: .normal)
        fullscreenButton.accessibilityLabel = isFullscreen ? "Exit full screen" : "Full screen"
    }

    private func showControlsNow(autoHide: Bool) {
        guard showControls else { return }
        controlsShown = true
        UIView.animate(withDuration: 0.2) { self.controls.alpha = 1 }
        setNeedsLayout()
        if autoHide { scheduleHide() }
    }

    private func hideControls() {
        controlsShown = false
        UIView.animate(withDuration: 0.25) { self.controls.alpha = 0 }
        setNeedsLayout()
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        guard let player, !player.paused else { return }
        let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.scrubbing, self.player?.paused == false else { return }
                self.hideControls()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    // MARK: - The menu: quality, captions, speed

    private func menuItems() -> [UIMenuElement] {
        guard let player else { return [] }
        var items: [UIMenuElement] = []
        let q = player.getQualities()
        if !q.available.isEmpty {
            var options = [UIAction(title: "Auto", state: q.selected == nil ? .on : .off) { [weak player] _ in try? player?.setQuality(nil) }]
            options += q.available.map { h in
                UIAction(title: "\(h)p", state: q.selected == h ? .on : .off) { [weak player] _ in try? player?.setQuality(h) }
            }
            items.append(UIMenu(title: "Quality", image: UIImage(systemName: "slider.horizontal.3"), children: options))
        }
        let c = player.getCaptions()
        if !c.available.isEmpty {
            var options = [UIAction(title: "Off", state: c.active == nil ? .on : .off) { [weak player] _ in try? player?.setCaptions(nil) }]
            options += c.available.map { track in
                UIAction(title: track.label, state: c.active == track.language ? .on : .off) { [weak player] _ in try? player?.setCaptions(track.language) }
            }
            items.append(UIMenu(title: "Captions", image: UIImage(systemName: "captions.bubble"), children: options))
        }
        let speeds = wolvyPlaybackRates.map { r in
            UIAction(title: r == 1 ? "Normal" : "\(Self.rateText(r))×", state: player.playbackRate == r ? .on : .off) { [weak player] _ in
                try? player?.setPlaybackRate(r)
            }
        }
        items.append(UIMenu(title: "Speed", image: UIImage(systemName: "speedometer"), children: speeds))
        return items
    }

    // MARK: - Helpers

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func rateText(_ r: Float) -> String {
        r == r.rounded() ? String(Int(r)) : String(format: "%g", r)
    }

    static func color(hex: String) -> UIColor? {
        guard hex.count == 7, hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    private static func thumb() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 14, height: 14)).image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 14, height: 14))
        }
    }
}

/// A label with room around its text, for captions.
final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = super.sizeThatFits(CGSize(width: size.width - insets.left - insets.right, height: size.height))
        return CGSize(width: inner.width + insets.left + insets.right, height: inner.height + insets.top + insets.bottom)
    }
}
