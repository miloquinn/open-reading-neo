package com.niki.xxread

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File

class SourceBrowserSessionBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    companion object {
        private const val CHANNEL = "com.niki.xxread/source_browser_session"
        private const val OPEN_REQUEST_CODE = 59143
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val replyMessenger = Messenger(ReplyHandler())
    private val pendingLoads = linkedMapOf<String, PendingLoad>()
    private val outbound = ArrayDeque<Message>()
    private var service: Messenger? = null
    private var bound = false
    private var pendingOpen: PendingOpen? = null
    private var pendingClear: MethodChannel.Result? = null

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            service = binder?.let(::Messenger)
            while (outbound.isNotEmpty()) service?.send(outbound.removeFirst())
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
            pendingClear?.error("service_disconnected", "Source browser service disconnected.", null)
            pendingClear = null
            pendingLoads.forEach { (_, pending) ->
                pending.requestFile.delete()
                pending.result.error("service_disconnected", "Source browser service disconnected.", null)
            }
            pendingLoads.clear()
            outbound.clear()
        }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> open(call.arguments as? Map<*, *>, result)
                "load" -> load(call.arguments as? Map<*, *>, result)
                "clear" -> clear(call.argument<String>("sourceId"), result)
                "cancel" -> cancel(call.argument<String>("requestId"), result)
                else -> result.notImplemented()
            }
        }
        bound = activity.bindService(
            Intent(activity, SourceBrowserSessionService::class.java),
            connection,
            Context.BIND_AUTO_CREATE,
        )
    }

    private fun open(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (pendingOpen != null) {
            result.error("busy", "Another source browser login is already open.", null)
            return
        }
        val sourceId = arguments?.get("sourceId")?.toString().orEmpty()
        val url = arguments?.get("url")?.toString().orEmpty()
        if (sourceId.isBlank() || !isSafeSourceBrowserUrl(url)) {
            result.error("invalid_request", "sourceId and URL are required.", null)
            return
        }
        val requestDir = File(activity.cacheDir, "source_browser_session").apply { mkdirs() }
        val requestFile = File(requestDir, "open-request-${System.nanoTime()}.json")
        try {
            requestFile.writeText(JSONObject(arguments ?: emptyMap<Any, Any>()).toString())
        } catch (error: Exception) {
            requestFile.delete()
            result.error("request_failed", error.message ?: "Browser login request could not be prepared.", null)
            return
        }
        pendingOpen = PendingOpen(result, requestFile)
        val intent = Intent(activity, SourceBrowserSessionActivity::class.java).apply {
            putExtra(SourceBrowserSessionActivity.EXTRA_REQUEST_FILE, requestFile.absolutePath)
        }
        try {
            activity.startActivityForResult(intent, OPEN_REQUEST_CODE)
        } catch (error: Exception) {
            pendingOpen = null
            requestFile.delete()
            result.error("unavailable", error.message ?: "Source browser login could not be opened.", null)
        }
    }

    private fun load(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val args = arguments ?: emptyMap<Any, Any>()
        val sourceId = args["sourceId"]?.toString().orEmpty()
        val requestId = args["requestId"]?.toString().orEmpty()
        val url = args["url"]?.toString().orEmpty()
        if (sourceId.isBlank() || requestId.isBlank() || !isSafeSourceBrowserUrl(url)) {
            result.error("invalid_request", "sourceId, requestId, and URL are required.", null)
            return
        }
        if (pendingLoads.containsKey(requestId)) {
            result.error("duplicate_request", "Browser session request ID is already active.", null)
            return
        }
        val requestDir = File(activity.cacheDir, "source_browser_session").apply { mkdirs() }
        val requestFile = File(requestDir, "request-${System.nanoTime()}.json")
        try {
            val normalized = linkedMapOf<String, Any?>(
                "sourceId" to sourceId,
                "requestId" to requestId,
                "url" to url,
                "headers" to (args["headers"] ?: emptyMap<String, String>()),
                "session" to (args["session"] ?: emptyMap<String, Any?>()),
                "method" to (args["method"]?.toString() ?: "GET"),
                "body" to (args["body"]?.toString() ?: ""),
                "webJs" to args["webJs"]?.toString(),
                "html" to args["html"]?.toString(),
                "timeoutMs" to ((args["timeoutMs"] as? Number)?.toLong() ?: 15_000L),
            )
            requestFile.writeText(JSONObject(normalized).toString())
        } catch (error: Exception) {
            requestFile.delete()
            result.error("request_failed", error.message ?: "Browser request could not be prepared.", null)
            return
        }
        pendingLoads[requestId] = PendingLoad(result, requestFile)
        send(
            Message.obtain(null, SourceBrowserSessionService.MSG_LOAD).apply {
                replyTo = replyMessenger
                data = Bundle().apply {
                    putString(SourceBrowserSessionService.KEY_REQUEST_ID, requestId)
                    putString(SourceBrowserSessionService.KEY_REQUEST_FILE, requestFile.absolutePath)
                }
            },
        )
    }

    private fun clear(sourceId: String?, result: MethodChannel.Result) {
        if (sourceId.isNullOrBlank()) {
            result.error("invalid_request", "sourceId is required.", null)
            return
        }
        if (pendingClear != null) {
            result.error("busy", "A browser session clear is already active.", null)
            return
        }
        pendingClear = result
        send(
            Message.obtain(null, SourceBrowserSessionService.MSG_CLEAR).apply {
                replyTo = replyMessenger
                data = Bundle().apply { putString(SourceBrowserSessionService.KEY_SOURCE_ID, sourceId) }
            },
        )
    }

    private fun cancel(requestId: String?, result: MethodChannel.Result) {
        if (requestId.isNullOrBlank() || !pendingLoads.containsKey(requestId)) {
            result.success(false)
            return
        }
        send(
            Message.obtain(null, SourceBrowserSessionService.MSG_CANCEL).apply {
                replyTo = replyMessenger
                data = Bundle().apply { putString(SourceBrowserSessionService.KEY_REQUEST_ID, requestId) }
            },
        )
        result.success(true)
    }

    private fun send(message: Message) {
        val target = service
        if (target == null) outbound.addLast(message) else target.send(message)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != OPEN_REQUEST_CODE) return false
        val pending = pendingOpen ?: return true
        pendingOpen = null
        pending.requestFile.delete()
        if (resultCode != Activity.RESULT_OK || data == null) {
            pending.result.error(
                data?.getStringExtra("errorCode") ?: "cancelled",
                data?.getStringExtra("errorMessage") ?: "Source browser login was cancelled.",
                null,
            )
            return true
        }
        returnResultFile(data.getStringExtra(SourceBrowserSessionActivity.RESULT_FILE), pending.result)
        return true
    }

    private inner class ReplyHandler : Handler(Looper.getMainLooper()) {
        override fun handleMessage(message: Message) {
            val requestId = message.data.getString(SourceBrowserSessionService.KEY_REQUEST_ID)
            if (requestId == null && pendingClear != null) {
                val clearResult = pendingClear
                pendingClear = null
                if (message.what == SourceBrowserSessionService.MSG_SUCCESS) clearResult?.success(null)
                else clearResult?.error(
                    message.data.getString(SourceBrowserSessionService.KEY_ERROR_CODE) ?: "clear_failed",
                    message.data.getString(SourceBrowserSessionService.KEY_ERROR_MESSAGE),
                    null,
                )
                return
            }
            val pending = requestId?.let(pendingLoads::remove) ?: return
            pending.requestFile.delete()
            if (message.what == SourceBrowserSessionService.MSG_SUCCESS) {
                returnResultFile(message.data.getString(SourceBrowserSessionService.KEY_RESULT_FILE), pending.result)
            } else {
                pending.result.error(
                    message.data.getString(SourceBrowserSessionService.KEY_ERROR_CODE) ?: "load_failed",
                    message.data.getString(SourceBrowserSessionService.KEY_ERROR_MESSAGE),
                    null,
                )
            }
        }
    }

    private fun returnResultFile(path: String?, result: MethodChannel.Result) {
        val file = path?.let(::File)
        if (file == null || !file.isFile) {
            result.error("result_failed", "Browser session result is missing.", null)
            return
        }
        try {
            result.success(jsonToPlatform(JSONObject(file.readText())))
        } catch (error: Exception) {
            result.error("result_failed", error.message ?: "Browser session result is invalid.", null)
        } finally {
            file.delete()
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        pendingOpen?.requestFile?.delete()
        pendingOpen?.result?.error("disposed", "Source browser session closed.", null)
        pendingOpen = null
        pendingClear?.error("disposed", "Source browser session closed.", null)
        pendingClear = null
        pendingLoads.forEach { (_, pending) ->
            pending.requestFile.delete()
            pending.result.error("disposed", "Source browser session closed.", null)
        }
        pendingLoads.clear()
        outbound.clear()
        if (bound) activity.unbindService(connection)
        bound = false
        service = null
    }

    private data class PendingLoad(val result: MethodChannel.Result, val requestFile: File)
    private data class PendingOpen(val result: MethodChannel.Result, val requestFile: File)
}
