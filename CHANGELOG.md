# Changelog

## 0.1.0

First release of the Wolvy iOS SDK (Swift Package Manager, product `WolvyPlayer`).

- `WolvyPlayer` and `WolvyPlayerView` on AVPlayer: Wolvy's HLS with FairPlay through `wolvy.net/api/app_render_video`, with the app's bundle id checked against the account's Allowed apps (platform iOS).
- FairPlay with `AVContentKeySession`: the certificate and the licence from Wolvy; the licence token never leaves the SDK.
- The CDN's path form with the playback session id, so analytics see every viewing.
- The web Player API's methods, events and error codes; `load` and `retry` for apps; `onCaptionCue`, and `onScreenCaptureChange` on iOS.
- Short viewer tokens: `WolvyVideo` takes an async token provider, asked before a token expires and once if Wolvy refuses it. Tokens are removed from error details.
- Recovery: fresh playback data and a resume at the same position after a licence or CDN token ran out or a longer outage (3 times, counted again after a minute of good playback).
- Viewer watermark (static or moving), WebVTT captions, chapter marks, the account's player colour, a quality (ceiling), captions and speed menu, and a bare view without controls.
- iOS 15 and later. Apache License 2.0.
