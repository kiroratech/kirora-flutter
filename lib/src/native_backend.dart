import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'state.dart';
import 'capture.dart';
import 'errors.dart';
import 'options.dart';
import 'version.dart';

const kiroraChannelName = 'io.kirora.flutter/sdk';

/// Hands every call to the native Kirora SDK (Android, iOS) over a method channel. `fetchUserToken`
/// stays in Dart: the native SDK calls back into it over the same channel. There is one native client
/// per app, so once [stop]ped (replaced by a newer instance, or destroyed) this backend sends nothing.
class NativeBackend {
  final LogLevel _logLevel;

  /// This instance's native client. This handler takes over the channel before its `configure`
  /// reaches native, so a failure the old client reports in between carries the old generation and
  /// is dropped rather than signing out this one. Seeded from the clock so a hot restart, which
  /// resets Dart statics but not native, never reuses a number.
  final int _generation = ++_lastGeneration;
  static int _lastGeneration = DateTime.now().microsecondsSinceEpoch;

  /// With [available] false (no native SDK on this platform) nothing reaches the channel: every
  /// call is a safe no-op, and one error log says why.
  NativeBackend(KiroraOptions options, this._channel, {bool available = true})
      : _logLevel = options.logLevel,
        _consentByDefault = !options.requireTrackingConsent {
    _capture = EventCapture(options.beforeSend, onError: _logError);
    if (!available) {
      _becomeUnavailable();
      _configured = Future<void>.error(MissingPluginException())..ignore();
      return;
    }
    final fetchUserToken = options.fetchUserToken;
    final handleDeepLink = options.handleDeepLink;
    final push = options.push;
    final foreground = push?.onForegroundNotification;
    final authFailed = options.onAuthenticationFailed;
    // The native SDK calls back for the app's token, the foreground decision, taps and pushes.
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'fetchUserToken':
          if (fetchUserToken == null) throw MissingPluginException();
          String? token;
          try {
            token = await fetchUserToken();
          } catch (e) {
            throw PlatformException(code: 'FETCH_USER_TOKEN_FAILED', message: e.toString());
          }
          // No token is a failed fetch on both platforms, never an empty token sent to Kirora.
          if (token == null || token.isEmpty) {
            throw PlatformException(code: 'FETCH_USER_TOKEN_FAILED', message: 'fetchUserToken gave no token');
          }
          return token;
        case 'foregroundNotification':
          if (foreground == null) return true;
          try {
            return await foreground(_strings(call.arguments)) != false;
          } catch (_) {
            return true;
          }
        case 'handleDeepLink':
          final args = _args(call.arguments);
          final url = Uri.tryParse(args['url'] as String? ?? '');
          if (handleDeepLink == null || url == null) return false;
          // The native SDK has stopped waiting and opened the link itself: the app must not also.
          final deadline = args['deadline'];
          if (deadline is num && DateTime.now().millisecondsSinceEpoch > deadline) return false;
          try {
            return await handleDeepLink(url) == true;
          } catch (_) {
            return false;
          }
        case 'authenticationFailed':
          final args = _args(call.arguments);
          if (authFailed == null || args['generation'] != _generation) return null;
          final reason = AuthenticationFailure.values.where((r) => r.wireName == args['reason']).firstOrNull;
          if (reason == null) return null;
          try {
            authFailed(reason);
          } catch (e) {
            _logError('onAuthenticationFailed threw: ${e.runtimeType}');
          }
        case 'notificationClicked':
          _clicks.add(_strings(call.arguments));
        case 'notificationReceived':
          _received.add(_strings(call.arguments));
        default:
          throw MissingPluginException();
      }
      return null;
    });
    final configured = _channel.invokeMethod<Object?>('configure', {
      'clientKey': options.clientKey.trim(),
      'apiUrl': options.apiUrl,
      'push': push != null,
      'pushAppId': push?.pushAppId,
      'requireTrackingConsent': options.requireTrackingConsent,
      'trackSessions': options.trackSessions,
      'trackAppLifecycle': options.trackAppLifecycle,
      'logLevel': options.logLevel.name,
      'hasTokenProvider': fetchUserToken != null,
      'smallIcon': push?.smallIcon,
      'accentColor': push?.accentColor,
      'defaultChannelId': push?.defaultChannelId,
      'defaultChannelName': push?.defaultChannelName,
      'hasForegroundHandler': foreground != null,
      'hasDeepLinkHandler': handleDeepLink != null,
      'hasAuthenticationFailedHandler': authFailed != null,
      'generation': _generation,
      'sdkVersion': sdkVersion,
    }).then((answer) {
      // The native SDK's tracking answer at setup: a remembered choice, or the default.
      final consent = _args(answer)['trackingConsent'];
      _storedConsent = consent is bool ? consent : _consentByDefault;
    }, onError: (Object e) {
      if (e is MissingPluginException) {
        // The plugin isn't registered (an app's own unit tests): every later call is a no-op.
        _becomeUnavailable();
        throw e;
      }
      // Kept for the calls that throw (identify), so the app hears the real cause.
      final message = e is PlatformException ? (e.message ?? e.code) : '$e';
      _setupError = KiroraError('Kirora could not be set up: $message');
      _logError('native setup failed: $message');
    });
    _configured = configured..ignore();
  }

  /// False where there is no native Kirora SDK: every call does nothing.
  bool get isAvailable => _isAvailable;
  bool _isAvailable = true;

  static bool _toldUnavailable = false;

  void _becomeUnavailable() {
    _isAvailable = false;
    if (_toldUnavailable) return;
    _toldUnavailable = true;
    _logError(unavailableMessage);
  }

  /// Logged once where there is no native Kirora SDK.
  static const unavailableMessage =
      "The native Kirora SDK isn't linked, so Kirora does nothing. It runs on Android and iOS: run the "
      "app there, and rebuild it after adding kirora_flutter. In your app's tests, use KiroraMock from "
      "package:kirora_flutter/testing.dart.";

  final MethodChannel _channel;
  late final Future<void> _configured;

  /// Why the native SDK refused to set up, thrown by [identify] and [setPushConsent].
  KiroraError? _setupError;

  /// Replaced by a newer instance, or destroyed: every call does nothing.
  bool _stopped = false;

  /// Whether tracking is allowed: the app's latest choice, else the native SDK's answer at setup
  /// (null until it answers). `beforeSend` never sees an event tracking doesn't allow.
  bool? get _consent => _freshConsent ?? _storedConsent;
  bool? _freshConsent;
  bool? _storedConsent;
  final bool _consentByDefault;

  /// The latest tracking choice not yet sent, waiting for setup: handed to the native SDK at once
  /// if this instance stops first, so a refusal is never lost to a replacement.
  bool? _unsentConsent;
  int _unsentConsents = 0;
  late final EventCapture _capture;

  void _logError(String message) {
    // ignore: avoid_print
    if (_logLevel != LogLevel.none) print('[Kirora] $message');
  }

  // Native events start with the first listener, so a tap that launched the app is delivered to it.
  late final StreamController<NotificationData> _clicks =
      StreamController.broadcast(onListen: _syncEvents, onCancel: _syncEvents);
  late final StreamController<NotificationData> _received =
      StreamController.broadcast(onListen: _syncEvents, onCancel: _syncEvents);

  void _syncEvents() => _fire('setNotificationEvents', {
        'clicked': _clicks.hasListener,
        'received': _received.hasListener,
      });

  static Map<Object?, Object?> _args(Object? arguments) => arguments is Map ? arguments : const {};

  static NotificationData _strings(Object? arguments) => {
        for (final e in (arguments as Map? ?? const {}).entries)
          if (e.value != null) e.key.toString(): e.value.toString(),
      };

  Stream<NotificationData> get onNotificationClicked => _clicks.stream;

  Stream<NotificationData> get onNotificationReceived => _received.stream;

  Future<void> identify([String? token]) => _surfacing('identify', {'token': token});

  Future<void> setPushConsent(bool granted) => _surfacing('setPushConsent', {'granted': granted});

  /// Sends [method] once setup has answered, unless this instance has been stopped (replaced or
  /// destroyed) by either side of that wait: the one native client then belongs to someone else.
  /// One wait for setup, so calls reach the native SDK in the order the app made them.
  /// With [surfaceSetupError], a setup the native SDK refused is thrown instead.
  /// A [_Later] call is built only then, and nothing is sent when it builds null.
  Future<T?> _send<T>(String method, [Object? arguments, bool surfaceSetupError = false]) async {
    if (_stopped) throw const _NotSent();
    await _configured;
    if (_stopped) throw const _NotSent();
    final setupError = _setupError;
    if (surfaceSetupError && setupError != null) throw setupError;
    if (arguments is _Later) {
      final call = arguments.build() ?? (throw const _NotSent());
      return _channel.invokeMethod<T>(call.method, call.arguments);
    }
    return _channel.invokeMethod<T>(method, arguments);
  }

  /// A call that never fails: [fallback] when nothing was sent, there is no native SDK, or it failed.
  Future<R> _quietly<R>(String method, Object? arguments, R fallback, [R Function(Object? answer)? read]) async {
    try {
      final answer = await _send<Object?>(method, arguments);
      return read == null ? fallback : read(answer);
    } catch (_) {
      return fallback;
    }
  }

  /// A call whose failure the app hears: the native SDK's error as [UserTokenError],
  /// [KiroraApiError] or [KiroraError] (a setup problem). Where there is no native SDK, or once this
  /// instance is stopped, it does nothing.
  Future<void> _surfacing(String method, Object? arguments) async {
    try {
      await _send<void>(method, arguments, true);
    } on _NotSent {
      return;
    } on MissingPluginException {
      return; // no native SDK: every call is a no-op, as the one error log said
    } on PlatformException catch (e) {
      throw _error(e);
    }
  }

  static KiroraError _error(PlatformException e) => switch (e.code) {
        'USER_TOKEN_ERROR' => UserTokenError(e.message ?? 'Could not obtain a user token', e),
        'KIRORA_API_ERROR' => _apiError(e),
        _ => KiroraError(e.message ?? e.code),
      };

  static KiroraApiError _apiError(PlatformException e) {
    final d = _args(e.details);
    return KiroraApiError(
      (d['status'] as num?)?.toInt() ?? 0,
      d['code'] as String?,
      e.message ?? 'Kirora refused the call',
      retryAfterMs: (d['retryAfterMs'] as num?)?.toInt(),
    );
  }

  Future<void> _fire(String method, [Object? arguments]) => _quietly<void>(method, arguments, null);

  /// [_fire] for a call [build] makes once setup has answered, in call order; null sends nothing.
  void _fireAfterSetup(MethodCall? Function() build) => _fire('', _Later(build));

  /// Never fails.
  Future<void> logout() => _fire('logout');

  /// Never throws.
  void track(String name, [Map<String, Object?>? properties]) {
    if (!_tracking) return;
    final event = _capture.copy(name, properties);
    if (event != null) _forward(event);
  }

  void trackScreenView(String name) {
    if (_tracking) _forward(_capture.screen(name));
  }

  /// False when nothing may be tracked now: stopped, no native SDK, or tracking refused.
  bool get _tracking => !_stopped && _isAvailable && _consent != false;

  /// Runs beforeSend before the event crosses to the native SDK and is stored: at once when tracking
  /// is allowed, or, while setup hasn't said whether it is, once it has (still sent in call order).
  void _forward(PendingEvent event) {
    if (_consent == true) {
      final call = _released(event);
      if (call != null) _fire(call.method, call.arguments);
    } else {
      _fireAfterSetup(() => _storedConsent == true ? _released(event) : null);
    }
  }

  MethodCall? _released(PendingEvent event) {
    final kept = _capture.release(event);
    if (kept == null) return null;
    final p = kept.properties;
    // An unchanged screen view is the native SDK's own.
    if (event.screen && p == null) return MethodCall('trackScreenView', {'name': event.properties['name']});
    return MethodCall('track', {'name': event.name, 'properties': p == null ? null : jsonEncode(p)});
  }

  void setTrackingConsent(bool granted) {
    if (_stopped) return;
    _freshConsent = granted;
    if (!_isAvailable) return;
    _unsentConsent = granted;
    _unsentConsents++;
    _fireAfterSetup(() {
      if (--_unsentConsents == 0) _unsentConsent = null;
      return MethodCall('setTrackingConsent', {'granted': granted});
    });
  }

  /// Sends the choice still waiting for setup now, ahead of whatever this instance's stop lets
  /// through next (a destroy, a newer instance's setup), so the native SDK records it first.
  void _handOverConsent() {
    final choice = _unsentConsent;
    if (choice == null || !_isAvailable) return;
    _unsentConsent = null;
    _channel.invokeMethod<void>('setTrackingConsent', {'granted': choice}).catchError((Object _) {});
  }

  Future<PushPermission> requestPushPermission() => _quietly(
        'requestPushPermission',
        null,
        PushPermission.unsupported,
        (a) => PushPermission.values.firstWhere((p) => p.name == a, orElse: () => PushPermission.unsupported),
      );

  Future<PushStatus> getPushStatus() => _quietly(
        'getPushStatus',
        null,
        PushStatus.unsupported,
        (a) => PushStatus.values.firstWhere((p) => p.name == a, orElse: () => PushStatus.unsupported),
      );

  /// Never fails: the native SDK logs its own errors.
  Future<void> setPushEnabled(bool enabled) => _fire('setPushEnabled', {'enabled': enabled});

  Future<void> flush() => _fire('flush');

  Future<KiroraState> getState() async {
    final m = await _quietly<Map<Object?, Object?>>('getState', null, const {}, (a) => a is Map ? a : const {});
    return KiroraState(
      isInitialized: m['isInitialized'] == true,
      isIdentified: m['isIdentified'] == true,
      deviceId: _string(m['deviceId']),
      sessionId: _string(m['sessionId']),
      pushToken: _string(m['pushToken']),
      trackingConsent: m['trackingConsent'] == true,
      pushConsent: m['pushConsent'] == true,
      queuedEventCount: m['queuedEventCount'] is num ? (m['queuedEventCount'] as num).toInt() : 0,
    );
  }

  static String? _string(Object? value) => value is String ? value : null;

  void onNewPushToken(String token) => _fire('onNewPushToken', {'token': token});

  /// Destroys the native client, unless this instance was already replaced: the client then is the
  /// newer instance's, and stays. Sent at once, not after setup, so it can't arrive after a newer
  /// instance's setup and destroy that instance's client.
  void destroy() {
    if (_stopped) return;
    _handOverConsent();
    if (_isAvailable) _channel.invokeMethod<void>('destroy').catchError((Object _) {});
    stop();
  }

  /// Stops this instance for good. The channel's handler is cleared only once, here, so a replaced
  /// instance's later destroy() never removes the newer instance's.
  void stop() {
    if (_stopped) return;
    _handOverConsent();
    _stopped = true;
    _channel.setMethodCallHandler(null);
    _clicks.close();
    _received.close();
  }
}

/// A call built when it is sent, after setup; null sends nothing.
class _Later {
  const _Later(this.build);

  final MethodCall? Function() build;
}

/// A call not sent because the instance was stopped.
class _NotSent implements Exception {
  const _NotSent();
}
