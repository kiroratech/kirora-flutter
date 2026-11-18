# Kirora Flutter SDK

Connect signed-in users' app activity and push notifications to Kirora through one Dart
API. The package wraps Kirora's native Android and iOS SDKs, which own event storage,
sessions, consent, delivery retries and notification handling.

**Preview: 0.1.0, not published to pub.dev.** This guide describes the implemented API and
its limits; it does not certify production readiness.

## Requirements and installation

| Component | Requirement |
| --- | --- |
| Dart | `^3.13.1` according to `pubspec.yaml`. Use a Flutter distribution containing a compatible Dart SDK. |
| Flutter | Declared `>=3.22.0`, additionally constrained by Dart. Reviewed with Flutter 3.50.0 / Dart 3.14.0; a full compatibility matrix is not established. |
| Android | API 24+, compileSdk 36 and Java 17. The plugin uses AGP 9.1.1 and its Kotlin build configuration; align your host toolchain with the resolved dependencies. |
| iOS | iOS 13+ and Swift 5.9 in the podspec. Your Flutter/Xcode combination may require a higher deployment target. |
| Platforms | Native plugin implementations exist for Android and iOS. Web and desktop have no Kirora native backend. |

The package currently sets `publish_to: none`. Use a local checkout while developing:

```yaml
dependencies:
  kirora_flutter:
    path: /absolute/path/to/kirora-flutter
```

Then run `flutter pub get` in your host app and rebuild its native application.
Hot reload cannot install a newly added native plugin.

### Resolve the native SDKs

Android always includes both `com.kirora:android-sdk` and `com.kirora:android-sdk-push`,
including Firebase Messaging and its notification permission, even when Dart push
options are absent. The default native version is `0.1.0`; the Gradle property
`kiroraAndroidSdkVersion` overrides it.

For local development, publish the native Android libraries from their checkout:

```sh
./gradlew :kirora-sdk:publishToMavenLocal :kirora-sdk-push:publishToMavenLocal
```

Ensure your host repositories permit `mavenLocal()`; the plugin and example already
include it. Verify the resolved artifact after updating native sources. A reused local
version label does not prove the latest code reached your app.

iOS uses CocoaPods and depends on `Kirora ~> 0.1`. Until that pod is available from your
configured repository, point your host's `Runner` target to the local native checkout:

```ruby
pod 'Kirora', :path => '/absolute/path/to/kirora-ios'
```

Run `pod install` from the host's `ios` directory. The plugin podspec is discovered
automatically. This package does not currently include a Swift Package Manager manifest.

## Create one retained client

Initialize Flutter bindings before creating Kirora. Retain the client outside widget
build methods. In this example, `myServer.kiroraUserToken` is your existing authenticated
server call returning `Future<String?>`.

```dart
import 'package:flutter/widgets.dart';
import 'package:kirora_flutter/kirora_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final kirora = Kirora(KiroraOptions(
    clientKey: 'kirora_pk_REPLACE_ME',
    requireTrackingConsent: true,
    fetchUserToken: myServer.kiroraUserToken,
  ));

  runApp(MyApp(kirora: kirora));
}
```

The client key is public. **Keep the token secret and server API keys on your server.**
Construction does not prompt for notification permission.

`Kirora.active` refers to the latest client in the Dart isolate. Creating another stops
the previous Dart backend and replaces native configuration. Identify after startup or
reconfiguration; do not rely on identity carrying over consistently across platforms.

A `setTrackingConsent` choice made just before a replacement or `destroy()` still reaches
the native SDK first. With several Flutter engines (add-to-app), the engine that configured
Kirora last owns the process-wide push callbacks; an older engine's teardown or `destroy()`
ends only its own client and leaves them alone. Keep one retained client where you can.

`isAvailable` becomes false when no native plugin is found. On Android/iOS it is
optimistically true until setup answers. It indicates plugin availability, not successful
authentication or delivery. Web, desktop and unlinked environments use safe no-ops and
report push as unsupported, with one diagnostic unless logging is disabled. A no-op
completion is not proof that the server saved anything.

