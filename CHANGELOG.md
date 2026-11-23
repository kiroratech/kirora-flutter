## 0.1.0 (unreleased)

First release. A Flutter wrapper for the native Kirora SDKs: on Android it calls
`io.kirora:android-sdk` and `android-sdk-push`, on iOS `kirora-ios` (exactly `0.1.0`, iOS 13+), and
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
  `onAuthenticationFailed` (a token that fails outside a call: `AuthenticationFailureReason.fetchFailed`
  or `.refused`),
  `requireTrackingConsent`, `trackSessions`, `trackAppLifecycle`, `logLevel`, `apiUrl`, and Android's
  notification appearance.
- `Kirora-SDK: kirora-flutter/<version>` on both platforms.
- Errors reach the app as `KiroraApiError` (`status`, `code`, `retryAfterMs`), `UserTokenError`, or
  `KiroraError` itself (their base) for a setup or network problem. `identify()` and
  `setPushConsent()` throw, also on an instance that was destroyed or replaced; `track()` never does, and `logout()`, `flush()`, `getState()`,
  `requestPushPermission()`, `getPushStatus()` and `setPushEnabled()` never fail.
- Properties are copied as JSON at `track()`, as Dart's encoder writes them (dates as ISO 8601,
  objects through `toJson()`). A cycle, NaN or infinity, a non-string map key or another object
  drops that event with a logged reason.
- Calls reach the native SDK in the order the app makes them, and once setup has answered they
  are sent at once: a `logout()` just before `destroy()` or a new `Kirora(...)` is not lost. After
  a refused setup nothing is tracked.
- One native client per app. A background engine (an FCM background handler, WorkManager, a
  background task) can't take it from the app's UI: its setup is refused. The app's UI still
  replaces a background engine's client.
- Android: `kiroraPush=false` in the app's `gradle.properties` leaves push out (no Firebase,
  no notification permission); the push calls then answer `unsupported`.
- Native SDK versions are pinned exactly (Android `0.1.0`, iOS `0.1.0`): the plugin uses their
  wrapper-only API.
- One native client per app: a newer engine's setup replaces it, and an older engine's calls then
  answer "not set up". Create Kirora in the main isolate only.
- Where no native SDK is linked (web, desktop, an app's unit tests) every call does nothing and never
  throws, one error log says so, and `isAvailable` is `false`. `KiroraMock`
  (`package:kirora_flutter/testing.dart`) stands in for `Kirora` in an app's tests.
- Requires Flutter 3.44 or later (Dart 3.12). Android builds with AGP 8.9.3 / Kotlin 2.1.0 and later.
- iOS supports Swift Package Manager (`ios/kirora_flutter/Package.swift`, depending on Flutter's
  generated `FlutterFramework` package) as well as CocoaPods.
- Android gets `io.kirora:android-sdk` and `android-sdk-push` 0.1.0 from Maven Central. On iOS,
  Swift Package Manager gets `kirora-ios` 0.1.0 from GitHub; with CocoaPods the plugin bundles that
  version's sources (`ios/Kirora`, refreshed by `tool/sync_kirora_ios.sh`), as CocoaPods trunk is
  read-only from December 2026.
