# iOS spike (SDK plan phase 4, step 2)

A throwaway app that answers the phase's unknowns on a real iPhone before the SDK is written:

1. **FairPlay from an app.** The certificate (`wolvy.net/api/process_videos/fairplay.cer`) and the licence proxy (`process_videos/fairplay`) with no browser origin. Needs Wolvy-Video-APIs#8 deployed.
2. **The CDN from AVPlayer.** The HLS path form `/p/{cdn_token}/{exp}/{session}/{account}/{video}/hls/playlist.m3u8` on `{server}.wolvy-cdn.net`.
3. **Old videos.** A title packaged before the separate FairPlay key (the licence proxy falls back to the audio key).

Paste an `embed_url` (from `POST /v1/videos/{id}/playback-tokens`) and press Play. The app asks `wolvy.net/api/app_render_video` as an iOS app (`X-Wolvy-Platform: ios`, its bundle id `net.wolvy.spike.ios`, `X-Wolvy-SDK: wolvy-ios-spike/0.0.1`), plays the HLS ladder in `AVPlayerViewController`, answers key requests through `AVContentKeySession`, and logs every step (certificate, key request, licence status, picture size, stalls, errors, screen capture). Tokens are cut out of the log. "Copy log" puts it on the clipboard.

FairPlay does not play in the simulator; the simulator only shows the steps before the licence.

## Build

```bash
brew install xcodegen
```

```bash
cd spike && xcodegen && open WolvySpike.xcodeproj
```

In Xcode: target WolvySpike → Signing & Capabilities → Team (the company team `N858H3328Q`, or a personal Apple ID for a phone test), then run on the connected iPhone. Add `net.wolvy.spike.ios` (platform iOS) to the test account's Allowed apps.