## Identify the signed-in user

Your authenticated server signs an HS256 user token with:

| Claim | Value |
| --- | --- |
| `sub` | Your stable user ID, matching the Kirora contact's `externalId`. |
| `iat` | Issued-at time in seconds. |
| `exp` | Expiry in seconds, no more than 24 hours after issue. |

The server rejects expired tokens and tokens issued more than 60 seconds ahead.
The SDK does not create or sign user tokens on the device.

Call identify after your application signs the user in, and again at authenticated
startup because the native SDK keeps its JWT in memory:

```dart
try {
  await kirora.identify(); // Calls fetchUserToken.
  // Or: await kirora.identify(tokenFromYourAuthenticatedServer);
} on KiroraError {
  // Show a safe integration failure state; do not log the token.
}
```

The native token request has a 30-second round-trip limit. A missing/empty token or
provider failure is reported as `UserTokenError`. Native code owns refresh and stale
answer handling.

Events tracked before anyone is identified remain unbound and can be adopted by the
next user. They are not sent anonymously. On a direct switch from A to B, A's owned
records must remain A's and wait until A can authenticate again; switching does not
promise to flush A's records before B's.

On application sign-out:

```dart
await kirora.logout();
```

Native logout attempts outgoing event delivery and device detachment within one
five-second deadline, then completes local sign-out. It does not guarantee every event
was accepted or push access was revoked remotely. Failed detachment may retry with
outgoing credentials held in memory for up to 24 hours, ending on success, terminal
refusal, client destruction or process death. Offline sign-out cannot promise immediate
server-side revocation. Finish sign-out before starting the next authenticated flow.

`destroy()` disposes client work without flushing or deleting pending events. Use logout
for application sign-out; destroy is for client disposal.

## Track activity

```dart
kirora.track('Order Completed', {
  'order_id': 'ORD-1042',
  'amount': 12500,
  'currency': 'NGN',
});
kirora.trackScreenView('Checkout');
```

Use clear, consistent event names and property names. The server applies business limits.
Properties are copied when tracked: maps need string keys; JSON values include lists,
strings, finite numbers, booleans and null. `DateTime` becomes a UTC ISO string and
objects with `toJson()` are copied through that method. Cycles, excessive nesting,
unsupported objects and non-finite numbers drop the event with a failure-category
diagnostic. The SDK does not intentionally log property values.

`trackSessions` defaults to true; `trackAppLifecycle` defaults to false. Both follow
behavioural tracking consent. Automatic event collection and context come from native
code, not a second Dart tracker.

The delivery contract targets 1,000 events / 1,000,000 serialized bytes in the queue,
oldest-first eviction, sends at 20 queued events or a 30-second interval and background
transitions, and batches of up to 100 events / 200,000 bytes. Native code owns persistence,
in-memory fallback, acknowledgements, fixed event keys and server backoff. Validate those
guarantees with the exact native SDK versions you ship.

```dart
await kirora.flush();
```

Flush attempts delivery without intentionally bypassing consent or Retry-After. Completion
is not a receipt that all queued events were accepted. Native background delivery is
subject to OS execution limits.

### Redact app properties before native storage

```dart
beforeSend: (event) {
  if (event.name == 'Sensitive Action') return null;
  event.properties.remove('email');
  event.properties.remove('phone');
  return event;
},
```

Set this callback in `KiroraOptions`. It runs synchronously in Dart on explicit
`track`/`trackScreenView` events before forwarding, and only for events tracking allows:
never after a refusal, or with `requireTrackingConsent` before a grant. Properties are copied
at the call; until native setup has said whether tracking is allowed (once, at startup),
the hook runs when it has, and events still go in call order. Return the event or null to drop it.
The name stays unchanged. Exceptions, invalid JSON results and recursive tracking are
handled as dropped events.

Context is empty in this wrapper hook. Native code adds automatic context later; returned
context is not forwarded. The hook cannot redact native device/session context or
operational reports. Native automatic session/lifecycle events bypass the wrapper hook,
by design.

