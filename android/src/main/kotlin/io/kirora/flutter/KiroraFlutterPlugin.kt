@file:OptIn(KiroraInternalApi::class)

package io.kirora.flutter

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import com.kirora.androidsdk.Kirora
import com.kirora.androidsdk.KiroraInternalApi
import com.kirora.androidsdk.model.AuthFailureReason
import com.kirora.androidsdk.model.KiroraOptions
import com.kirora.androidsdk.model.KiroraPushOptions
import com.kirora.androidsdk.model.LogLevel
import com.kirora.androidsdk.model.KiroraApiError
import com.kirora.androidsdk.model.UserTokenError
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONArray
import org.json.JSONObject
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Hands the Dart `Kirora` class to the native Kirora Android SDK, which does the work. The SDK's
 * questions (user tokens, deep links, foreground display) are asked of Dart over the same channel,
 * through the SDK's wrapper hooks; push at launch is installed by [KiroraLaunchProvider].
 */
class KiroraFlutterPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {

    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context
    private var activity: Activity? = null
    private var kirora: Kirora? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var clicksOn = false
    private var receivedOn = false

    /** This engine set Kirora up, and has a client to end when it goes. */
    private var configured = false

    /** This engine set Kirora up last, so the process-wide wrapper callbacks are its own. */
    private val ownsCallbacks get() = owner === this
    private val clickListener: (Map<String, String>) -> Unit = { data -> invokeDart("notificationClicked", data) }
    private val receivedListener: (Map<String, String>) -> Unit = { data -> invokeDart("notificationReceived", data) }

