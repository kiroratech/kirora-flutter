import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirora_flutter/kirora_flutter.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('io.kirora.flutter/sdk');
  late List<MethodCall> calls;
  late Object? Function(MethodCall) answer;
  late List<String> hooked;

  setUp(() {
    Kirora.resetForTesting();
    calls = [];
    answer = (_) => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer(call);
    });
  });

  tearDown(() {
    Kirora.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Kirora make({
    Future<String?> Function()? fetchUserToken,
    KiroraPushOptions? push,
    void Function(AuthenticationFailure)? onAuthenticationFailed,
  }) =>
      Kirora(
        KiroraOptions(
          clientKey: ' kirora_pk_n ',
          fetchUserToken: fetchUserToken,
          push: push,
          onAuthenticationFailed: onAuthenticationFailed,
          trackAppLifecycle: true,
          logLevel: LogLevel.none,
        ),
        channel: channel,
      );

  Object? generationOf(MethodCall configure) => (configure.arguments as Map)['generation'];

  test('the native SDK is configured with the options, key trimmed', () async {
    answer = (c) => c.method == 'getState' ? <String, Object?>{'isInitialized': true, 'queuedEventCount': 2} : null;
    final k = make(push: const KiroraPushOptions(pushAppId: 'app_1'), fetchUserToken: () async => 't');
    final state = await k.getState();

    expect(calls.first.method, 'configure');
    expect(calls.first.arguments, {
      'clientKey': 'kirora_pk_n',
      'apiUrl': 'https://api.kirora.io',
      'push': true,
      'pushAppId': 'app_1',
      'requireTrackingConsent': false,
      'trackSessions': true,
      'trackAppLifecycle': true,
      'logLevel': 'none',
      'hasTokenProvider': true,
      'smallIcon': null,
      'accentColor': null,
      'defaultChannelId': null,
      'defaultChannelName': null,
      'hasForegroundHandler': false,
      'hasDeepLinkHandler': false,
      'hasAuthenticationFailedHandler': false,
      'generation': isA<int>(),
      'sdkVersion': sdkVersion,
    });
    expect(state.isInitialized, isTrue);
    expect(state.queuedEventCount, 2);
    expect(state.deviceId, isNull);
  });

  test('calls go straight to the native SDK, properties as JSON', () async {
    final k = make();
    await k.identify('tok');
    k.track('Order Completed', {'id': 1, 'when': DateTime.utc(1970)});
    k.track('No Props');
    k.trackScreenView('Home');
    k.setTrackingConsent(true);
    k.setPushConsent(false);
    k.onNewPushToken('t1');
    await k.flush();
    await k.logout();

    expect(
      calls.skip(1).map((c) => [c.method, c.arguments]).toList(),
      [
        ['identify', {'token': 'tok'}],
        ['track', {'name': 'Order Completed', 'properties': '{"id":1,"when":"1970-01-01T00:00:00.000Z"}'}],
        ['track', {'name': 'No Props', 'properties': null}],
        ['trackScreenView', {'name': 'Home'}],
        ['setTrackingConsent', {'granted': true}],
        ['setPushConsent', {'granted': false}],
        ['onNewPushToken', {'token': 't1'}],
        ['flush', null],
        ['logout', null],
      ],
    );
  });

  test('the permission answer maps to PushPermission', () async {
    answer = (c) => c.method == 'requestPushPermission' ? 'unanswered' : null;
    expect(await make().requestPushPermission(), PushPermission.unanswered);
  });

  test('a token failure in the native SDK is a UserTokenError; a setup problem is a KiroraError', () async {
    answer = (c) => c.method == 'identify' ? throw PlatformException(code: 'USER_TOKEN_ERROR', message: 'nope') : null;
    await expectLater(make().identify(), throwsA(isA<UserTokenError>()));

    answer = (c) => c.method == 'identify' ? throw PlatformException(code: 'OTHER', message: 'boom') : null;
    await expectLater(make().identify('t'), throwsA(isA<KiroraError>().having((e) => e.message, 'message', 'boom')));
  });

  test('fetchUserToken stays in Dart: the native SDK calls back for a token', () async {
    var fail = false;
    make(fetchUserToken: () async => fail ? throw StateError('server down') : 'fresh.token');
    Future<ByteData?> ask() {
      final done = Completer<ByteData?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(const MethodCall('fetchUserToken')),
        done.complete,
      );
      return done.future;
    }

    final ok = await ask();
    expect(const StandardMethodCodec().decodeEnvelope(ok!), 'fresh.token');
    fail = true;
    final bad = await ask();
    expect(
      () => const StandardMethodCodec().decodeEnvelope(bad!),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'FETCH_USER_TOKEN_FAILED')),
    );
  });

  Future<Object?> fromNative(String method, [Object? arguments]) async {
    final done = Completer<ByteData?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
      done.complete,
    );
    return const StandardMethodCodec().decodeEnvelope((await done.future)!);
  }

  test('the push look and the foreground hook are passed to the native SDK', () async {
    final k = make(
      push: KiroraPushOptions(
        smallIcon: 'ic_notification',
        accentColor: '#FF5500',
        defaultChannelId: 'promos',
        defaultChannelName: 'Promotions',
        onForegroundNotification: (d) => d['plan'] != 'muted',
      ),
    );
    await k.getState();
    expect(calls.first.arguments, containsPair('smallIcon', 'ic_notification'));
    expect(calls.first.arguments, containsPair('accentColor', '#FF5500'));
    expect(calls.first.arguments, containsPair('defaultChannelId', 'promos'));
    expect(calls.first.arguments, containsPair('defaultChannelName', 'Promotions'));
    expect(calls.first.arguments, containsPair('hasForegroundHandler', true));
  });

  test('the foreground hook answers each push, and a failing or absent hook shows the push', () async {
    var fail = false;
    make(
      push: KiroraPushOptions(onForegroundNotification: (d) async {
        if (fail) throw StateError('hook broke');
        return d['plan'] != 'muted';
      }),
    );
    expect(await fromNative('foregroundNotification', {'plan': 'pro'}), isTrue);
    expect(await fromNative('foregroundNotification', {'plan': 'muted'}), isFalse);
    fail = true;
    expect(await fromNative('foregroundNotification', {'plan': 'pro'}), isTrue);

    Kirora.resetForTesting();
    make(); // no hook given
    expect(await fromNative('foregroundNotification', {'plan': 'muted'}), isTrue);
  });

  test('listening starts the native events, hears taps and pushes, and stops them again', () async {
    final k = make();
    final taps = <Map<String, String>>[];
    final pushes = <Map<String, String>>[];
    final tapSub = k.onNotificationClicked.listen(taps.add);
    final pushSub = k.onNotificationReceived.listen(pushes.add);
    await pumpEventQueue();
    await fromNative('notificationClicked', {'plan': 'pro'});
    await fromNative('notificationReceived', {'kirora': 'true'});
    await pumpEventQueue();
    expect(taps, [
      {'plan': 'pro'}
    ]);
    expect(pushes, [
      {'kirora': 'true'}
    ]);

    await tapSub.cancel();
    await pushSub.cancel();
    await pumpEventQueue();
    final events = calls
        .where((c) => c.method == 'setNotificationEvents')
        .map((c) {
          final a = c.arguments as Map;
          return '${a['clicked'] == true ? 'c' : '-'}${a['received'] == true ? 'r' : '-'}';
        })
        .toList();
    expect(events, contains('cr'));
    expect(events.last, '--');
  });

  test('a second native instance stops answering for the first', () async {
    make(fetchUserToken: () async => 'a');
    make(fetchUserToken: () async => 'b');
    final done = Completer<ByteData?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('fetchUserToken')),
      done.complete,
    );
    expect(const StandardMethodCodec().decodeEnvelope((await done.future)!), 'b');
  });

  test('a replaced instance sends nothing, and its destroy() leaves the newer client alone', () async {
    final old = make(fetchUserToken: () async => 'a');
    final current = make(fetchUserToken: () async => 'b');
    await pumpEventQueue();
    calls.clear();

    old.track('Late');
    await old.identify('t');
    old.destroy();
    await pumpEventQueue();
    expect(calls, isEmpty);
    expect(Kirora.active, same(current));

    // The newer instance still answers the native SDK and still sends.
    expect(await fromNative('fetchUserToken'), 'b');
    current.track('Now');
    await pumpEventQueue();
    expect(calls.map((c) => c.method), ['track']);
  });

  test('destroy() then a new Kirora: destroy reaches the native side before the new setup', () async {
    final old = make();
    await pumpEventQueue();
    calls.clear();
    old.destroy();
    make();
    await pumpEventQueue();
    expect(calls.map((c) => c.method), ['destroy', 'configure']);
  });

  test('a call queued on an instance replaced before its setup answered is never sent', () async {
    final setup = Completer<void>();
    answer = (c) => c.method == 'configure' && !setup.isCompleted ? setup.future : null;
    final old = make();
    old.logout();
    old.track('Lost');
    make();
    setup.complete();
    await pumpEventQueue();
    expect(calls.map((c) => c.method), ['configure', 'configure']);
  });

  test('a tracking choice still waiting reaches the native SDK before a replacement or destroy', () async {
    for (final (end, next) in [((Kirora k) => make(), 'configure'), ((Kirora k) => k.destroy(), 'destroy')]) {
      calls.clear();
      final setup = Completer<void>();
      answer = (c) => c.method == 'configure' && !setup.isCompleted ? setup.future : null;
      final old = make();
      old.setTrackingConsent(true);
      old.setTrackingConsent(false);
      end(old);
      setup.complete();
      await pumpEventQueue();
      // Once, with the latest choice, before the next setup or the destroy.
      expect(calls.map((c) => [c.method, c.arguments is Map ? (c.arguments as Map)['granted'] : null]).take(3), [
        ['configure', null],
        ['setTrackingConsent', false],
        [next, null],
      ]);
      expect(calls.where((c) => c.method == 'setTrackingConsent'), hasLength(1));
      Kirora.resetForTesting();
    }
  });

  group('beforeSend never sees an event tracking does not allow', () {
    Kirora make2({bool require = false}) => Kirora(
          KiroraOptions(
            clientKey: 'kirora_pk_n',
            logLevel: LogLevel.none,
            requireTrackingConsent: require,
            beforeSend: (e) {
              hooked.add(e.name);
              return e;
            },
          ),
          channel: channel,
        );

    setUp(() => hooked = []);

    test('waits for setup to say whether tracking is allowed', () async {
      final setup = Completer<Object?>();
      answer = (c) => c.method == 'configure' ? setup.future : null;
      final k = make2();
      k.track('Before Setup');
      k.trackScreenView('Home');
      expect(hooked, isEmpty);
      setup.complete({'trackingConsent': false}); // a refusal remembered on the device
      await pumpEventQueue();
      expect(hooked, isEmpty);
      expect(calls.where((c) => c.method.startsWith('track')), isEmpty);
    });

    test('with consent required and none given, nothing reaches the hook', () async {
      answer = (c) => c.method == 'configure' ? {'trackingConsent': false} : null;
      final k = make2(require: true);
      await pumpEventQueue();
      k.track('Ungranted');
      k.setTrackingConsent(true);
      k.track('Granted');
      k.setTrackingConsent(false);
      k.track('Withdrawn');
      await pumpEventQueue();
      expect(hooked, ['Granted']);
      expect(calls.where((c) => c.method == 'track').map((c) => (c.arguments as Map)['name']), ['Granted']);
    });

    test('a fresh choice applies at once, before setup has answered', () async {
      final setup = Completer<Object?>();
      answer = (c) => c.method == 'configure' ? setup.future : null;
      final k = make2(require: true);
      k.setTrackingConsent(true);
      k.track('Granted');
      expect(hooked, ['Granted']);
      setup.complete({'trackingConsent': false});
      await pumpEventQueue();
      expect(calls.map((c) => c.method), ['configure', 'setTrackingConsent', 'track']);
    });
  });

  test('a setup the native SDK refused is the error identify() throws', () async {
    answer = (c) => c.method == 'configure' ? throw PlatformException(code: 'CONFIGURE_ERROR', message: 'apiUrl is not an address') : null;
    final k = make();
    await expectLater(
      k.identify('t'),
      throwsA(isA<KiroraError>().having((e) => e.message, 'message', contains('apiUrl is not an address'))),
    );
  });

  test('no token from fetchUserToken is a failed fetch, on both platforms', () async {
    make(fetchUserToken: () async => '');
    await expectLater(fromNative('fetchUserToken'), throwsA(isA<PlatformException>()));
    make(fetchUserToken: () async => null);
    await expectLater(fromNative('fetchUserToken'), throwsA(isA<PlatformException>()));
  });

  test('a toJson() that throws drops that event and never reaches the app', () async {
    final k = make();
    k.track('Bad', {'o': _ThrowingJson()});
    k.track('Good');
    await pumpEventQueue();
    expect(calls.where((c) => c.method == 'track').map((c) => (c.arguments as Map)['name']), ['Good']);
  });

  test('push status, the device on/off and destroy go to the native SDK', () async {
    answer = (c) => c.method == 'getPushStatus' ? 'denied' : null;
    final k = make(push: const KiroraPushOptions());
    expect(await k.getPushStatus(), PushStatus.denied);
    await k.setPushEnabled(false);
    k.destroy();
    await pumpEventQueue();
    final setCall = calls.firstWhere((c) => c.method == 'setPushEnabled');
    expect(setCall.arguments, {'enabled': false});
    expect(calls.map((c) => c.method), contains('destroy'));
    expect(Kirora.active, isNull);
  });

  test('an older native SDK without them answers unsupported and never throws', () async {
    answer = (c) => c.method == 'getPushStatus' || c.method == 'setPushEnabled'
        ? throw MissingPluginException()
        : null;
    final k = make(push: const KiroraPushOptions());
    expect(await k.getPushStatus(), PushStatus.unsupported);
    await k.setPushEnabled(true);
  });

  test('identify throws the native error; logout, flush and the rest never fail', () async {
    answer = (c) => switch (c.method) {
          'identify' => throw PlatformException(
              code: 'KIRORA_API_ERROR',
              message: 'refused',
              details: {'status': 401, 'code': 'UNAUTHORIZED', 'retryAfterMs': null},
            ),
          'logout' || 'flush' || 'getState' || 'requestPushPermission' => throw PlatformException(code: 'KIRORA_ERROR'),
          _ => null,
        };
    final k = make();
    await expectLater(
      k.identify('t'),
      throwsA(isA<KiroraApiError>().having((e) => e.status, 'status', 401).having((e) => e.code, 'code', 'UNAUTHORIZED')),
    );
    await k.logout();
    await k.flush();
    expect((await k.getState()).isInitialized, isFalse);
    expect(await k.requestPushPermission(), PushPermission.unsupported);

    answer = (c) => c.method == 'identify' ? throw PlatformException(code: 'KIRORA_ERROR') : null;
    await expectLater(k.identify('t'), throwsA(isA<KiroraError>()));
  });

  test('setPushConsent completes once recorded, and throws when Kirora has not recorded it', () async {
    answer = (_) => null;
    final k = make();
    await k.setPushConsent(true);
    expect(calls.last.arguments, {'granted': true});

    answer = (c) => c.method == 'setPushConsent'
        ? throw PlatformException(code: 'KIRORA_API_ERROR', message: 'down', details: {'status': 503, 'retryAfterMs': 2000})
        : null;
    await expectLater(
      k.setPushConsent(false),
      throwsA(isA<KiroraApiError>().having((e) => e.retryAfterMs, 'retryAfterMs', 2000)),
    );
    answer = (c) => c.method == 'setPushConsent' ? throw PlatformException(code: 'USER_TOKEN_ERROR') : null;
    await expectLater(k.setPushConsent(false), throwsA(isA<UserTokenError>()));
  });

  test('an event with a value JSON cannot hold is not forwarded', () async {
    final k = make();
    k.track('Bad', {'nan': double.nan});
    k.track('Good', {'when': DateTime.utc(1970)});
    await pumpEventQueue();
    final tracks = calls.where((c) => c.method == 'track').toList();
    expect(tracks.map((c) => (c.arguments as Map)['name']), ['Good']);
    expect(jsonDecode((tracks.single.arguments as Map)['properties'] as String), {'when': '1970-01-01T00:00:00.000Z'});
  });

  group('beforeSend runs in Dart on what the app tracks, before it is forwarded', () {
    Kirora withHook(BeforeSend hook) => Kirora(
          KiroraOptions(clientKey: 'kirora_pk_n', logLevel: LogLevel.none, beforeSend: hook),
          channel: channel,
        );
    List<MethodCall> sent() => calls.where((c) => c.method == 'track' || c.method == 'trackScreenView').toList();

    test('redacts, drops, and keeps the original name', () async {
      final k = withHook((e) => e.name == 'Drop Me'
          ? null
          : BeforeSendEvent(name: 'Renamed', properties: {...e.properties}..remove('email'), context: e.context));
      k.track('Signed Up', {'email': 'a@b.c', 'plan': 'pro'});
      k.track('Drop Me');
      await pumpEventQueue();
      expect(sent().map((c) => c.arguments), [
        {'name': 'Signed Up', 'properties': '{"plan":"pro"}'},
      ]);
    });

    test('a throw, an answer JSON cannot hold, or tracking from inside the hook drops the event', () async {
      late Kirora k;
      k = withHook((e) {
        if (e.name == 'Throws') throw StateError('no');
        if (e.name == 'NaN') return BeforeSendEvent(name: e.name, properties: {'x': double.nan}, context: {});
        if (e.name == 'Reenters') k.track('Inner');
        return e;
      });
      k.track('Throws');
      k.track('NaN');
      k.track('Reenters');
      k.track('Fine');
      await pumpEventQueue();
      expect(sent().map((c) => (c.arguments as Map)['name']), ['Reenters', 'Fine']);
    });

    test('a screen view goes as the native one unless redacted', () async {
      final k = withHook((e) => (e.properties['name'] == 'Secret')
          ? BeforeSendEvent(name: e.name, properties: {'name': 'redacted'}, context: e.context)
          : e);
      k.trackScreenView('Home');
      k.trackScreenView('Secret');
      await pumpEventQueue();
      expect(sent().map((c) => [c.method, c.arguments]), [
        ['trackScreenView', {'name': 'Home'}],
        ['track', {'name': 'Screen Viewed', 'properties': '{"name":"redacted"}'}],
      ]);
    });
  });

  test('a tapped link is offered to handleDeepLink over the channel', () async {
    Uri? got;
    Kirora(
      KiroraOptions(
        clientKey: 'kirora_pk_n',
        logLevel: LogLevel.none,
        handleDeepLink: (url) async {
          got = url;
          return url.host == 'mine.example';
        },
      ),
      channel: channel,
    );
    expect(calls.first.arguments, containsPair('hasDeepLinkHandler', true));
    Future<Object?> ask(String url, [int? deadline]) async {
      deadline ??= DateTime.now().millisecondsSinceEpoch + 1500;
      final reply = Completer<ByteData?>();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall('handleDeepLink', {'url': url, 'deadline': deadline})),
        reply.complete,
      );
      return const StandardMethodCodec().decodeEnvelope((await reply.future)!);
    }

    expect(await ask('https://mine.example/x'), isTrue);
    expect(got, Uri.parse('https://mine.example/x'));
    expect(await ask('https://other.example/'), isFalse);
    // Too late: the native SDK stopped waiting and opened it, so the app's router is never called.
    got = null;
    expect(await ask('https://mine.example/late', DateTime.now().millisecondsSinceEpoch - 1), isFalse);
    expect(got, isNull);
  });

  test('a background token failure reaches onAuthenticationFailed with its reason', () async {
    final reasons = <AuthenticationFailure>[];
    make(onAuthenticationFailed: (r) {
      reasons.add(r);
      if (r == AuthenticationFailure.refused) throw StateError('app bug'); // never reaches the SDK
    });
    expect(calls.first.arguments, containsPair('hasAuthenticationFailedHandler', true));
    final generation = generationOf(calls.first);
    await fromNative('authenticationFailed', {'reason': 'fetch_failed', 'generation': generation});
    await fromNative('authenticationFailed', {'reason': 'refused', 'generation': generation});
    await fromNative('authenticationFailed', {'reason': 'something_new', 'generation': generation}); // a reason this version doesn't know is ignored
    expect(reasons, [AuthenticationFailure.fetchFailed, AuthenticationFailure.refused]);
  });

  test('a late authentication failure from a replaced client never reaches the new one', () async {
    final first = <AuthenticationFailure>[];
    final second = <AuthenticationFailure>[];
    make(onAuthenticationFailed: first.add);
    final oldGeneration = generationOf(calls.last);
    make(onAuthenticationFailed: second.add);
    final newGeneration = generationOf(calls.last);
    expect(newGeneration, isNot(oldGeneration));

    await fromNative('authenticationFailed', {'reason': 'refused', 'generation': oldGeneration}); // the replaced client's background refresh
    await fromNative('authenticationFailed', {'reason': 'refused', 'generation': null}); // untagged
    expect(second, isEmpty);
    await fromNative('authenticationFailed', {'reason': 'fetch_failed', 'generation': newGeneration});
    expect(second, [AuthenticationFailure.fetchFailed]);
  });

  test('with no native SDK (web, desktop, an app\'s own unit tests) every call does nothing', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    final k = Kirora(const KiroraOptions(clientKey: 'kirora_pk_n', logLevel: LogLevel.none), channel: channel);
    await k.identify('t');
    k.track('E', {'a': 1});
    k.trackScreenView('Home');
    k.setTrackingConsent(true);
    k.setPushConsent(true);
    await k.flush();
    expect(await k.requestPushPermission(), PushPermission.unsupported);
    expect(await k.getPushStatus(), PushStatus.unsupported);
    await k.setPushEnabled(true);
    expect((await k.getState()).isInitialized, isFalse);
    await k.logout();
    k.destroy();
    expect(k.isAvailable, isFalse);
  });

  test('on a platform with no native SDK nothing reaches the channel, and it says so once', () async {
    final logs = <String>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await runZoned(
        () async {
          final k = Kirora(const KiroraOptions(clientKey: 'kirora_pk_n'));
          Kirora(const KiroraOptions(clientKey: 'kirora_pk_n'));
          expect(k.isAvailable, isFalse);
          k.track('E');
          await k.identify('t');
          expect(await k.getPushStatus(), PushStatus.unsupported);
        },
        zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => logs.add(line)),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    expect(calls, isEmpty);
    expect(logs.where((l) => l.contains("isn't linked")).length, lessThanOrEqualTo(1));
  });
}

class _ThrowingJson {
  Map<String, Object?> toJson() => throw StateError('not ready');
}
