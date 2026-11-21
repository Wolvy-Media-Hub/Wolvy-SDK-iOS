import Foundation

/// What the `ready` event carries and ``WolvyPlayer/getState()`` returns. Times in seconds.
public struct WolvyState: Equatable, Sendable {
    public let currentTime: Double
    public let duration: Double
    public let paused: Bool
    public let muted: Bool
    public let volume: Float
    public let playbackRate: Float
}

/// Qualities on offer, as picture heights. `selected` is the picked height, or nil for automatic
/// (the web API's "auto"); `playing` is the height on screen, or nil before the first frame.
public struct WolvyQualities: Equatable, Sendable {
    public let available: [Int]
    public let selected: Int?
    public let playing: Int?
}

public struct WolvyCaptionTrack: Equatable, Sendable {
    public let language: String
    public let label: String

    public init(language: String, label: String) {
        self.language = language
        self.label = label
    }
}

/// `active` is the language shown, or nil when captions are off.
public struct WolvyCaptions: Equatable, Sendable {
    public let available: [WolvyCaptionTrack]
    public let active: String?
}

/// How much of the video was played, each second counted once: the same numbers as the web
/// player's `progress` event. `percent` has one decimal, 0 to 100.
public struct WolvyProgress: Equatable, Sendable {
    public let percent: Double
    public let seconds: Int
    public let duration: Double
}

public struct WolvyChapter: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let title: String
}

public struct WolvyMoment: Equatable, Sendable {
    public let timestamp: Double
    public let label: String
}

/// The account's watermark setting. `opacity` is a percent, 0 to 100.
public struct WolvyWatermark: Equatable, Sendable {
    public let enabled: Bool
    /// "moving" or "static".
    public let mode: String
    /// "top-left", "top-right", "bottom-left" or "bottom-right" (static mode).
    public let position: String
    public let opacity: Int
}

/// What ``WolvyPlayer/videoInfo`` returns once a video is loaded.
public struct WolvyVideoInfo: Equatable, Sendable {
    public let chapters: [WolvyChapter]
    public let moments: [WolvyMoment]
    /// The verified viewer id from the token, shown by the watermark.
    public let viewerId: String?
    public let watermark: WolvyWatermark
    /// The account's player colour as "#RRGGBB", or nil.
    public let playerColor: String?
    public let poster: URL?
}

/// The speeds the player offers: the only values ``WolvyPlayer/setPlaybackRate(_:)`` accepts (as on the web).
public let wolvyPlaybackRates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