    // Results and channel calls must happen on the main thread; the SDK's own calls are main-safe.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        // The engine is gone (back on the root activity) but the process may live on: its client must
        // not keep running beside the one the next engine sets up. Only the engine that set Kirora up
        // last clears the process-wide callbacks; an older or background engine never touches them.
        if (configured) {
            endClient()
            configured = false
        }
        if (ownsCallbacks) {
            // Not setWrapperCallbacks(null, null), which means "set up, with no handler": the next
            // tap's link must wait for the next engine's callbacks (10 s at most), not open at once.
            Kirora.wrapperDetached()
            owner = null
        }
        scope.cancel()
    }

    /** Destroys this engine's client and forgets which listeners Dart had, for the next client. */
    private fun endClient() {
        kirora?.let { client ->
            if (clicksOn) client.removeNotificationClickListener(clickListener)
            if (receivedOn) client.removeForegroundNotificationListener(receivedListener)
            client.destroy()
        }
        kirora = null
        clicksOn = false
        receivedOn = false
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            handle(call, result)
        } catch (e: Throwable) {
            // A synchronous call the SDK failed (an older SDK without the method, say): answer, never crash.
            answerQuietly { result.error("KIRORA_ERROR", e.message ?: e.javaClass.simpleName, null) }
        }
    }

    private fun handle(call: MethodCall, result: Result) {
        when (call.method) {
            "configure" -> configure(call, result)
            "identify" -> surfacing(result) { kirora ->
                kirora.identify(call.argument<String>("token")?.takeIf { it.isNotEmpty() })
            }
            "logout" -> withKirora(result) { kirora ->
                kirora.logout()
                result.success(null)
            }
            "track" -> fireAndForget(result) { kirora ->
                val properties = try {
                    call.argument<String>("properties")?.let { JSONObject(it).toMap() }
                } catch (_: Exception) {
                    null
                }
                kirora.track(call.argument<String>("name") ?: "", properties)
            }
            "trackScreenView" -> fireAndForget(result) { it.trackScreenView(call.argument<String>("name") ?: "") }
            "setTrackingConsent" -> fireAndForget(result) { it.setTrackingConsent(call.argument<Boolean>("granted") == true) }
            "setPushConsent" -> surfacing(result) { kirora ->
                kirora.setPushConsent(call.argument<Boolean>("granted") == true)
            }
            "setNotificationEvents" -> fireAndForget(result) { kirora ->
                val clicked = call.argument<Boolean>("clicked") == true
                val received = call.argument<Boolean>("received") == true
                if (clicked != clicksOn) {
                    clicksOn = clicked
                    // Attaching delivers a tap that launched the app before Dart was listening.
                    if (clicked) kirora.addNotificationClickListener(clickListener) else kirora.removeNotificationClickListener(clickListener)
                }
                if (received != receivedOn) {
                    receivedOn = received
                    if (received) kirora.addForegroundNotificationListener(receivedListener) else kirora.removeForegroundNotificationListener(receivedListener)
                }
            }
            "onNewPushToken" -> fireAndForget(result) { it.onNewPushToken(call.argument<String>("token") ?: "") }
            "requestPushPermission" -> withKirora(result) { kirora ->
                val caller: Context = activity ?: appContext
                result.success(kirora.requestPushPermission(caller).wireValue)
            }
            "getPushStatus" -> withKirora(result) { kirora ->
                result.success(kirora.getPushStatus().wireValue)
            }
            "setPushEnabled" -> withKirora(result) { kirora ->
                kirora.setPushEnabled(call.argument<Boolean>("enabled") == true)
                result.success(null)
            }
            "destroy" -> {
                endClient()
                // The app stopped Kirora on purpose: set up, with no handler, so a tapped push's link
                // opens natively at once rather than waiting for a client that may never come. Not
                // when a newer engine has set Kirora up since: the callbacks are its own.
                if (ownsCallbacks) Kirora.setWrapperCallbacks(null, null)
                result.success(null)
            }
            "flush" -> withKirora(result) { kirora ->
                kirora.flush()
                result.success(null)
            }
            "getState" -> withKirora(result) { kirora ->
                val state = kirora.getState()
                result.success(
                    mapOf(
                        "isInitialized" to state.isInitialized,
                        "isIdentified" to state.isIdentified,
                        "deviceId" to state.deviceId,
                        "sessionId" to state.sessionId,
                        "pushToken" to state.pushToken,
                        "trackingConsent" to state.trackingConsent,
                        "pushConsent" to state.pushConsent,
                        "queuedEventCount" to state.queuedEventCount
                    )
                )
            }
            else -> result.notImplemented()
        }
    }

    private fun configure(call: MethodCall, result: Result) {
        try {
            val provider: (suspend () -> String?)? =
                if (call.argument<Boolean>("hasTokenProvider") == true) ({ requestToken() }) else null
            val push = if (call.argument<Boolean>("push") == true) pushOptions(call) else null
            // A second configure (hot restart) replaces the client, and Dart's listeners start over.
            endClient()
            configured = true
            owner = this
            // Before the client exists: Kirora-SDK names this wrapper.
            Kirora.setWrapperSdk("kirora-flutter", call.argument<String>("sdkVersion") ?: "0.1.0")
            // Always called, with handlers or none: a launch tap's link waits for this call.
            Kirora.setForegroundNotificationHandler(null)
            val deepLink: (suspend (String) -> Boolean)? =
                if (call.argument<Boolean>("hasDeepLinkHandler") == true) {
                    { url: String ->
                        // Dart skips the app's handler once the SDK has stopped waiting (1.5 s).
                        val deadline = System.currentTimeMillis() + DEEP_LINK_WAIT_MS
                        askDart("handleDeepLink", mapOf("url" to url, "deadline" to deadline), otherwise = false)
                    }
                } else {
                    null
                }
            val foreground: (suspend (Map<String, String>) -> Boolean)? =
                if (call.argument<Boolean>("hasForegroundHandler") == true) {
                    { data: Map<String, String> -> askDart("foregroundNotification", data, otherwise = true) }
                } else {
                    null
                }
            Kirora.setWrapperCallbacks(handleDeepLink = deepLink, onForegroundNotification = foreground)
            // A token that fails outside a call (a background refresh): Dart hears the spec's reason,
            // tagged with this setup's generation so a newer Dart instance ignores it.
            val generation = call.argument<Number>("generation")?.toLong()
            val authFailed: ((AuthFailureReason) -> Unit)? =
                if (call.argument<Boolean>("hasAuthenticationFailedHandler") == true) {
                    { reason: AuthFailureReason ->
                        val wire = when (reason) {
                            AuthFailureReason.FETCH_FAILED -> "fetch_failed"
                            AuthFailureReason.REFUSED -> "refused"
                        }
                        invokeDart("authenticationFailed", mapOf("reason" to wire, "generation" to generation))
                    }
                } else {
                    null
                }
            kirora = Kirora(
                appContext,
                KiroraOptions(
                    clientKey = call.argument<String>("clientKey") ?: "",
                    fetchUserToken = provider,
                    onAuthenticationFailed = authFailed,
                    push = push,
                    requireTrackingConsent = call.argument<Boolean>("requireTrackingConsent") == true,
                    trackSessions = call.argument<Boolean>("trackSessions") != false,
                    trackAppLifecycle = call.argument<Boolean>("trackAppLifecycle") == true,
                    logLevel = when (call.argument<String>("logLevel")) {
                        "none" -> LogLevel.NONE
                        "debug" -> LogLevel.DEBUG
                        else -> LogLevel.ERROR
                    },
                    apiUrl = call.argument<String>("apiUrl") ?: "https://api.kirora.io"
                )
            )
            // Whether tracking is allowed now, so Dart's beforeSend never sees an event it isn't.
            result.success(mapOf("trackingConsent" to kirora?.trackingConsent))
        } catch (e: Throwable) {
            // Rare: the SDK's constructor catches its own setup failures. The callbacks installed above
            // stay: the SDK asks them without a client, and Dart is alive to answer. This engine still
            // owns them, so its teardown detaches them.
            result.error("CONFIGURE_ERROR", e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun pushOptions(call: MethodCall): KiroraPushOptions {
        val icon = call.argument<String>("smallIcon")?.let { name ->
            appContext.resources.getIdentifier(name, "drawable", appContext.packageName).takeIf { it != 0 }
                ?: appContext.resources.getIdentifier(name, "mipmap", appContext.packageName).takeIf { it != 0 }
        }
        val color = call.argument<String>("accentColor")?.let {
            try {
                Color.parseColor(it)
            } catch (_: IllegalArgumentException) {
                null
            }
        }
        return KiroraPushOptions(
            pushAppId = call.argument<String>("pushAppId"),
            smallIconResId = icon,
            accentColor = color,
            defaultChannelId = call.argument<String>("defaultChannelId") ?: "kirora_default",
            defaultChannelName = call.argument<String>("defaultChannelName") ?: "Notifications"
        )
    }

    /**
     * Asks Dart a yes/no question (a deep link, a push in the foreground). The SDK waits 1.5 seconds
     * at most, then acts as if there were no callback; a missing or odd answer is [otherwise].
     */
    private suspend fun askDart(method: String, arguments: Any, otherwise: Boolean): Boolean =
        suspendCancellableCoroutine { continuation ->
            mainHandler.post {
                try {
                    channel.invokeMethod(method, arguments, object : Result {
                        override fun success(result: Any?) = continuation.resume(result as? Boolean ?: otherwise)
                        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) =
                            continuation.resume(otherwise)

                        override fun notImplemented() = continuation.resume(otherwise)
                    })
                } catch (_: Exception) {
                    continuation.resume(otherwise)
                }
            }
        }

    /** Tells Dart about a tap or a push (events can come from any thread). */
    private fun invokeDart(method: String, data: Map<String, Any?>) {
        mainHandler.post {
            try {
                channel.invokeMethod(method, data)
            } catch (_: Exception) {
            }
        }
    }

    /**
     * Asks Dart for a user token (the app's `fetchUserToken`). The SDK's 30-second limit covers the
     * round trip and discards a late answer. Channel calls must be made on the main thread.
     */
    private suspend fun requestToken(): String? = suspendCancellableCoroutine { continuation ->
        mainHandler.post {
            try {
                channel.invokeMethod("fetchUserToken", null, object : Result {
                    override fun success(result: Any?) = continuation.resume(result as? String)
                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) =
                        continuation.resumeWithException(IllegalStateException(errorMessage ?: errorCode))

                    override fun notImplemented() = continuation.resume(null)
                })
            } catch (e: Exception) {
                continuation.resumeWithException(e)
            }
        }
    }

    private fun withKirora(result: Result, block: suspend (Kirora) -> Unit) {
        val kirora = kirora
        if (kirora == null) {
            result.error("NOT_CONFIGURED", "Kirora was not set up", null)
            return
        }
        scope.launch {
            try {
                block(kirora)
            } catch (e: CancellationException) {
                // The engine is going away: answer anyway, so no Dart call is left waiting.
                answerQuietly { result.error("CANCELLED", "Kirora's call was cancelled", null) }
                throw e
            } catch (e: Throwable) {
                // Throwable, not Exception: an older SDK without a method throws NoSuchMethodError,
                // which must answer Dart rather than crash the app.
                answerQuietly { result.error("KIRORA_ERROR", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    private inline fun answerQuietly(answer: () -> Unit) {
        try {
            answer()
        } catch (_: Throwable) {
        }
    }

    /**
     * A call whose failure the app hears: answers null once [block] returns, or the SDK's error as
     * Dart's UserTokenError, KiroraApiError or KiroraError (setup and network problems).
     */
    private fun surfacing(result: Result, block: suspend (Kirora) -> Unit) = withKirora(result) { kirora ->
        try {
            block(kirora)
            result.success(null)
        } catch (e: CancellationException) {
            throw e
        } catch (e: UserTokenError) {
            result.error("USER_TOKEN_ERROR", e.message, null)
        } catch (e: KiroraApiError) {
            result.error(
                "KIRORA_API_ERROR",
                e.message,
                mapOf("status" to e.status, "code" to e.code, "retryAfterMs" to e.retryAfterMs)
            )
        } catch (e: Throwable) {
            result.error("KIRORA_ERROR", e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun fireAndForget(result: Result, block: (Kirora) -> Unit) {
        try {
            kirora?.let(block)
        } catch (_: Throwable) {
        }
        result.success(null)
    }

    private fun JSONObject.toMap(): Map<String, Any?> = keys().asSequence().associateWith { unwrap(get(it)) }

    private fun unwrap(value: Any?): Any? = when {
        value == null || value == JSONObject.NULL -> null
        value is JSONObject -> value.toMap()
        value is JSONArray -> (0 until value.length()).map { unwrap(value.get(it)) }
        else -> value
    }

    private companion object {
        const val CHANNEL = "io.kirora.flutter/sdk"
        const val DEEP_LINK_WAIT_MS = 1_500L

        /** The engine that set Kirora up last: only it may clear the process-wide callbacks. */
        @Volatile
        var owner: KiroraFlutterPlugin? = null
    }
}
