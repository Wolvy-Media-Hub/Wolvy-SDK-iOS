import Foundation

/// Player events, with the web Player API's names and data. Implement only what you need
/// (every method has an empty default). Called on the main thread.
///
/// The player keeps listeners weakly, like a delegate: keep a reference to yours.
@MainActor
public protocol WolvyPlayerListener: AnyObject {
    /// The video is loaded and accepts every command. Sent once per ``WolvyPlayer/load(_:autoplay:)``.
    func onReady(_ state: WolvyState)
    func onPlay(_ currentTime: Double)
    func onPause(_ currentTime: Double)
    func onEnded()
    /// After a jump, whoever asked for it.
    func onSeeked(_ currentTime: Double)
    /// About 4 times a second while playing.
    func onTimeUpdate(_ currentTime: Double, duration: Double)
    /// As the share played changes, at most once a second, and once more at the end.
    func onProgress(_ progress: WolvyProgress)
    func onVolumeChange(_ volume: Float, muted: Bool)
    func onRateChange(_ playbackRate: Float)
    func onQualityChange(_ qualities: WolvyQualities)
    /// A language code, or nil when captions are off.
    func onCaptionsChange(_ active: String?)
    /// The fullscreen button of ``WolvyPlayerView`` was pressed; the app resizes the view.
    func onFullscreenChange(_ fullscreen: Bool)
    /// The video could not be loaded or played. After this, control methods throw the same error.
    func onError(_ error: WolvyError)
    /// The caption text to show now, or nil. For apps that draw their own captions.
    func onCaptionCue(_ text: String?)
    /// iOS only: the screen started or stopped being recorded, mirrored or captured. iOS itself
    /// blanks the protected video in captures; react if you want more (pause, cover).
    func onScreenCaptureChange(_ captured: Bool)
}

public extension WolvyPlayerListener {
    func onReady(_ state: WolvyState) {}
    func onPlay(_ currentTime: Double) {}
    func onPause(_ currentTime: Double) {}
    func onEnded() {}
    func onSeeked(_ currentTime: Double) {}
    func onTimeUpdate(_ currentTime: Double, duration: Double) {}
    func onProgress(_ progress: WolvyProgress) {}
    func onVolumeChange(_ volume: Float, muted: Bool) {}
    func onRateChange(_ playbackRate: Float) {}
    func onQualityChange(_ qualities: WolvyQualities) {}
    func onCaptionsChange(_ active: String?) {}
    func onFullscreenChange(_ fullscreen: Bool) {}
    func onError(_ error: WolvyError) {}
    func onCaptionCue(_ text: String?) {}
    func onScreenCaptureChange(_ captured: Bool) {}
}
