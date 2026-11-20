// ignore_for_file: prefer_initializing_formals
import 'dart:async';

/// How much the SDK prints. Never includes tokens or event data.
enum LogLevel { none, error, debug }

/// The answers of `requestPushPermission()`.
enum PushPermission {
  granted,
  denied,

  /// The prompt was dismissed without an answer.
  unanswered,
  unsupported,
}

/// The answers of `getPushStatus()`, for an app's "notifications on/off" setting.
enum PushStatus {
  /// Permission granted, and this device is registered for the signed-in user.
  enabled,

  /// Permission granted, but the device is not registered: turned off with `setPushEnabled(false)`,
  /// signed out, or the registration failed.
  disabled,
  denied,

  /// The platform's prompt has not been answered yet.
  unanswered,
  unsupported,
}

/// A Kirora push as the app sees it: the sender's own data, plus Kirora's `kirora_*` keys.
typedef NotificationData = Map<String, String>;

/// Why the user's token failed outside a method call (see [KiroraOptions.onAuthenticationFailed]).
enum AuthenticationFailure {
  /// `fetchUserToken` threw, gave no token, or ran out of time.
  fetchFailed('fetch_failed'),

  /// Kirora answered 401 and there was no fresh token to try, or it refused the fresh one.
  refused('refused');

  const AuthenticationFailure(this.wireName);

  /// The name the native SDKs and the spec use.
  final String wireName;
}

/// Turns push on. Kirora chooses the push app unless the workspace has several and [pushAppId] names one.
class KiroraPushOptions {
  const KiroraPushOptions({
    this.pushAppId,
    this.smallIcon,
    this.accentColor,
    this.defaultChannelId,
    this.defaultChannelName,
    this.onForegroundNotification,
  });

  final String? pushAppId;

  /// Android: name of the small monochrome drawable for notifications (`ic_notification`). Falls
  /// back to the manifest meta-data, then the launcher icon.
  final String? smallIcon;

  /// Android: accent colour of notifications (`#RRGGBB`).
  final String? accentColor;

  /// Android: id and name of the default channel the SDK creates at start (`kirora_default`,
  /// `Notifications`).
  final String? defaultChannelId;
  final String? defaultChannelName;

  /// Android and iOS: decides whether a push is shown while the app is open. It is shown by default;
  /// return `false` to hold one back. Must answer within about 1.5 s, or the push is shown.
  final FutureOr<bool> Function(NotificationData data)? onForegroundNotification;
}

/// What `beforeSend` sees: a detached JSON copy of one event the app tracked.
class BeforeSendEvent {
  BeforeSendEvent({required this.name, required this.properties, required this.context});

  /// The event's name. Changing it has no effect: the SDK keeps the original.
  final String name;
  final Map<String, Object?> properties;

  /// Empty: the native SDK builds the context, with no app-supplied values in it.
  final Map<String, Object?> context;
}

/// Redacts or drops an event before it is stored: return the event with fields removed or changed,
/// or null to drop it. Must answer synchronously; a throw drops the event.
typedef BeforeSend = BeforeSendEvent? Function(BeforeSendEvent event);

/// Configuration for [Kirora].
class KiroraOptions {
  const KiroraOptions({
    required this.clientKey,
    this.fetchUserToken,
    this.push,
    this.requireTrackingConsent = false,
    this.trackSessions = true,
    this.trackAppLifecycle = false,
    this.logLevel = LogLevel.error,
    this.apiUrl = 'https://api.kirora.io',
    this.beforeSend,
    this.onAuthenticationFailed,
    this.handleDeepLink,
  });

  /// The workspace's public key (`kirora_pk_…`), safe to ship.
  final String clientKey;

  /// Asks your server for a signed user token; called by `identify()` without a token and when
  /// Kirora refuses an expired one.
  final Future<String?> Function()? fetchUserToken;

  /// Register this device for push. The native SDK reads the push token itself.
  final KiroraPushOptions? push;

  /// Track and store nothing until `setTrackingConsent(true)`.
  final bool requireTrackingConsent;

  /// `Session Started` when a visit begins, `context.sessionId` on every event.
  final bool trackSessions;

  /// `Application Installed`, `Opened`, `Updated` and `Backgrounded`.
  final bool trackAppLifecycle;

  /// What the SDK prints (default `error`).
  final LogLevel logLevel;

  /// The Kirora API base URL. Must be `https`, except for local hosts.
  final String apiUrl;

  /// Redacts or drops each event the app tracks (`track`, `trackScreenView`) before it is stored.
  /// The native SDK's automatic events (`Session Started`, the `Application …` events) carry no
  /// app-supplied values and do not pass through it.
  final BeforeSend? beforeSend;

  /// Called when the user's token fails outside a method call, where nothing else would tell the
  /// app: a background refresh whose `fetchUserToken` failed, or a fresh token Kirora refused.
  /// Called once per failure, and again only after a request with that user's token succeeds or
  /// `identify()` is called. Never for a failure a method call throws (`identify()`,
  /// `setPushConsent()`), a cancelled call, or while the user signs out. The app can sign the user
  /// out or ask them to sign in again.
  final void Function(AuthenticationFailure reason)? onAuthenticationFailed;

  /// Called with a push's link when it is tapped; answer `true` when the app opened it itself.
  /// Otherwise the SDK opens it, as it also does without an answer within 1.5 seconds.
  final FutureOr<bool> Function(Uri url)? handleDeepLink;
}
