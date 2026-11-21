# Wolvy iOS SDK

**0.1.0, in testing (not released yet).** Swift Package Manager. The Flutter and React Native SDKs will use it on iOS.

Plays Wolvy's DRM-protected video (HLS and FairPlay, through AVPlayer) in your own iPhone or iPad app, with the viewer watermark and the account's look, and with the same methods and events as Wolvy's web Player API and the Android SDK.

- iOS 15 and later.
- Your app's bundle id must be on your account's **Allowed apps**, platform iOS (Wolvy dashboard → Settings → Protection). An empty list lets no app play.
- The viewer token is made on **your server**: `POST /v1/videos/{id}/playback-tokens` on the Developer API, or `signViewerToken` in the [PHP](https://github.com/Wolvy-Media-Hub/Wolvy-SDK-PHP) and [Node.js](https://github.com/Wolvy-Media-Hub/Wolvy-SDK-Node) SDKs. Nothing secret goes into the app.

## Install

Once released: Xcode → File → Add Package Dependencies → `https://github.com/Wolvy-Media-Hub/Wolvy-SDK-iOS`, product **WolvyPlayer**. Or in `Package.swift`:

```swift
.package(url: "https://github.com/Wolvy-Media-Hub/Wolvy-SDK-iOS", from: "0.1.0")
```

## Use

```swift
import WolvyPlayer

final class LessonViewController: UIViewController, WolvyPlayerListener {
    private let player = WolvyPlayer()           // asks wolvy.net/api/app_render_video with your bundle id
    private let playerView = WolvyPlayerView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(playerView)              // lay it out at 16:9
        playerView.player = player
        player.addListener(self)                 // kept weakly, like a delegate
        try? player.load(WolvyVideo(videoId: videoId, accountId: accountId, viewerToken: viewerTokenFromYourServer))
    }

    func onProgress(_ progress: WolvyProgress) {
        if progress.percent >= 90 { markLessonComplete() }   // seconds actually watched, each once
    }

    func onError(_ error: WolvyError) { print(error.code.rawValue, error.reason ?? "") }

    deinit { /* player.release() when the screen goes away */ }
}
```

In SwiftUI, wrap `WolvyPlayerView` in a `UIViewRepresentable` and keep the `WolvyPlayer` in your model (the sample app shows how). `WolvyVideo.fromEmbedUrl(embedUrl)` reads the three values from the `embed_url` that `POST /v1/videos/{id}/playback-tokens` returns.

### Short viewer tokens (recommended)

A viewer token is good for any video of your account until it expires, so keep it short (for example 10 minutes) and give the player a way to get a fresh one from your server:

```swift
let video = try WolvyVideo(videoId: id, accountId: account, viewerToken: tokenFromYourServer) { video in
    try await myApi.freshViewerToken(for: video.videoId)    // signed on your server
}
try player.load(video)
```

The player asks for a fresh token before it talks to Wolvy when the one it has expires within a minute (it reads the expiry from the token; only Wolvy verifies it), and once more if Wolvy refuses the token. Without a provider, the token must outlive the viewing: a reload after an error needs it again. Tokens never appear in `WolvyError` messages or details.

## What it does for you

| | |
|---|---|
| FairPlay | HLS with one FairPlay key for the whole ladder: the certificate and the licence come from Wolvy (the licence token stays inside the SDK) |
| Screen capture | iOS keeps FairPlay video out of screenshots, screen recordings and mirroring by itself: the picture is black there. `onScreenCaptureChange` tells you when capture starts if you want to react too |
| Quality | AVPlayer adapts to the network; `setQuality` sets a ceiling (as in Safari) |
| Recovery | A network drop is ridden out by AVPlayer. A licence or CDN token that ran out, or a longer outage: fresh playback data for the same session, then playback resumes at the same position, up to 3 times (counted again after a minute of good playback) |
| Analytics | Every media address carries the playback session id, so watch time and usage appear in your dashboard as for the web player |
| Watermark | The verified viewer id from the token, static or moving, inside the picture, as set in the dashboard |
| Captions | Fetched and drawn by the SDK (WebVTT); `onCaptionCue` gives the text for apps that draw their own |
| Chapters | Marks on the seek bar; `player.videoInfo` has chapters and highlights |
| Look | The account's player colour; quality, captions and speed in a menu. `playerView.showControls = false` for a bare view with your own controls |
| Fullscreen | The button reports `onFullscreenChange(true/false)`; your app changes the layout (the same player can move to another `WolvyPlayerView`, and playback goes on) |

## API

The web Player API's names, so the same code ideas work in every Wolvy SDK. Call on the main thread (the player is `@MainActor`). Methods throw `WolvyError`.

| Methods | Notes |
|---|---|
| `load(_:autoplay:)` | Apps only: starts a video (`video` may carry a token provider) |
| `play()`, `pause()` | |
| `seek(_:)` | Returns the time jumped to; `not_ready` before the length is known |
| `mute()`, `unmute()`, `setVolume(_:)` | 0 to 1 |
| `setPlaybackRate(_:)` | 0.5, 0.75, 1, 1.25, 1.5 or 2 |
| `setQuality(_:)` | A height from `getQualities().available` (a ceiling); nil = automatic |
| `setCaptions(_:)` | A language from `getCaptions().available`; nil = off |
| `currentTime`, `duration`, `paused`, `isMuted`, `volume`, `playbackRate` | Properties |
| `getState()`, `getQualities()`, `getCaptions()`, `getProgress()` | |
| `retry()` | Apps only: after an error |
| `release()` | The web `destroy()` |

| Events (`WolvyPlayerListener`) | |
|---|---|
| `onReady`, `onPlay`, `onPause`, `onEnded`, `onSeeked` | |
| `onTimeUpdate(_:duration:)` | About 4 times a second while playing |
| `onProgress(_:)` | Share of the video's seconds played, each counted once, with one decimal: the same numbers as the web and Android |
| `onVolumeChange`, `onRateChange`, `onQualityChange`, `onCaptionsChange`, `onFullscreenChange` | |
| `onError(_:)` | `error.code` is one of the web codes: `network_error`, `playback_error`, `device_not_supported`, `not_ready`, `invalid_argument`, `destroyed`, `failed`; `error.reason` is the server's code (`app_not_allowed`, `viewer_token_required`, `update_required`…) or the device's (`licence_refused`, `network`, `playback_failed`) |
| `onCaptionCue(_:)` | The caption text to show now, for apps that draw their own captions |
| `onScreenCaptureChange(_:)` | iOS only: the screen started or stopped being recorded or mirrored |

## Another source of playback data

`WolvyPlayer(source:)` takes any `WolvyPlaybackSource`. The default, `WolvyAppRenderVideoSource`, posts to `https://wolvy.net/api/app_render_video` with `X-Wolvy-Platform: ios`, `X-Wolvy-App-Id` (the bundle id) and `X-Wolvy-SDK: wolvy-ios/<version>`. A source answers with `WolvyPlaybackData.fromJSON(_:)` from an answer of the same shape.

## Build

Xcode 16 or later:

```bash
xcodebuild -scheme WolvyPlayer -destination 'platform=iOS Simulator,name=iPhone 17' test
```

`Sample/` is a small SwiftUI app that plays the `embed_url` you paste and logs every event (also to the device log); add `net.wolvy.player.sample` (platform iOS) to a test account's Allowed apps. Its Xcode project is generated from `Sample/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). FairPlay plays on real iPhones and iPads only, not in the simulator.

Other Wolvy SDKs: [web](https://github.com/Wolvy-Media-Hub/Wolvy-SDK) · [PHP](https://github.com/Wolvy-Media-Hub/Wolvy-SDK-PHP) · [Node.js](https://github.com/Wolvy-Media-Hub/Wolvy-SDK-Node) · [Android](https://github.com/Wolvy-Media-Hub/Wolvy-SDK-Android) · [Flutter](https://github.com/Wolvy-Media-Hub/Wolvy-SDK-Flutter) · [React Native](https://github.com/Wolvy-Media-Hub/Wolvy-SDK-React-Native)

## Licence

Apache License 2.0 ([LICENSE](LICENSE)).
