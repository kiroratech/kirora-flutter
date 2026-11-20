import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';

import 'errors.dart';
import 'native_backend.dart';
import 'options.dart';
import 'state.dart';

/// The Kirora client SDK.
///
/// ```dart
/// final kirora = Kirora(KiroraOptions(clientKey: 'kirora_pk_…', fetchUserToken: myServer.kiroraToken));
/// await kirora.identify();          // at every start while signed in, and after sign-in
/// kirora.track('Order Completed', {'order_id': 'ORD-1042'});
/// await kirora.logout();            // on sign-out
/// ```
///
/// Every call goes to the native Kirora SDK (kirora-android, kirora-ios), which does the work.
/// Where there is none (web, desktop, a unit test), calls do nothing and never throw. Create it
/// once, at startup. No call blocks the app or throws because Kirora is unreachable.
class Kirora {
  /// [channel] is for tests.
  Kirora(this.options, {MethodChannel? channel}) {
    active?._stop();
    final native = channel != null ||
        (!kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS));
    _backend = NativeBackend(options, channel ?? const MethodChannel(kiroraChannelName), available: native);
    active = this;
  }

  /// False where the native Kirora SDK isn't linked (web, desktop, an app's own unit tests): every
  /// call then does nothing and never throws, and one error log says so. Known once setup has
  /// answered; before that it is true on Android and iOS.
  bool get isAvailable => _backend.isAvailable;

  /// The most recently created instance.
  static Kirora? active;

  final KiroraOptions options;
  late final NativeBackend _backend;

  /// Signs the user in with [token], or with one from `fetchUserToken` when omitted; registers the
  /// device for push if allowed and sends waiting events. Call it at every start while the user is
  /// signed in. Throws [UserTokenError] when `fetchUserToken` fails, [KiroraApiError] (401) when
  /// Kirora refuses even a fresh token, and [KiroraError] for a setup problem: no token and no
  /// `fetchUserToken`, or an `apiUrl` that isn't an address. A failed push registration is only logged.
  Future<void> identify([String? token]) => _backend.identify(token);

  /// Sends what waits, detaches the device from the user, and forgets the rest. Safe to call twice.
  Future<void> logout() => _backend.logout();

  /// Queues an event and returns at once. Never throws.
  void track(String name, [Map<String, Object?>? properties]) => _backend.track(name, properties);

  /// Records a `Screen Viewed` event. Screens are named by the app.
  void trackScreenView(String name) => _backend.trackScreenView(name);

  /// The visitor's tracking choice, remembered on the device. `false` stops behavioural collection
  /// even without `requireTrackingConsent`, and forgets the events, visit and app opens still waiting.
  void setTrackingConsent(bool granted) => _backend.setTrackingConsent(granted);

  /// The user's own answer to marketing push; independent of the OS permission. Completes once
  /// Kirora has recorded it; throws [KiroraApiError], [UserTokenError] or [KiroraError] when it
  /// hasn't, and the earlier choice then stands.
  Future<void> setPushConsent(bool granted) => _backend.setPushConsent(granted);

  /// The platform's prompt, then registration if granted.
  Future<PushPermission> requestPushPermission() => _backend.requestPushPermission();

  /// This device's push, for an app's "notifications on/off" setting. Never prompts. The platform's
  /// permission first (`denied`, `unanswered`, `unsupported`); with it granted, `enabled` when this
  /// device is registered for the signed-in user, `disabled` otherwise (turned off, signed out, or
  /// the registration failed).
  Future<PushStatus> getPushStatus() => _backend.getPushStatus();

  /// The device's own push on/off, kept on the device rather than with the user: it survives
  /// sign-out and applies to whoever signs in next. `false` detaches the device (retried in the
  /// background as `logout()`'s detachment is), and while it holds, `identify()` does not register
  /// it. `true` forgets the choice and registers if permission is already granted, never
  /// prompting; `requestPushPermission()` answered `granted` also turns it back on. Never fails.
  /// Not marketing consent: that is [setPushConsent].
  Future<void> setPushEnabled(bool enabled) => _backend.setPushEnabled(enabled);

  /// Stops this client's timers and listeners at once, without sending or deleting anything: for
  /// hot reload, tests and apps that replace their client. Events still waiting stay on the device
  /// for the next client.
  void destroy() {
    _backend.destroy();
    if (identical(active, this)) active = null;
  }

  /// Sends waiting events now. Rarely needed.
  Future<void> flush() => _backend.flush();

  /// A snapshot of the SDK's state: identity, ids, consent and the waiting queue.
  Future<KiroraState> getState() => _backend.getState();

  /// A tap on a Kirora notification or one of its buttons (the data is the push's own, plus Kirora's
  /// `kirora_*` keys). The native SDK has reported it to Kirora (waiting 1.5 seconds at most) and
  /// opened its link first. A tap that launched the app is delivered when you first listen.
  Stream<NotificationData> get onNotificationClicked => _backend.onNotificationClicked;

  /// A Kirora push arriving, in any app state it is drawn in. Android only.
  Stream<NotificationData> get onNotificationReceived => _backend.onNotificationReceived;

  /// Android: forward a new FCM token if your own messaging service receives it instead of the
  /// SDK's. iOS reads the APNs token itself; this does nothing there.
  void onNewPushToken(String token) => _backend.onNewPushToken(token);

  void _stop() => _backend.stop();

  /// For tests: stops and forgets the active instance.
  static void resetForTesting() {
    active?._stop();
    active = null;
  }
}
