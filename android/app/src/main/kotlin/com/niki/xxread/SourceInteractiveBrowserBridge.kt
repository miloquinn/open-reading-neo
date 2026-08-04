package com.niki.xxread

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class SourceInteractiveBrowserBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    companion object {
        private const val CHANNEL = "com.niki.xxread/source_interactive_browser"
        private const val REQUEST_CODE = 59142
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private var pending: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "open") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            if (pending != null) {
                result.error("busy", "Another reading source verification is already open.", null)
                return@setMethodCallHandler
            }
            val url = call.argument<String>("url")
            if (url.isNullOrBlank()) {
                result.error("invalid_url", "Reading source verification URL is empty.", null)
                return@setMethodCallHandler
            }
            val headers = (call.argument<Map<*, *>>("headers") ?: emptyMap<Any, Any>())
                .entries
                .associate { "${it.key}" to "${it.value}" }
            pending = result
            val intent = Intent(activity, SourceInteractiveBrowserActivity::class.java).apply {
                putExtra(SourceInteractiveBrowserActivity.EXTRA_URL, url)
                putExtra(SourceInteractiveBrowserActivity.EXTRA_HTML, call.argument<String>("html"))
                putExtra(
                    SourceInteractiveBrowserActivity.EXTRA_HEADERS,
                    HashMap(headers),
                )
            }
            activity.startActivityForResult(intent, REQUEST_CODE)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pending ?: return true
        pending = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.error("cancelled", "Reading source verification was cancelled.", null)
            return true
        }
        result.success(
            mapOf(
                "body" to (data.getStringExtra(SourceInteractiveBrowserActivity.RESULT_BODY) ?: ""),
                "finalUrl" to (data.getStringExtra(SourceInteractiveBrowserActivity.RESULT_URL) ?: ""),
                "cookieHeader" to data.getStringExtra(SourceInteractiveBrowserActivity.RESULT_COOKIE),
            ),
        )
        return true
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        pending?.error("disposed", "Reading source verification closed.", null)
        pending = null
    }
}
