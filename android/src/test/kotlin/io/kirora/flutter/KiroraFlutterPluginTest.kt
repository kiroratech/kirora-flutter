package io.kirora.flutter

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
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.ArgumentCaptor
import org.mockito.Mockito.any
import org.mockito.Mockito.anyString
import org.mockito.Mockito.eq
import org.mockito.Mockito.isNull
import org.mockito.Mockito.mock
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * The plugin's own behaviour on the channel: errors before set-up, replacement and engine teardown.
 * Run from the example, which supplies the Flutter embedding:
 * `cd example/android && ./gradlew :kirora_flutter:testDebugUnitTest`
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class KiroraFlutterPluginTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val bindings = mutableMapOf<KiroraFlutterPlugin, FlutterPlugin.FlutterPluginBinding>()

    private fun attach(): KiroraFlutterPlugin {
        val binding = mock(FlutterPlugin.FlutterPluginBinding::class.java)
        `when`(binding.applicationContext).thenReturn(context)
        `when`(binding.binaryMessenger).thenReturn(mock(BinaryMessenger::class.java))
        return KiroraFlutterPlugin().also {
            it.onAttachedToEngine(binding)
            bindings[it] = binding
        }
    }

    private fun configured() = attach().also { call(it, "configure", options()) }

    private fun detach(plugin: KiroraFlutterPlugin) = plugin.onDetachedFromEngine(bindings.remove(plugin)!!)

    @After
    fun tearDown() {
        bindings.keys.toList().forEach(::detach)
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

    private fun assertNotConfigured(result: MethodChannel.Result) =
        verify(result).error(eq("NOT_CONFIGURED"), anyString(), any())

    /** [plugin]'s getState answer, once it arrives. */
    private fun stateOf(plugin: KiroraFlutterPlugin): Map<*, *> {
        val result = call(plugin, "getState")
        val state = ArgumentCaptor.forClass(Any::class.java)
        eventually { verify(result).success(state.capture()) }
        return state.value as Map<*, *>
    }

    /**
     * Lets the plugin's main-thread work finish, then runs [check]. Kirora's own calls run on other
     * threads, and a cold JVM's first database open is slow.
     */
    private fun eventually(check: () -> Unit) {
        val deadline = System.currentTimeMillis() + 30_000
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
            assertNotConfigured(call(plugin, method, mapOf("token" to "t", "enabled" to true, "granted" to true)))
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
        val state = stateOf(configured())
        assertEquals(true, state["isInitialized"])
        assertEquals(0, state["queuedEventCount"])
    }

    @Test
    fun destroyEndsTheClientAndLaterCallsAnswerNotConfigured() {
        val plugin = configured()
        verify(call(plugin, "destroy")).success(null)
        assertNotConfigured(call(plugin, "flush"))
    }

    @Test
    fun aSecondConfigureReplacesTheClientAndStillAnswers() {
        val plugin = configured()
        call(plugin, "configure", options())
        assertEquals(true, stateOf(plugin)["isInitialized"])
    }

    @Test
    fun detachingTheEngineStopsItsClientAndTheChannelHandler() {
        val plugin = configured()
        val messenger = bindings.getValue(plugin).binaryMessenger
        detach(plugin)
        assertNotConfigured(call(plugin, "flush"))
        verify(messenger).setMessageHandler(eq("io.kirora.flutter/sdk"), isNull())
    }

    @Test
    fun anOlderEnginesTeardownLeavesTheNewerEnginesClientRunning() {
        val older = configured()
        val newer = configured()
        detach(older)
        assertEquals(true, stateOf(newer)["isInitialized"])
    }

    @Test
    fun aDestroyFromAnOlderEngineDoesNotStopTheNewerOnes() {
        val older = configured()
        val newer = configured()
        call(older, "destroy")
        assertEquals(true, stateOf(newer)["isInitialized"])
    }

    @Test
    fun activityChangesNeverThrow() {
        val plugin = attach()
        plugin.onDetachedFromActivityForConfigChanges()
        plugin.onDetachedFromActivity()
    }
}
