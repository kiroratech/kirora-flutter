@preconcurrency import Flutter
import UIKit
@_spi(Wrapper) import Kirora

/// The iOS side of `io.kirora.flutter/sdk`: forwards Dart's calls to the Kirora iOS SDK and the
/// SDK's questions (user tokens, deep links, foreground display) and taps back to Dart. The SDK
/// does the work; nothing here reimplements it. The same channel contract as the Android plugin.
public final class KiroraFlutterPlugin: NSObject, FlutterPlugin {
    private static let channelName = "io.kirora.flutter/sdk"

    private let channel: FlutterMethodChannel
    private var kirora: Kirora?
    private var tokens: KiroraWrapper.TokenRequests?
    private var tapsOn = false
    /// This engine set Kirora up, and has a client to end when it goes.
    private var configured = false
    /// Read for its view controller: none means a headless engine (a background task's).
    private weak var registrar: FlutterPluginRegistrar?
    /// This engine has shown the app's UI.
    private var hasUi = false

    /// The engine that set Kirora up last: only it may change the process-wide callbacks and tap
    /// listener. Used on the main thread only.
    private static weak var owner: KiroraFlutterPlugin?
    private var ownsCallbacks: Bool { Self.owner === self }

    init(channel: FlutterMethodChannel) {
        self.channel = channel
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        // GeneratedPluginRegistrant runs this during didFinishLaunching: early enough for the tap
        // that launched the app, long before Dart creates the client.
        KiroraWrapper.installPushIntegration()
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
        let instance = KiroraFlutterPlugin(channel: channel)
        instance.registrar = registrar
        registrar.addMethodCallDelegate(instance, channel: channel)
        // Published, or the engine never calls detachFromEngine and its client outlives it.
        registrar.publish(instance)
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        guard configured else { return }
        configured = false
        endClient()
        // Only the engine that set Kirora up last clears the process-wide callbacks. Not the nil
        // setters, which mean "set up, with no handler": taps are held again, and the next tap's link
        // waits (10 s at most) for the next engine's handler.
        guard ownsCallbacks else { return }
        Self.owner = nil
        KiroraWrapper.wrapperDetached()
    }

    /// Destroys the client and detaches the tap listener, so taps are held for the next client
    /// instead of sent to a Dart side that no longer listens.
    private func endClient() {
        kirora?.destroy()
        kirora = nil
        setTaps(on: false)
    }