Keep the callback to redaction: no collection or network side effects inside it.

## Consent and device settings

These controls have different purposes:

| API | Controls |
| --- | --- |
| `setTrackingConsent(granted)` | Behavioural events, screens, sessions, lifecycle events and influenced app-open times. |
| `setPushConsent(granted)` | Signed-in user's marketing push choice, saved by the server. |
| `requestPushPermission()` | System notification authorization; does not grant marketing consent. |
| `setPushEnabled(enabled)` | This installation's push setting, retained across user sign-out; does not prompt. |

Tracking is allowed by default unless a refusal is remembered. Set
`requireTrackingConsent: true` to require an explicit grant. Apply the user's choice:

```dart
kirora.setTrackingConsent(userGrantedBehaviouralTracking);
```

Native consent storage remembers refusals separately from the main settings. Withdrawal
stops behavioural collection/sends and clears pending behavioural work according to the
native contract. Data already accepted by the server cannot be recalled.

Save marketing consent after identify and handle failure before showing it as saved:

```dart
if (kirora.isAvailable) {
  try {
    await kirora.setPushConsent(userAcceptedMarketingPush);
    // Show the saved choice.
  } on KiroraError {
    // Keep the earlier saved choice and offer a retry.
  }
}
```

Marketing push requires both marketing consent and OS permission. Transactional push
does not require marketing consent. Device registration, operational delivered/opened/
clicked reports and detachment may continue while behavioural tracking is refused.
Influenced app-open times are behavioural and follow tracking consent.

## Configure push

Add `push: const KiroraPushOptions()` to the retained client's options. Use `pushAppId`
when the workspace has multiple push apps for the platform.

### Android / FCM

Configure Firebase in your host app, including `android/app/google-services.json` and
the Google Services Gradle plugin, and configure the matching FCM push app in Kirora.
The native SDK renders Kirora's data-only FCM messages, marked `kirora = "true"`.
Delivery still depends on Android permissions, settings and FCM/background behavior.

```dart
push: KiroraPushOptions(
  smallIcon: 'ic_notification',
  accentColor: '#FF5500',
  channelId: 'kirora_default',
  channelName: 'Notifications',
  onForegroundNotification: (data) => data['plan'] != 'muted',
),
```

The small icon is an app drawable/mipmap resource name. Android channel settings control
sound/importance. The native push library includes a messaging service. If your app
already owns one, follow the [native Android forwarding guide](../kirora-android/README.md)
and inspect the merged manifest. `kirora.onNewPushToken(token)` forwards a token received
through another messaging integration; it does not forward message payloads. Avoid
multiple rendering/reporting paths for the same push.

### iOS

Enable Push Notifications and configure signing/entitlements and the matching Kirora
push app. Enable Remote notifications background mode when your push integration needs
it. The plugin installs native push integration at registration, before Dart setup.
The native SDK obtains the token kind configured for the push app; a Firebase target
also needs Firebase configured in your iOS host.

By default, no extra Dart APNs forwarding is needed. If you disable delegate proxying
with `KiroraAppDelegateProxyEnabled = NO`, forward callbacks as described in the
[native iOS guide](../kirora-ios/README.md). Validate coexistence with other notification
delegates/messaging libraries in your app.

Delivered reporting and images require a Notification Service Extension target with
`KiroraNotificationService`. The main-app plugin pod does not create an extension for
you. Follow the native guide for its pod and service subclass setup.

### Permission, device preference and streams

```dart
final permission = await kirora.requestPushPermission();
// PushPermission.granted / denied / unanswered / unsupported

final status = await kirora.getPushStatus();
// PushStatus.enabled / disabled / denied / unanswered / unsupported

await kirora.setPushEnabled(false);
// Later: await kirora.setPushEnabled(true);

final tapSubscription = kirora.onNotificationClicked.listen((data) {
  // Observe the tap; native code owns reporting and link opening.
});
final receiveSubscription = kirora.onNotificationReceived.listen((data) {
  // Android only; iOS does not emit this stream.
});

// When the owner is disposed:
await tapSubscription.cancel();
await receiveSubscription.cancel();
```

