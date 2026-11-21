# Changelog

## 0.2.0

- **App protection.** When the account sets up protection for the app (dashboard: Settings → Protection → Allowed apps → Protection: the Apple team id), the app proves it is genuine before playback with Apple's App Attest. The first time on an install it attests a new key; later times it sends an assertion with that key, kept in the Keychain. Wolvy checks Apple's proof against the team ids listed (App Store builds only, unless the app allows test builds) and answers a 6-hour app key. The SDK signs `app_render_video` and every FairPlay licence request with it, and Wolvy treats the app like Wolvy Player.
- Without the setup, or when the proof fails (no App Attest on the device, a refusal), the app plays unproven, as in 0.1.0, unless the account only allows proven apps. New error reasons: `attestation_required`, `app_not_genuine`, `attestation_failed`.
- `WolvyState.attested` and `WolvyPlaybackData.attested`. `WolvyAppRenderVideoSource(appProtection: false)` turns it off.

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
