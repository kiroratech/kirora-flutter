# Kirora Flutter SDK

Track what your signed-in users do in your Flutter app (events, screen views and sessions)
and reach them with push notifications, through one Dart API. The plugin uses Kirora's
native Android and iOS SDKs for event storage, retries, consent and notification handling.

Kirora represents each signed-in user as a **contact**. Your server signs a user token whose
`sub` claim is your stable user ID; Kirora uses it as the contact's `externalId`. The events
you track feed Kirora's segments, journeys and conversion goals, and campaigns send push to
the devices this SDK registers.

This version tracks signed-in users only. Nothing is sent anonymously: events tracked before
sign-in wait on the device and are sent as the next user you identify.

[API reference](https://pub.dev/documentation/kirora_flutter/latest/) ·
[Example app](https://github.com/kiroratech/kirora-flutter/tree/main/example) ·
[Changelog](https://pub.dev/packages/kirora_flutter/changelog) ·
[Issues](https://github.com/kiroratech/kirora-flutter/issues) ·
[Event naming guide](https://kirora.io/docs/api/events)

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Identify and sign out](#identify-and-sign-out)
- [Track events](#track-events)
- [Consent and device settings](#consent-and-device-settings)
- [Push notifications](#push-notifications)
- [Check your integration](#check-your-integration)
- [State, errors and privacy](#state-errors-and-privacy)
- [Testing your app](#testing-your-app)
- [Advanced](#advanced)
- [Support and contributing](#support-and-contributing)

## Requirements

| Component | Requirement |
| --- | --- |
| Flutter | 3.44 or later (Dart 3.12 or later). Tested with Flutter 3.44.4 and the latest stable. |
| Android | API 24+, compileSdk 36, Java 17. AGP 8.9.3 / Kotlin 2.1 or later, or AGP 9. |
| iOS | iOS 13+, Swift 5.9. Swift Package Manager or CocoaPods. |
| Web, desktop | Not supported: every call is a safe no-op. |

The native SDKs come with the plugin; there is nothing to add:

- **Android:** `io.kirora:android-sdk` and `android-sdk-push` 0.1.0 from Maven Central, with
  Firebase Messaging 26 (beside your own `firebase_messaging`, Gradle uses the higher
  version). An app that doesn't use push can leave it out, with no Firebase and no
  notification permission: add `kiroraPush=false` to `android/gradle.properties`. The push
  calls then answer `unsupported`.
- **iOS, Swift Package Manager:** `kirora-ios` 0.1.0 from GitHub.
- **iOS, CocoaPods:** the plugin bundles `kirora-ios` 0.1.0 and builds it itself; nothing
  comes from CocoaPods trunk. Don't also add the `Kirora` pod: the SDK would be linked twice.

## Quick start

You need your workspace's public client key (`kirora_pk_…`) and a server endpoint that signs
user tokens (see [Identify and sign out](#identify-and-sign-out)).

**1. Install**, then rebuild the app (hot reload can't add a native plugin):

```sh
flutter pub add kirora_flutter
```

**2. Create one client** at startup, in the main isolate, outside widget `build` methods:

```dart
import 'package:flutter/widgets.dart';
import 'package:kirora_flutter/kirora_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final kirora = Kirora(KiroraOptions(
    clientKey: 'kirora_pk_REPLACE_ME',
    requireTrackingConsent: true, // collect nothing until the user agrees
    fetchUserToken: myServer.kiroraUserToken, // your app's call, returns Future<String?>
  ));

  runApp(MyApp(kirora: kirora)); // your app
}
```

The client key is public and safe to ship. **Keep the secret that signs user tokens, and
your server API keys, on your server.** Creating the client never asks for notification
permission.

**3. Apply the user's tracking choice.** With `requireTrackingConsent: true`, nothing is
collected until you grant it, and events tracked before then are dropped, not kept for later:

```dart
kirora.setTrackingConsent(userAgreedToTracking);
```

**4. Identify the user** after they sign in, and at every launch while they are signed in:

```dart
try {
  await kirora.identify(); // calls fetchUserToken
} on KiroraError {
  // Show a failure state; never log the token.
}
```

**5. Track an event:**

```dart
kirora.track('Order Completed', {'order_id': 'ORD-1042', 'total': 125.00, 'currency': 'NGN'});
```

**6. Check it arrived:** see [Check your integration](#check-your-integration).

Push is optional: see [Push notifications](#push-notifications).

## Identify and sign out

Your server signs an HS256 user token:

| Claim | Value |
| --- | --- |
| `sub` | Your stable user ID, the Kirora contact's `externalId`. |
| `iat` | Issued-at time in seconds. |
| `exp` | Expiry in seconds, at most 24 hours after issue. |

Kirora rejects expired tokens and tokens issued more than 60 seconds ahead.

Call `identify()` after sign-in and at every launch while the app has a signed-in user: the
native SDK keeps the token in memory only. Pass a token directly with
`identify(tokenFromYourServer)`, or let it call `fetchUserToken`.

`fetchUserToken` must return a non-empty token within 30 seconds; otherwise `identify()`
throws `UserTokenError`. The native SDK refreshes tokens itself. When a background refresh
fails, `onAuthenticationFailed` is called, once per failure:

```dart
onAuthenticationFailed: (reason) {
  // AuthenticationFailureReason.fetchFailed: fetchUserToken threw, returned nothing or timed out.
  // AuthenticationFailureReason.refused: Kirora answered 401 and no fresh token worked.
  auth.askUserToSignInAgain();
},
```

It isn't called again until that user's token works or `identify()` is called. Failures that
`identify()` or `setPushConsent()` throw are not reported here, nor are cancelled calls or
failures during sign-out.

On a direct switch from user A to user B, A's waiting events stay A's and are sent once A
can authenticate again.

### Sign out

```dart
await kirora.logout();
```

Call and await it from your app's sign-out, before identifying another user. Within five
seconds it tries to send waiting events and detach the device from push, then signs out
locally; neither is guaranteed to reach Kirora. Events still waiting from before sign-in are
dropped, so the next user never adopts them. See [Sign-out details](#sign-out-details).

`destroy()` stops the client without sending or deleting waiting events; it is not a
sign-out.

## Track events

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
| `Session Started` | A session begins: the first activity after 30 minutes without any. Every event carries the session's `context.sessionId`. | `trackSessions`, on by default |
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

The native SDKs store events on the device and send them when 20 are waiting, every 30
seconds, and when the app goes to the background, up to 100 per batch, retrying with
backoff. They keep up to 1,000 events and drop the oldest when full. `flush()` sends now;
it completes when the attempt ends, which doesn't mean every event was accepted.

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
the native SDK and its storage, and only for events tracking allows. The name can't be
changed, and an exception or an invalid result drops the event. It can't see the device
and session context the native SDK adds, or the native SDK's own events. Keep it to
redaction.

## Consent and device settings

| API | Controls |
| --- | --- |
| `setTrackingConsent(granted)` | Behavioural events, screen views, sessions, lifecycle events and influenced app-open times. Remembered on the device. |
| `setPushConsent(granted)` | The signed-in user's marketing push consent, saved by Kirora. |
| `requestPushPermission()` | The system notification permission; not marketing consent. |
| `setPushEnabled(enabled)` | This device's own push setting, kept across sign-out; never prompts. |

Tracking is allowed by default unless the user refused it; `requireTrackingConsent: true`
waits for a grant. Events tracked while tracking isn't allowed are dropped. Withdrawing it
stops collection and drops the events still waiting; data Kirora already accepted stays.

Save marketing push consent after identify, and show it as saved only once it succeeds:

```dart
try {
  await kirora.setPushConsent(userAcceptedMarketingPush);
} on KiroraError {
  // Keep the earlier choice and offer a retry.
}
```

Marketing push needs both marketing push consent and the system permission; transactional
push needs only the permission.

## Push notifications

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
   - Swift Package Manager: add the `kirora-ios` package
     (`https://github.com/kiroratech/kirora-ios`, exactly 0.1.0) to the Xcode project and
     its `KiroraNotificationService` product to the extension target.
3. Replace the generated `NotificationService.swift` with:
   ```swift
   import KiroraNotificationService

   final class NotificationService: KiroraNotificationServiceExtension {}
   ```

If the app already has an extension, see
[An existing Notification Service Extension](#an-existing-notification-service-extension).
If the app sets `apiUrl`, add a `KiroraApiUrl` string with the same address to the
extension's `Info.plist`.

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
  // A Kirora push arriving, in any app state it is drawn in. Android only.
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

Return `true` only when your app handled the link; otherwise the native SDK opens it. Don't
open it again from the tap stream. For a tap that launched the app, the SDK waits up to 10
seconds for setup, then gives `handleDeepLink` 1.5 seconds to answer. A request that comes
later is answered "not handled" without calling it, because the SDK has already opened the
link.

On iOS, a link you don't take opens in Safari or in the app that owns that universal link.
Route your own universal links here, not through `KiroraUniversalLinkHosts`: Flutter's app
delegate accepts every web link, so a listed host would never reach your router.

## Check your integration

While developing, set `logLevel: LogLevel.debug` in the options to see what the native SDKs
do, then check the state after tracking:

```dart
final state = await kirora.getState();
// state.isIdentified: identify() succeeded
// state.trackingConsent: false means events are being dropped
// state.queuedEventCount: events still waiting on the device
await kirora.flush(); // send them now
```

If `queuedEventCount` stays above zero after a flush, check the debug log for the send
attempt: no network, a refused token, or an event Kirora refused. Go back to
`LogLevel.error`, the default, for release builds.

## State, errors and privacy

### State

```dart
final state = await kirora.getState();
// isInitialized, isIdentified, deviceId, sessionId, pushToken,
// trackingConsent, pushConsent, queuedEventCount
```

`getState()` reads the device only: no network request or prompt.

`isAvailable` is false when no native plugin is found (web, desktop, an app's own unit
tests). Every call is then a no-op, and one diagnostic is logged. On Android and iOS it is
known once setup has answered, and reports `true` until then.

### Errors

`KiroraError` is the base exception. `UserTokenError` is a failed user token, and
`KiroraApiError` adds `status`, `code`, `retryAfterMs` and `retryable`. Only `identify()`
and `setPushConsent()` throw; `track()`, `logout()`, `flush()` and the push calls never do.

### Privacy

The Dart layer stores nothing on the device: the native SDKs store events, consent, the
session and push registration in the app's own storage, and user tokens only in memory.
Every event's context carries the app, OS, screen, the device's manufacturer and type,
locale, time zone and session; the device model and network details are never collected,
since with the rest they help fingerprint a device.

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

## Advanced

### One client per app

There is one native client per app, and each new setup replaces it, with one exception: a
setup from a background isolate (such as `firebase_messaging`'s `onBackgroundMessage`) is
refused while the app's UI has a client; its `identify()` throws and it tracks nothing. On a
replacement:

- `Kirora.active` is the latest client. Creating another stops the previous one: it then
  sends nothing but push tokens (`onNewPushToken()`, which belong to the device), and its
  `identify()` and `setPushConsent()` throw `KiroraError`. Identify again after setting up.
- A `setTrackingConsent` choice made just before a replacement or `destroy()` still reaches
  the native SDK first.
- With several Flutter engines (add-to-app), the engine that set Kirora up last owns the
  push callbacks. An older engine's calls then do nothing (push tokens still go), and its
  `identify()` throws "Kirora was not set up".

### Sign-out details

With a user signed in, `logout()` drops events still waiting from before sign-in. With
nobody signed in (after a relaunch, before `identify()`), it drops only waiting events that
continued a signed-in user's session: a visitor who never signed in keeps theirs, and with
`trackSessions` off nothing is dropped.

A failed push detach is retried with backoff for up to 24 hours from the sign-out, also
after a relaunch, using a device secret the SDK makes once per installation and sends with
every registration (it can only detach the device). Retrying ends on success, a permanent
refusal, the 24 hours, or the client being destroyed. With nobody signed in, `logout()`
still detaches the device using that secret. Finish sign-out before the next sign-in.

### An existing Notification Service Extension

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
shows nothing for a push without a title or body.

## Support and contributing

- Questions and bugs: [GitHub issues](https://github.com/kiroratech/kirora-flutter/issues).
- Working on the package itself: [CONTRIBUTING.md](https://github.com/kiroratech/kirora-flutter/blob/main/CONTRIBUTING.md).

## License

MIT: see [LICENSE](LICENSE).