    // MARK: - Calls from Dart

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        if call.method == "configure" {
            // One client per process. A headless engine never takes it from the app's UI: that would
            // leave the UI with no client. Refused, its Kirora tracks nothing and identify() throws.
            hasUi = hasUi || registrar?.viewController != nil
            if !hasUi, let owner = Self.owner, owner !== self, owner.hasUi, owner.kirora != nil {
                result(FlutterError(code: "CONFIGURE_ERROR",
                                    message: "the app's UI already set Kirora up: set it up in the main isolate only",
                                    details: nil))
                return
            }
            configure(args)
            // Whether tracking is allowed now, so Dart's beforeSend never sees an event it isn't.
            // Not getState(), which reads the event queue from disk on the main thread.
            // Null when unknown, as on Android: Dart then uses its default.
            result(["trackingConsent": kirora.map { $0.trackingConsent as Any } ?? NSNull()])
            return
        }
        if call.method == "setNotificationEvents" {
            // The tap listener is process-wide, not the client's: Dart can stop listening at any time.
            setTaps(on: args["clicked"] as? Bool == true)
            result(nil)
            return
        }
        guard let kirora = kirora else {
            result(FlutterError(code: "NOT_CONFIGURED", message: "Kirora was not set up", details: nil))
            return
        }
        switch call.method {
        case "identify":
            let token = (args["token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            Task { @MainActor in
                do {
                    try await kirora.identify(token)
                    result(nil)
                } catch {
                    result(Self.flutterError(error))
                }
            }
        case "logout":
            Task { @MainActor in
                await kirora.logout()
                result(nil)
            }
        case "track":
            kirora.track(args["name"] as? String ?? "", properties: Self.properties(args["properties"]))
            result(nil)
        case "trackScreenView":
            kirora.trackScreenView(args["name"] as? String ?? "")
            result(nil)
        case "setTrackingConsent":
            kirora.setTrackingConsent(args["granted"] as? Bool == true)
            result(nil)
        case "setPushConsent":
            let granted = args["granted"] as? Bool == true
            Task { @MainActor in
                do {
                    try await kirora.setPushConsent(granted)
                    result(nil)
                } catch {
                    result(Self.flutterError(error))
                }
            }
        case "requestPushPermission":
            Task { @MainActor in result(await kirora.requestPushPermission().rawValue) }
        case "getPushStatus":
            Task { @MainActor in result(await kirora.getPushStatus().rawValue) }
        case "setPushEnabled":
            let enabled = args["enabled"] as? Bool == true
            Task { @MainActor in
                await kirora.setPushEnabled(enabled)
                result(nil)
            }
        case "flush":
            Task { @MainActor in
                await kirora.flush()
                result(nil)
            }
        case "getState":
            let state = kirora.getState()
            result([
                "isInitialized": state.isInitialized,
                "isIdentified": state.isIdentified,
                "deviceId": state.deviceId.map { $0 as Any } ?? NSNull(),
                "sessionId": state.sessionId.map { $0 as Any } ?? NSNull(),
                "pushToken": state.pushToken.map { $0 as Any } ?? NSNull(),
                "trackingConsent": state.trackingConsent,
                "pushConsent": state.pushConsent,
                "queuedEventCount": state.queuedEventCount,
            ] as [String: Any])
        case "onNewPushToken":
            // The SDK reads the APNs token itself (installPushIntegration).
            result(nil)
        case "destroy":
            endClient()
            // Process-wide in the SDK: without a client, a tapped push must not ask Dart. Not when a
            // newer engine has set Kirora up since: the handlers are its own.
            if ownsCallbacks {
                KiroraWrapper.setDeepLinkHandler(nil)
                KiroraWrapper.setForegroundPresentationHandler(nil)
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func configure(_ args: [String: Any]) {
        // A second configure (hot restart) replaces the client, and Dart's listeners start over.
        endClient()
        configured = true
        if let previous = Self.owner, previous !== self {
            // One native client per process, and this setup replaces it: the older engine's calls
            // now answer "not set up", and its tap listener stops taking this engine's taps.
            previous.endClient()
        }
        Self.owner = self
        KiroraWrapper.setSDK(name: "kirora-flutter", version: args["sdkVersion"] as? String ?? "0.1.0")

        var fetchUserToken: (@Sendable () async throws -> String?)?
        if args["hasTokenProvider"] as? Bool == true {
            let channel = self.channel
            // The request closure can't name the object it is passed to: it reaches it here.
            let box = TokenRequestsBox()
            let requests = KiroraWrapper.TokenRequests { requestId in
                DispatchQueue.main.async {
                    channel.invokeMethod("fetchUserToken", arguments: nil) { answer in
                        KiroraFlutterPlugin.answerToken(box.requests, requestId, answer)
                    }
                }
            }
            box.requests = requests
            tokens = requests
            fetchUserToken = { try await requests.fetchUserToken() }
        } else {
            tokens = nil
        }

        // A token that fails outside a call (a background refresh): Dart hears the spec's reason,
        // tagged with this setup's generation so a newer Dart instance ignores it.
        var onAuthenticationFailed: (@MainActor @Sendable (AuthenticationFailureReason) -> Void)?
        if args["hasAuthenticationFailedHandler"] as? Bool == true {
            let channel = self.channel
            let generation = (args["generation"] as? NSNumber)?.int64Value ?? 0
            onAuthenticationFailed = { reason in
                channel.invokeMethod(
                    "authenticationFailed", arguments: ["reason": reason.rawValue, "generation": generation])
            }
        }

        let push = args["push"] as? Bool == true
            ? KiroraPushOptions(pushAppId: (args["pushAppId"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            : nil
        kirora = Kirora(options: KiroraOptions(
            clientKey: (args["clientKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            fetchUserToken: fetchUserToken,
            onAuthenticationFailed: onAuthenticationFailed,
            push: push,
            requireTrackingConsent: args["requireTrackingConsent"] as? Bool == true,
            trackSessions: args["trackSessions"] as? Bool ?? true,
            trackAppLifecycle: args["trackAppLifecycle"] as? Bool == true,
            logLevel: LogLevel(rawValue: args["logLevel"] as? String ?? "") ?? .error,
            apiUrl: args["apiUrl"] as? String ?? "https://api.kirora.io"
        ))

        // Asked over the channel; the SDK waits 1.5 seconds at most, then acts as if unset.
        let channel = self.channel
        if args["hasDeepLinkHandler"] as? Bool == true {
            KiroraWrapper.setDeepLinkHandler { url in
                // Dart skips the app's handler once the SDK has stopped waiting (1.5 s).
                let deadline = Int((Date().timeIntervalSince1970 + 1.5) * 1000)
                return await KiroraFlutterPlugin.ask(
                    channel, "handleDeepLink", ["url": url.absoluteString, "deadline": deadline], otherwise: false)
            }
        } else {
            KiroraWrapper.setDeepLinkHandler(nil)
        }
        if args["hasForegroundHandler"] as? Bool == true {
            KiroraWrapper.setForegroundPresentationHandler { data in
                await KiroraFlutterPlugin.ask(channel, "foregroundNotification", KiroraFlutterPlugin.strings(data), otherwise: true)
            }
        } else {
            KiroraWrapper.setForegroundPresentationHandler(nil)
        }
    }

    // MARK: - Calls to Dart

    /// Dart's answer to one `fetchUserToken` request: a token, or the app's failure.
    private static func answerToken(_ tokens: KiroraWrapper.TokenRequests?, _ requestId: String, _ answer: Any?) {
        guard let tokens = tokens else { return }
        if let token = answer as? String, !token.isEmpty {
            tokens.answer(requestId, token: token)
        } else if let error = answer as? FlutterError {
            tokens.fail(requestId, message: error.message ?? error.code)
        } else {
            tokens.fail(requestId, message: "fetchUserToken gave no token")
        }
    }

    /// Asks Dart a yes/no question. A missing or odd answer is `otherwise`.
    private static func ask(_ channel: FlutterMethodChannel, _ method: String, _ arguments: Any, otherwise: Bool) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.main.async {
                let reply = AnswerOnce(continuation)
                channel.invokeMethod(method, arguments: arguments) { answer in
                    reply.resume(answer as? Bool ?? otherwise)
                }
                // The SDK stops waiting after 1.5 s. If the engine goes away and no reply ever comes,
                // the question still ends, rather than leaving its task suspended for good.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { reply.resume(otherwise) }
            }
        }
    }

    private func setTaps(on: Bool) {
        // An engine that no longer owns Kirora never takes the listener from the one that does.
        guard on != tapsOn, ownsCallbacks else { return }
        tapsOn = on
        guard on else {
            // Taps are held again until Dart listens.
            KiroraWrapper.setTapListener(nil)
            return
        }
        let channel = self.channel
        // Attaching delivers the held taps, the one that launched the app among them.
        KiroraWrapper.setTapListener { tap in
            var data = KiroraFlutterPlugin.strings(tap.data)
            data["kirora_action_identifier"] = tap.actionIdentifier
            if let index = tap.buttonIndex { data["kirora_button_index"] = String(index) }
            if let link = tap.link { data["kirora_link"] = link.absoluteString }
            DispatchQueue.main.async { channel.invokeMethod("notificationClicked", arguments: data) }
        }
    }

    // MARK: - Values

    /// The SDK's error as Dart's: KiroraApiError, UserTokenError, or KiroraError for a setup or
    /// network problem.
    private static func flutterError(_ error: Error) -> FlutterError {
        switch error {
        case let error as KiroraApiError:
            return FlutterError(code: "KIRORA_API_ERROR", message: error.message, details: [
                "status": error.status,
                "code": error.code.map { $0 as Any } ?? NSNull(),
                "retryAfterMs": error.retryAfterMs.map { $0 as Any } ?? NSNull(),
            ] as [String: Any])
        case let error as UserTokenError:
            return FlutterError(code: "USER_TOKEN_ERROR", message: error.description, details: nil)
        case let error as KiroraError:
            return FlutterError(code: "KIRORA_ERROR", message: error.message, details: nil)
        default:
            return FlutterError(code: "KIRORA_ERROR", message: "\(error)", details: nil)
        }
    }

    /// Dart sends properties as a JSON string.
    private static func properties(_ value: Any?) -> [String: Any] {
        guard let json = value as? String, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// A push's data as Dart's `NotificationData`: strings, with anything else as JSON text.
    private static func strings(_ data: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in data {
            if let string = value as? String {
                out[key] = string
            } else if value is NSNull {
                continue
            } else if JSONSerialization.isValidJSONObject(value),
                      let encoded = try? JSONSerialization.data(withJSONObject: value),
                      let text = String(data: encoded, encoding: .utf8) {
                out[key] = text
            } else {
                out[key] = "\(value)"
            }
        }
        return out
    }
}

/// Holds a client's token requests for the closure that sends them to Dart. Set once, before any
/// request can be made, then only read. Weak: the requests hold this box (through their closure),
/// and the plugin holds the requests, so a strong reference here would keep them alive for good.
private final class TokenRequestsBox: @unchecked Sendable {
    weak var requests: KiroraWrapper.TokenRequests?
}

/// Resumes a question to Dart exactly once, by its reply or its deadline. Used on the main thread only.
private final class AnswerOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ answer: Bool) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        continuation.resume(returning: answer)
    }
}
