@file:OptIn(KiroraInternalApi::class)

package io.kirora.flutter

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.util.Log
import com.kirora.androidsdk.Kirora
import com.kirora.androidsdk.KiroraInternalApi

/**
 * Push at launch: runs as the app process starts, before any activity and long before Dart sets
 * Kirora up, so the link of a tap that launched the app waits for the plugin's callbacks instead of
 * opening without asking. Holds no data.
 */
class KiroraLaunchProvider : ContentProvider() {
    override fun onCreate(): Boolean {
        // Runs before Application.onCreate on every process start: a failure here must never crash it.
        try {
            context?.let { Kirora.installPushIntegration(it) }
        } catch (e: Throwable) {
            Log.e("Kirora", "Push at launch could not be installed; push taps and tokens won't reach Kirora", e)
        }
        return true
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}
