package io.kirora.flutter

// UNVERIFIED: these tests were written without being compiled or run. The build environment that
// wrote them had no Flutter SDK, which supplies the Flutter embedding this module compiles against.
// Run them from a Flutter build (`cd example && flutter build apk`, then the module's unit tests)
// before relying on them, and fix any API drift the first run shows.

import android.content.Context
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.ArgumentCaptor
import org.mockito.Mockito.any
import org.mockito.Mockito.anyString
import org.mockito.Mockito.eq
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** The plugin's own behaviour on the channel: errors before set-up, replacement and engine teardown. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class KiroraFlutterPluginTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val plugins = mutableListOf<Pair<KiroraFlutterPlugin, FlutterPlugin.FlutterPluginBinding>>()

    private fun attach(): KiroraFlutterPlugin {
        val binding = mock(FlutterPlugin.FlutterPluginBinding::class.java)
        `when`(binding.applicationContext).thenReturn(context)
        `when`(binding.binaryMessenger).thenReturn(mock(BinaryMessenger::class.java))
        return KiroraFlutterPlugin().also {
            it.onAttachedToEngine(binding)
            plugins += it to binding
        }
    }

    @Before
    fun setUp() {
        plugins.clear()
    }

    @After
    fun tearDown() {
        plugins.forEach { (plugin, binding) -> plugin.onDetachedFromEngine(binding) }
    }

    private fun options() = mapOf(
        "clientKey" to "kirora_pk_test",
        "hasTokenProvider" to false,
        "push" to false,
        "requireTrackingConsent" to false,
        "trackSessions" to false,
        "trackAppLifecycle" to false,
        "logLevel" to "none"
    )

    private fun call(plugin: KiroraFlutterPlugin, method: String, args: Map<String, Any?>? = null): MethodChannel.Result {
        val result = mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(MethodCall(method, args), result)
        return result
    }

    /** Lets the plugin's main-thread work finish, then runs [check] (Kirora's own calls run on other threads). */
    private fun eventually(check: () -> Unit) {
        val deadline = System.currentTimeMillis() + 10_000
        while (true) {
            shadowOf(Looper.getMainLooper()).idle()
            try {
                return check()
            } catch (e: Throwable) {
                if (System.currentTimeMillis() > deadline) throw e
                Thread.sleep(25)
            }
        }
    }

    @Test
    fun anUnknownMethodIsNotImplemented() {
        val plugin = attach()
        verify(call(plugin, "noSuchMethod")).notImplemented()
    }

    @Test
    fun callsThatNeedAClientAnswerNotConfiguredBeforeSetUp() {
        val plugin = attach()
        for (method in listOf("identify", "logout", "flush", "getState", "getPushStatus", "setPushEnabled", "setPushConsent", "requestPushPermission")) {
            verify(call(plugin, method, mapOf("token" to "t", "enabled" to true, "granted" to true)))
                .error(eq("NOT_CONFIGURED"), anyString(), any())
        }
    }

    @Test
    fun fireAndForgetCallsWithNoClientStillAnswerNull() {
        val plugin = attach()
        for (method in listOf("track", "trackScreenView", "setTrackingConsent", "setNotificationEvents", "onNewPushToken")) {
            verify(call(plugin, method, mapOf("name" to "x", "properties" to "{}", "granted" to true, "token" to "t"))).success(null)
        }
    }

    @Test
    fun configureAnswersWithWhetherTrackingIsAllowed() {
        val plugin = attach()
        val result = call(plugin, "configure", options())
        val answer = ArgumentCaptor.forClass(Any::class.java)
        verify(result).success(answer.capture())
        assertTrue((answer.value as Map<*, *>).containsKey("trackingConsent"))
    }

    @Test
    fun getStateAfterConfigureAnswersTheSdksSnapshot() {
        val plugin = attach()
        call(plugin, "configure", options())
        val result = call(plugin, "getState")
        eventually {
            val state = ArgumentCaptor.forClass(Any::class.java)
            verify(result).success(state.capture())
            val map = state.value as Map<*, *>
            assertEquals(true, map["isInitialized"])
            assertEquals(0, map["queuedEventCount"])
        }
    }

    @Test
    fun destroyEndsTheClientAndLaterCallsAnswerNotConfigured() {
        val plugin = attach()
        call(plugin, "configure", options())
        verify(call(plugin, "destroy")).success(null)
        verify(call(plugin, "flush")).error(eq("NOT_CONFIGURED"), anyString(), any())
    }

    @Test
    fun aSecondConfigureReplacesTheClientAndStillAnswers() {
        val plugin = attach()
        call(plugin, "configure", options())
        call(plugin, "configure", options())
        val result = call(plugin, "getState")
        eventually { verify(result).success(any()) }
    }

    @Test
    fun detachingTheEngineStopsItsClientAndTheChannelHandler() {
        val plugin = attach()
        call(plugin, "configure", options())
        val (_, binding) = plugins.single()
        plugin.onDetachedFromEngine(binding)
        verify(call(plugin, "flush")).error(eq("NOT_CONFIGURED"), anyString(), any())
    }

    @Test
    fun anOlderEnginesTeardownLeavesTheNewerEnginesClientRunning() {
        val older = attach()
        call(older, "configure", options())
        val newer = attach()
        call(newer, "configure", options())

        val (_, olderBinding) = plugins.first()
        older.onDetachedFromEngine(olderBinding)

        val result = call(newer, "getState")
        eventually {
            val state = ArgumentCaptor.forClass(Any::class.java)
            verify(result).success(state.capture())
            assertEquals(true, (state.value as Map<*, *>)["isInitialized"])
        }
    }

    @Test
    fun aDestroyFromAnOlderEngineDoesNotStopTheNewerOnes() {
        val older = attach()
        call(older, "configure", options())
        val newer = attach()
        call(newer, "configure", options())

        call(older, "destroy")

        val result = call(newer, "getState")
        eventually { verify(result).success(any()) }
        verify(result, never()).error(anyString(), anyString(), any())
    }

    @Test
    fun activityChangesNeverThrow() {
        val plugin = attach()
        plugin.onDetachedFromActivityForConfigChanges()
        plugin.onDetachedFromActivity()
    }
}
