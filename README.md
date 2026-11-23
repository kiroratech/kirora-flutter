# Kirora Flutter SDK

Report what your signed-in users do in your Flutter app (events, screens, visits) and
reach them with push notifications, through one Dart API. The package wraps Kirora's
native Android and iOS SDKs, which own event storage, visits, consent, delivery retries
and notification handling.

Each signed-in user is a **contact** in Kirora, matched by the `sub` of the user token your
server signs (the contact's `externalId`). The events you track feed the rest of Kirora:

- **Segments** select contacts by what they did ("completed an order twice in 90 days").
- **Journeys** start when a contact's event arrives (`Signed Up`).
- **Conversion goals** count an event after a send (`Order Completed`), optionally summing
  a property such as `total` as revenue.
- **Campaigns** and journeys send push to the devices this SDK registers.

This version tracks signed-in users only: events tracked before sign-in wait on the
device and go as the next user to sign in. Nothing is sent anonymously.

**Preview: 0.1.0, not yet published to pub.dev.**

## Requirements and installation

| Component | Requirement |
| --- | --- |
| Flutter | 3.44 or later (Dart 3.12 or later). Tested with Flutter 3.44.4 and 3.50. |
| Android | API 24+, compileSdk 36, Java 17. AGP 8.9.3 / Kotlin 2.1 or later, or AGP 9. |
| iOS | iOS 13+, Swift 5.9. Swift Package Manager or CocoaPods. |
| Web, desktop | Not supported: every call is a safe no-op. |

Until it is published, depend on a local checkout, then run `flutter pub get` and rebuild
the app (hot reload can't add a native plugin):

```yaml
dependencies:
  kirora_flutter:
    path: /absolute/path/to/kirora-flutter
```

### Native SDKs

**Android** includes `io.kirora:android-sdk` and `android-sdk-push` 0.1.0 from Maven
Central (with Firebase Messaging 26; beside your own `firebase_messaging`, Gradle uses the
higher version). An app that doesn't use push can leave it out, with no Firebase and no
notification permission: add `kiroraPush=false` to `android/gradle.properties`. The push
calls then answer `unsupported`.

**iOS, Swift Package Manager:** resolves `kirora-ios` 0.1.0 from GitHub; nothing to add.

**iOS, CocoaPods:** the plugin bundles `kirora-ios` 0.1.0 and builds it itself; nothing to
add, and nothing comes from CocoaPods trunk. Don't also add the `Kirora` pod: the SDK would be
linked twice.

## Create one client

```dart
import 'package:flutter/widgets.dart';
import 'package:kirora_flutter/kirora_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final kirora = Kirora(KiroraOptions(
    clientKey: 'kirora_pk_REPLACE_ME',
    requireTrackingConsent: true,
    fetchUserToken: myServer.kiroraUserToken, // your server call, Future<String?>
  ));

  runApp(MyApp(kirora: kirora));
}
```

The client key (`kirora_pk_…`) is public and safe to ship. **Keep the secret that signs
user tokens, and your server API keys, on your server.** Creating the client never asks
for notification permission.

Create it once, outside widget `build` methods, in your main isolate only: never in a
background isolate such as `firebase_messaging`'s `onBackgroundMessage`. There is one
native client per app. A background engine's setup is refused while the app's UI has a
client (its `identify()` throws and it tracks nothing). Otherwise each setup
replaces the client:

- `Kirora.active` is the latest client. Creating another stops the previous one: it then
  sends nothing but push tokens (`onNewPushToken()`, which belong to the device), and its
  `identify()` and `setPushConsent()` throw `KiroraError`. Identify again after setting up.
- A `setTrackingConsent` choice made just before a replacement or `destroy()` still reaches
  the native SDK first.
- With several Flutter engines (add-to-app), the engine that set Kirora up last owns the
  push callbacks. An older engine's calls then do nothing (push tokens still go), and its
  `identify()` throws "Kirora was not set up".

`isAvailable` is false when no native plugin is found (web, desktop, an app's own unit
tests). Every call is then a no-op, and one diagnostic is logged.

## Identify the signed-in user

Your server signs an HS256 user token:

| Claim | Value |
| --- | --- |
| `sub` | Your stable user ID, the Kirora contact's `externalId`. |
| `iat` | Issued-at time in seconds. |
| `exp` | Expiry in seconds, at most 24 hours after issue. |

Kirora rejects expired tokens and tokens issued more than 60 seconds ahead.

Call identify after the user signs in, and at every launch while the app has a signed-in
user (the native SDK keeps the token in memory only):

```dart
try {
  await kirora.identify(); // Calls fetchUserToken.
  // Or: await kirora.identify(tokenFromYourServer);
} on KiroraError {
  // Show a failure state; never log the token.
}
```

`fetchUserToken` has 30 seconds to answer; a failure or an empty token is a
`UserTokenError`. The native SDK refreshes tokens itself. When a token fails outside any
call (a background refresh), `onAuthenticationFailed` hears it, once per failure:

```dart
onAuthenticationFailed: (reason) {
  // AuthenticationFailureReason.fetchFailed: fetchUserToken threw, gave nothing or timed out.
  // AuthenticationFailureReason.refused: a 401 with no fresh token, or the fresh one refused.
  auth.askUserToSignInAgain();
},
```

It is called again only after that user's token works or `identify()` is called, and never
for a failure a call throws, a cancelled call, or during sign-out.

Events tracked before anyone is identified go as the next user to sign in. On a direct
switch from A to B, A's waiting events stay A's and go once A can authenticate again.

### Sign out

```dart
await kirora.logout();
```

Call it only from your app's sign-out. It tries to send waiting events and detach the
device from push within five seconds, then signs out locally; neither is guaranteed to
reach Kirora. With a user signed in, events still waiting from before sign-in are dropped,
so the next user never adopts them. With nobody signed in (after a relaunch, before
`identify()`), only waiting events that continued a signed-in user's visit are dropped: a
visitor who never signed in keeps theirs, and with `trackSessions` off nothing is dropped.

A failed detach is retried with backoff for up to 24 hours from the sign-out, also after a
relaunch, using a device secret the SDK makes once per installation and sends with every
registration (it can only detach the device). It ends on success, a refusal for good, the
24 hours, or the client being destroyed. With nobody signed in, `logout()` still detaches
the device using that secret. Finish sign-out before the next sign-in.

`destroy()` stops the client without sending or deleting waiting events; it is not a
sign-out.

## Track activity

```dart
kirora.track('Order Completed', {
  'order_id': 'ORD-1042',
  'total': 125.00,
  'currency': 'NGN',
});
kirora.trackScreenView('Checkout');
```

Properties are copied as JSON when tracked: string keys; lists, strings, finite numbers,
booleans and null. `DateTime` becomes a UTC ISO string, and objects with `toJson()` go
through it. A cycle, a non-finite number or another object drops the event with a logged
reason; property values are never logged.

`trackScreenView(name)` records `Screen Viewed`; screens are never tracked automatically.
The native SDKs add these on their own:

| Event | When | Option |
| --- | --- | --- |
| `Session Started` | A visit begins: the first activity after 30 minutes without any. Every event carries the visit's `context.sessionId`. | `trackSessions`, on by default |
| `Application Installed`, `Application Opened`, `Application Updated`, `Application Backgrounded` | First launch, each launch or return to the foreground, the first launch of a new version, leaving the foreground | `trackAppLifecycle`, off by default |

They follow tracking consent, and `beforeSend` never sees them.

### Name events and properties

Kirora matches names exactly, so a journey waiting for `Order Completed` never starts for
`order completed`:

- **Event names:** Title Case, object then past-tense action: `Plan Upgraded`,
  `Order Completed`. One fixed name per action; ids and amounts go in properties
  (`Product Viewed` with `{'product_id': '8812'}`, not `Viewed product 8812`). Up to 128
  characters. Names beginning with `contact.` are Kirora's own and are refused.
- **Property names:** lowercase snake_case (`order_id`, `plan_name`), up to 64 characters,
  at most 16 KB of properties per event.
- **Values:** send the same type every time (a `total` that is sometimes `42.5` and
  sometimes `"42.50"` breaks "total greater than 40"), and amounts in major units.
  Segment rules and journey conditions read nested values by dotted path (`order.total`).

Kirora refuses an event that breaks these rules; the native SDK logs it and the others
still go. The full guide: [Events](https://kirora.io/docs/api/events).

### Delivery

The native SDKs store events on the device and send them in batches (up to 100), at 20
waiting events, every 30 seconds and when the app goes to the background, retrying with
backoff. They keep up to 1,000 events, dropping the oldest first. `flush()` sends now; it
completes when the attempt ends, which doesn't mean every event was accepted.

```dart
await kirora.flush();
```

### Redact properties with `beforeSend`

```dart
beforeSend: (event) {
  if (event.name == 'Sensitive Action') return null; // drop it
  event.properties.remove('email');
  return event;
},
```

It runs in Dart, synchronously, on `track` and `trackScreenView` events before they reach
the native SDK and its storage. It runs only for events tracking allows: never after a
refusal, or with `requireTrackingConsent` before a grant. The name can't be changed, and
an exception or an invalid result drops the event. It can't see the device and visit
context the native SDK adds, or the native SDK's own events. Keep it to redaction.

## Consent and device settings

| API | Controls |
| --- | --- |
| `setTrackingConsent(granted)` | Behavioural events, screen views, visits, lifecycle events and influenced app-open times. Remembered on the device. |
| `setPushConsent(granted)` | The signed-in user's marketing push choice, saved by Kirora. |
| `requestPushPermission()` | The system notification permission; not marketing consent. |
| `setPushEnabled(enabled)` | This device's own push on/off, kept across sign-out; never prompts. |

Tracking is allowed by default unless the user refused it; `requireTrackingConsent: true`
waits for a grant. Withdrawing it stops collection and drops the events still waiting;
data Kirora already accepted stays.

```dart
kirora.setTrackingConsent(userGrantedTracking);
```

Save marketing consent after identify, and show it as saved only once it succeeds:

```dart
try {
  await kirora.setPushConsent(userAcceptedMarketingPush);
} on KiroraError {
  // Keep the earlier choice and offer a retry.
}
```

Marketing push needs both marketing consent and the system permission; transactional push
needs only the permission.

## Configure push

Add `push: const KiroraPushOptions()` to the options. Set `pushAppId` when the workspace
has more than one push app for the platform.

### Android (FCM)

Set up Firebase in your app (`android/app/google-services.json` and the Google Services
Gradle plugin) and the matching FCM push app in Kirora. The native SDK draws Kirora's
data-only FCM messages itself.

```dart
push: KiroraPushOptions(
  smallIcon: 'ic_notification', // a drawable or mipmap name
  accentColor: '#FF5500',
  defaultChannelId: 'kirora_default',
  defaultChannelName: 'Notifications',
  onForegroundNotification: (data) => data['plan'] != 'muted',
),
```

The native push library brings its own messaging service. If your app has one already,
follow the [native Android guide](https://github.com/kiroratech/kirora-android#readme).
`kirora.onNewPushToken(token)` forwards a token from another messaging integration.

### iOS

Enable the Push Notifications capability and set up the matching push app in Kirora (a
Firebase push app also needs Firebase in your app). The plugin hooks push in at launch, so
no `AppDelegate` code is needed; with `KiroraAppDelegateProxyEnabled = NO`, forward the
callbacks as the [native iOS guide](https://github.com/kiroratech/kirora-ios#readme) shows.
Kirora pushes show in the foreground even beside `firebase_messaging` or
`flutter_local_notifications`; only `onForegroundNotification` can hold one back.

Delivery reports, images and buttons need a Notification Service Extension:

1. In Xcode, open `ios/Runner.xcworkspace` and add a target: File > New > Target >
   Notification Service Extension (for example `NotificationService`), with the same iOS
   deployment target as `Runner` or lower.
2. Add `KiroraNotificationService` to that target only:
   - CocoaPods, in `ios/Podfile`, then run `pod install`:
     ```ruby
     target 'NotificationService' do
       use_frameworks!
       # The kirora-ios version this plugin bundles
       pod 'KiroraNotificationService', :git => 'https://github.com/kiroratech/kirora-ios.git', :tag => '0.1.0'
     end
     ```
   - Swift Package Manager: add the `kirora-ios` package to the Xcode project and its
     `KiroraNotificationService` product to the extension target.
3. Replace the generated `NotificationService.swift` with:
   ```swift
   import KiroraNotificationService

   final class NotificationService: KiroraNotificationServiceExtension {}
   ```

If the app already has an extension (for Firebase images, say), keep it and give Kirora
its pushes first:

```swift
import FirebaseMessaging
import KiroraNotificationService
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        if KiroraNotificationService.didReceive(request, withContentHandler: contentHandler) { return }
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            return contentHandler(request.content)
        }
        Messaging.serviceExtension().populateNotificationContent(content, withContentHandler: contentHandler)
    }

    override func serviceExtensionTimeWillExpire() {
        // Hands back Kirora's pushes; iOS shows any other unfinished push as it arrived.
        KiroraNotificationService.serviceExtensionTimeWillExpire()
    }
}
```

Every path must call `contentHandler` exactly once, with the push's own content or a
mutable copy of it. Never hand back a new, empty `UNMutableNotificationContent`: iOS
shows nothing for a push without a title or body. If the app sets `apiUrl`, add a
`KiroraApiUrl` string with the same address to the extension's `Info.plist`.

### Permission, status and taps

```dart
final permission = await kirora.requestPushPermission();
// PushPermission.granted / denied / unanswered / unsupported

final status = await kirora.getPushStatus();
// PushStatus.enabled / disabled / denied / unanswered / unsupported

await kirora.setPushEnabled(false);

final taps = kirora.onNotificationClicked.listen((data) {
  // After the SDK has reported the tap (1.5 s at most); it opens the link itself.
});
final received = kirora.onNotificationReceived.listen((data) {
  // A push arriving in the foreground. Android only.
});
// When done: await taps.cancel(); await received.cancel();
```

- `denied`: notifications are blocked, and only the system settings can undo it (the
  permission was refused or, on Android, Kirora's channel was turned off).
- `disabled`: permission is granted but this device isn't registered
  (`setPushEnabled(false)`, signed out, or the registration failed).
- `setPushEnabled` applies to whoever signs in next. Turning it on registers only if the
  permission allows; a granted permission request turns it on too.
- Tap data values are strings (structured values as JSON text) and include the push's own
  keys, such as `title`, `body` and `actionUrl`. iOS also adds `kirora_action_identifier`,
  `kirora_button_index` and `kirora_link`. Treat sender values as untrusted. A tap that
  launched the app is delivered when you start listening.
- `onForegroundNotification` may return a bool or a future; `false` within about 1.5
  seconds hides the push, and no answer shows it.

### Route a push's link

```dart
handleDeepLink: (url) {
  if (url.scheme != 'https' || url.host != 'app.example.com') return false;
  router.go(url.path);
  return true;
},
```

Return true only when your app handled the link; otherwise the native SDK opens it. Don't
open it again from the tap stream. A link from the tap that launched the app waits up to
10 seconds for setup; after that, `handleDeepLink` has 1.5 seconds to answer, and a
late request is answered "not handled" without calling it, since the SDK has already opened
the link.

On iOS, a link you don't take opens in Safari or in the app that owns that universal link.
Route your own universal links here, not through `KiroraUniversalLinkHosts`: Flutter's app
delegate accepts every web link, so a listed host would never reach your router.

## State, errors and privacy

```dart
final state = await kirora.getState();
// isInitialized, isIdentified, deviceId, sessionId, pushToken,
// trackingConsent, pushConsent, queuedEventCount
```

`getState()` reads the device only: no network request or prompt. `queuedEventCount` is
events still waiting on the device.

`KiroraError` is the base exception. `UserTokenError` is a failed user token, and
`KiroraApiError` adds `status`, `code`, `retryAfterMs` and `retryable`. Only `identify()`
and `setPushConsent()` throw; `track()`, `logout()`, `flush()` and the push calls never do.

The package keeps nothing in Dart: the native SDKs store events, consent, the visit and
push registration in the app's own storage, and user tokens only in memory. Every event's
context carries the app, OS, screen, the device's manufacturer and type, locale, time zone
and visit; the device model and network details are never collected, since with the rest
they help fingerprint a device.

To report how push notifications perform, the SDK sends:

- the app's version, the OS version, and the device's language and time zone, when it
  registers the device;
- the time the app is opened or returns to the foreground;
- when a Kirora notification is shown or tapped.

Behavioural tracking consent also controls app-open times for influenced opens.
Push registration details, delivery receipts and notification taps are operational
push reports and are separate from behavioural tracking consent and marketing push
consent. Disabling behavioural tracking does not disable those operational reports.

It never sends hardware or advertising identifiers. The device id is a random value the
SDK creates and keeps in the app's own storage; it is deleted with the app.

## Testing your app

Use the mock in your app's tests:

```dart
import 'package:kirora_flutter/testing.dart';

final kirora = KiroraMock();
await kirora.identify('test-token');
kirora.track('Order Completed', {'order_id': 'ORD-1042'});
final event = kirora.tracked.single;
```

It records calls and events, lets you set state and errors, and can simulate notification
streams. Like the real client, it skips `beforeSend` for events tracking doesn't allow. It
has no native queue, authentication or push.

## Developing this package

```sh
flutter pub get && flutter analyze && flutter test
(cd example/android && ./gradlew :kirora_flutter:testDebugUnitTest)   # Android bridge
(cd example && flutter build apk --debug)
(cd example && flutter build ios --simulator)
```

To build against unreleased native code: on Android, set `KIRORA_ANDROID_LOCAL=1` after running
`./gradlew publishToMavenLocal` in `kirora-android`. On iOS, set `KIRORA_IOS_PATH` to a
`kirora-ios` checkout for Swift Package Manager (the folder must have that name; `flutter clean`
if Xcode keeps the old package), or run `tool/sync_kirora_ios.sh /path/to/kirora-ios` for
CocoaPods. A new kirora-ios release: `tool/sync_kirora_ios.sh <tag>` and the same exact version in
`ios/kirora_flutter/Package.swift`.

The Android example builds without Firebase; live push needs your own Firebase project and
a device. CI builds both platforms against the released native SDKs on every change. Real-device
push and several engines in one app are not covered by automated tests.

## License

MIT: see [LICENSE](LICENSE). `publish_to: none` keeps the package off pub.dev until it is
released.
