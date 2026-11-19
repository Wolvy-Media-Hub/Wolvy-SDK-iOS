# Wolvy iOS SDK

**In development. Nothing is published yet.**

The native iOS player for Wolvy video, in Swift on AVPlayer with FairPlay. The Flutter and React Native SDKs use it on iOS.

- Plays Wolvy's DRM-protected video (Widevine on Android, FairPlay on iOS) in your own app, with the per-viewer watermark and screen-capture protection.
- Takes the same three values as the embed URL: the video id, your account id, and a viewer token signed on **your server** (`POST /v1/videos/{id}/playback-tokens` on the Developer API, or the server SDKs). Nothing secret is ever built into the app.
- Your app must be on your account's **Allowed apps** list (Wolvy dashboard → Settings → Protection).

Will be published to: Swift Package Manager. Plan and progress: https://docs.wolvy.net (the SDK pages appear when it ships).

Other Wolvy SDKs: [web](https://github.com/Wolvy-Media-Hub/Wolvy-SDK) · [PHP](https://github.com/Wolvy-Media-Hub/Wolvy-SDK-PHP) · [Node.js](https://github.com/Wolvy-Media-Hub/Wolvy-SDK-Node) · [Android](https://github.com/Wolvy-Media-Hub/Wolvy-SDK-Android) · [iOS](https://github.com/Wolvy-Media-Hub/Wolvy-SDK-iOS) · [Flutter](https://github.com/Wolvy-Media-Hub/Wolvy-SDK-Flutter) · [React Native](https://github.com/Wolvy-Media-Hub/Wolvy-SDK-React-Native)

## Licence

Apache License 2.0 ([LICENSE](LICENSE)).