Device push off persists across users. Turning it back on registers when permission
already allows notifications; it does not prompt. A granted permission request also
turns device push on.

Tap payload values are strings; structured values may be JSON text. iOS adds
`kirora_action_identifier`, optional `kirora_button_index` and `kirora_link`; do not assume
those additions exist on Android. Treat all sender values as untrusted. A buffered
launch tap is delivered when listening starts.

`onForegroundNotification` works through both native bridges and can return a bool or
future. A timely false suppresses foreground display; no answer within about 1.5 seconds
means native default display. Keep the callback fast.

### Route a link once

Configure `handleDeepLink` with your application's router. This example's `router.go`
is your existing navigation operation:

```dart
handleDeepLink: (url) {
  if (url.scheme != 'https' || url.host != 'app.example.com') return false;
  router.go(url.path);
  return true;
},
```

Return true only when your app handled the URL. Otherwise native code uses its fallback.
Validate the scheme, host and route. Do not open the link again from the tap stream.
A cold-start link waits for initial wrapper configuration for up to ten seconds;
routing answers then have a 1.5-second budget. A request that reaches Dart after that
budget is answered "not handled" without calling `handleDeepLink`: native code has
already opened the link, so the app never routes it a second time.

For iOS universal links, claim routes explicitly when needed, especially in scene-based
hosts. An unhandled web URL may open through the system rather than stay in the app.

## State, errors and privacy

```dart
final state = await kirora.getState();
// isInitialized, isIdentified, deviceId, sessionId, pushToken,
// trackingConsent, pushConsent, queuedEventCount
```

The native snapshot makes no network request or prompt. Channel failures yield empty
state in normal handling. `pushToken` describes the current registration, not merely
the OS token cache. Queue count describes local pending events, not server acceptance.

`KiroraError` is the exception base. `UserTokenError` represents token acquisition
failure. `KiroraApiError` adds `status`, `code`, `retryAfterMs` and `retryable`. Identify
and marketing-consent operations surface failures; quiet methods such as logout/flush
and device push toggles do not provide remote-success receipts.

This package adds no Dart storage/HTTP queue. Native SDKs store event properties,
ownership/context, consent, sessions and installation/registration state in app storage.
JWTs remain in native memory. The installation ID is random, not a hardware or advertising
ID. Native context can include approved app, OS, screen and device manufacturer/model/
type fields alongside locale/timezone/session/library data; network details are outside
the current shared context contract. Review both your properties and the exact native
artifact's collection/storage policy before release.

## Mock and source development

Use the supplied mock for host-app tests without native code:

```dart
import 'package:kirora_flutter/testing.dart';

final kirora = KiroraMock();
await kirora.identify('test-token');
kirora.track('Order Completed', {'order_id': 'ORD-1042'});
final event = kirora.tracked.single;
```

The mock records calls/events, has configurable state/errors and can simulate notification
streams. It does not reproduce a native queue, authentication, FCM/APNs or engine lifetime.
Like production, it skips `beforeSend` for events tracking doesn't allow. Use it for
application wiring assertions, not proof of native conformance.

From this checkout:

```sh
flutter pub get
flutter analyze
cd example
flutter pub get
flutter build apk --debug
```

The Android example builds without Firebase configuration; live push needs your own
Firebase project and device. There is currently no checked-in iOS example host, so create
or use a real iOS host and configure its Podfile/capabilities before validating that side.
Do not assume the Android example directory is already an iOS Runner project.

Run the suite with `flutter test`; it covers the channel contract against a mock
messenger, not a native engine.
Full iOS plugin linking, real-device push and multi-engine execution remain unverified.

## License and publication

MIT licensed: see [LICENSE](LICENSE). `publish_to: none` keeps it off pub.dev until the
native SDKs are published.
