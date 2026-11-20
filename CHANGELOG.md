## 0.1.0 (unreleased)

First release. A Flutter wrapper for the native Kirora SDKs: on Android it calls
`com.kirora:android-sdk` and `android-sdk-push`, on iOS the `Kirora` pod (`~> 0.1`, iOS 13+), and
they do the work (queue, visits, consent, push, retries, sign-out).

- `identify()`, `logout()`, `track()`, `trackScreenView()`, `setTrackingConsent()`, `flush()`,
  `getState()` and `destroy()`.
- Push: `requestPushPermission()`, `getPushStatus()`, `setPushEnabled()` (the device's own on/off,
  kept across sign-out) and `setPushConsent()` (marketing consent). Taps on `onNotificationClicked`,
  arriving pushes on `onNotificationReceived` (Android). Push is hooked in at launch with no
  `AppDelegate` or activity code, so a tap that launched the app is not lost.
- Options: `fetchUserToken` (answered from Dart for the native SDK, 30 s for the round trip),
  `beforeSend` (redacts or drops an event the app tracks, in Dart, before it is forwarded and
  stored; never called for an event tracking doesn't allow), `handleDeepLink` and `onForegroundNotification` (asked over the channel, 1.5 s at most),
  `onAuthenticationFailed` (a token that fails outside a call: `fetchFailed` or `refused`),
  `requireTrackingConsent`, `trackSessions`, `trackAppLifecycle`, `logLevel`, `apiUrl`, and Android's
  notification appearance.
- `Kirora-SDK: kirora-flutter/<version>` on both platforms.
- Errors reach the app as `KiroraApiError` (`status`, `code`, `retryAfterMs`), `UserTokenError`, or
  `KiroraError` itself (their base) for a setup or network problem. `identify()` and
  `setPushConsent()` throw; `track()` never does, and `logout()`, `flush()`, `getState()`,
  `requestPushPermission()`, `getPushStatus()` and `setPushEnabled()` never fail.
- Properties are copied as JSON at `track()`, as Dart's encoder writes them (dates as ISO 8601,
  objects through `toJson()`). A cycle, NaN or infinity, a non-string map key or another object
  drops that event with a logged reason.
- Where no native SDK is linked (web, desktop, an app's unit tests) every call does nothing and never
  throws, one error log says so, and `isAvailable` is `false`. `KiroraMock`
  (`package:kirora_flutter/testing.dart`) stands in for `Kirora` in an app's tests.
- Requires Flutter 3.44 or later (Dart 3.12). Android builds with AGP 8.9.3 / Kotlin 2.1.0 and later.
- iOS supports Swift Package Manager (`ios/kirora_flutter/Package.swift`, depending on Flutter's
  generated `FlutterFramework` package) as well as CocoaPods.
- Until the native SDKs are published: Android builds against `mavenLocal()`, and the iOS app
  points at a local kirora-ios (a local Swift package, or the `Kirora` pod by path).
