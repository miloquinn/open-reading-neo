package com.niki.xxread

import android.annotation.SuppressLint
import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONObject
import org.json.JSONTokener
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

class SourceBrowserSessionService : Service() {
    companion object {
        const val MSG_LOAD = 1
        const val MSG_CANCEL = 2
        const val MSG_CLEAR = 3
        const val MSG_SUCCESS = 10
        const val MSG_ERROR = 11
        const val KEY_REQUEST_FILE = "requestFile"
        const val KEY_REQUEST_ID = "requestId"
        const val KEY_SOURCE_ID = "sourceId"
        const val KEY_RESULT_FILE = "resultFile"
        const val KEY_ERROR_CODE = "errorCode"
        const val KEY_ERROR_MESSAGE = "errorMessage"
    }

    private val handler = Handler(Looper.getMainLooper())
    private val messenger = Messenger(IncomingHandler())
    private var active: BackgroundLoad? = null
    private val queuedLoads = ArrayDeque<QueuedLoad>()

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    private inner class IncomingHandler : Handler(Looper.getMainLooper()) {
        override fun handleMessage(message: Message) {
            when (message.what) {
                MSG_LOAD -> handleLoad(message)
                MSG_CANCEL -> handleCancel(message)
                MSG_CLEAR -> handleClear(message)
                else -> super.handleMessage(message)
            }
        }
    }

    private fun handleLoad(message: Message) {
        val reply = message.replyTo ?: return
        if (!SourceBrowserSessionRuntime.supportsIsolatedDataDirectory) {
            replyError(
                reply,
                message.data.getString(KEY_REQUEST_ID),
                "unsupported",
                "Isolated source browser sessions require Android 9 or newer.",
            )
            return
        }
        val requestFile = message.data.getString(KEY_REQUEST_FILE)?.let(::File)
        if (requestFile == null || !requestFile.isFile) {
            replyError(reply, message.data.getString(KEY_REQUEST_ID), "invalid_request", "Browser session request payload is missing.")
            return
        }
        val payload = try {
            JSONObject(requestFile.readText())
        } catch (error: Exception) {
            requestFile.delete()
            replyError(reply, message.data.getString(KEY_REQUEST_ID), "invalid_request", error.message ?: "Browser session request is invalid.")
            return
        } finally {
            requestFile.delete()
        }
        val requestId = payload.optString("requestId")
        val sourceId = payload.optString("sourceId")
        val url = payload.optString("url")
        if (requestId.isBlank() || sourceId.isBlank() || !isSafeSourceBrowserUrl(url)) {
            replyError(reply, requestId, "invalid_request", "sourceId, requestId, and URL are required.")
            return
        }
        if (active != null) {
            if (queuedLoads.size >= 32) {
                replyError(reply, requestId, "busy", "Too many source browser requests are queued.")
            } else {
                queuedLoads.addLast(QueuedLoad(payload, reply))
            }
            return
        }
        if (!SourceBrowserSessionRuntime.acquire("load:$requestId", sourceId) { active?.cancel() }) {
            replyError(reply, requestId, "busy", "Another source browser session is active.")
            return
        }
        startLoad(payload, reply)
    }

    private fun handleCancel(message: Message) {
        val requestId = message.data.getString(KEY_REQUEST_ID)
        if (active?.requestId == requestId) {
            active?.cancel()
            return
        }
        val queued = queuedLoads.firstOrNull { it.payload.optString("requestId") == requestId } ?: return
        queuedLoads.remove(queued)
        replyError(queued.reply, requestId, "cancelled", "Background browser request was cancelled.")
    }

    private fun handleClear(message: Message) {
        val reply = message.replyTo ?: return
        val sourceId = message.data.getString(KEY_SOURCE_ID)
        if (sourceId.isNullOrBlank()) {
            replyError(reply, null, "invalid_request", "sourceId is required.")
            return
        }
        if (!SourceBrowserSessionRuntime.supportsIsolatedDataDirectory) {
            val response = Message.obtain(null, MSG_SUCCESS)
            try { reply.send(response) } catch (_: Exception) {}
            return
        }
        val matchingQueued = queuedLoads.filter { it.payload.optString("sourceId") == sourceId }
        matchingQueued.forEach { queued ->
            queuedLoads.remove(queued)
            replyError(queued.reply, queued.payload.optString("requestId"), "cancelled", "Background browser request was cancelled.")
        }
        val activeSource = SourceBrowserSessionRuntime.activeSourceId()
        if (activeSource != null && activeSource != sourceId) {
            replySuccess(reply)
            return
        }
        SourceBrowserSessionRuntime.cancelSource(sourceId)
        SourceBrowserSessionRuntime.whenIdle {
            if (!SourceBrowserSessionRuntime.acquire("clear:$sourceId", sourceId)) {
                replySuccess(reply)
                return@whenIdle
            }
            SourceBrowserSessionRuntime.clearStorage {
                SourceBrowserSessionRuntime.release("clear:$sourceId")
                replySuccess(reply)
                startNextLoad()
            }
        }
    }

    private fun startLoad(payload: JSONObject, reply: Messenger) {
        active = BackgroundLoad(payload, reply).also { it.start() }
    }

    private fun startNextLoad() {
        val next = queuedLoads.removeFirstOrNull() ?: return
        val requestId = next.payload.optString("requestId")
        if (!SourceBrowserSessionRuntime.acquire("load:$requestId", next.payload.optString("sourceId")) { active?.cancel() }) {
            queuedLoads.addFirst(next)
            return
        }
        startLoad(next.payload, next.reply)
    }

    @SuppressLint("SetJavaScriptEnabled")
    private inner class BackgroundLoad(
        private val payload: JSONObject,
        private val reply: Messenger,
    ) {
        val requestId: String = payload.optString("requestId")
        val sourceId: String = payload.optString("sourceId")
        private val owner = "load:$requestId"
        private val url = payload.optString("url")
        private val method = payload.optString("method", "GET").uppercase()
        private val body = payload.optString("body", "")
        private val webJs = payload.optString("webJs").takeIf { it.isNotBlank() }
        private val html = payload.optString("html").takeIf { it.isNotEmpty() }
        private val headers = headersFromJson(payload.optJSONObject("headers")?.toString())
        private val timeoutMs = payload.optLong("timeoutMs", 15_000L).coerceIn(2_000L, 60_000L)
        private val tracker = SourceBrowserSessionTracker(
            SourceBrowserSession.fromJson(payload.optJSONObject("session")?.toString()),
        )
        private val completed = AtomicBoolean(false)
        private val webView = WebView(this@SourceBrowserSessionService)
        private val storageBridgeName = "xxreadSourceStorage"
        private var hydrating = false
        private var hydrationIndex = 0
        private val hydration = tracker.hydrationOrigins()
        private var navigationGeneration = 0
        private var collectingStorage = false
        private var collectionIndex = 0
        private var collectionOrigins = emptyList<String>()
        private var capturedBody = ""
        private var capturedFinalUrl = ""
        private var pendingFinish: Runnable? = null
        private val timeout = Runnable { fail("timeout", "Background browser timed out while loading this source.") }

        fun start() {
            configureSourceBrowserWebView(webView, headers)
            webView.addJavascriptInterface(
                SourceStorageJavascriptBridge { raw -> handler.post { tracker.mergeStoragePayload(raw) } },
                storageBridgeName,
            )
            webView.webViewClient = object : WebViewClient() {
                override fun onPageStarted(view: WebView, startedUrl: String, favicon: android.graphics.Bitmap?) {
                    if (!hydrating && !collectingStorage) {
                        navigationGeneration++
                        pendingFinish?.let(handler::removeCallbacks)
                        pendingFinish = null
                        tracker.observeCookies(startedUrl)
                    }
                }

                override fun onPageFinished(view: WebView, finishedUrl: String) {
                    if (completed.get()) return
                    if (collectingStorage) {
                        collectionOrigins.getOrNull(collectionIndex)?.let(tracker::observeCookies)
                        view.evaluateJavascript(tracker.captureStorageScript()) { storage ->
                            if (completed.get()) return@evaluateJavascript
                            tracker.mergeStorage(storage)
                            collectionIndex++
                            collectNextOriginOrSucceed()
                        }
                        return
                    }
                    if (hydrating) {
                        hydrationIndex++
                        hydrateNextOrLoad()
                        return
                    }
                    tracker.observeCookies(finishedUrl)
                    view.evaluateJavascript(tracker.captureStorageScript()) { tracker.mergeStorage(it) }
                    view.evaluateJavascript(tracker.installCaptureHooksScript(storageBridgeName), null)
                    val generation = navigationGeneration
                    pendingFinish?.let(handler::removeCallbacks)
                    pendingFinish = Runnable {
                        pendingFinish = null
                        if (completed.get() || generation != navigationGeneration || view.progress < 100) return@Runnable
                        if (webJs == null) captureResult() else {
                            view.evaluateJavascript(webJs) {
                                handler.postDelayed({ captureResult() }, 250L)
                            }
                        }
                    }
                    handler.postDelayed(pendingFinish!!, 750L)
                }

                override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                    if (request.isForMainFrame && !hydrating) {
                        fail("load_failed", "Background browser load failed: ${error.description}")
                    }
                }

                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                    tracker.recordVisitedUrl(request.url.toString())
                    return null
                }
            }
            handler.postDelayed(timeout, timeoutMs)
            SourceBrowserSessionRuntime.clearStorage {
                if (completed.get()) return@clearStorage
                tracker.restoreCookies { hydrateNextOrLoad() }
            }
        }

        private fun hydrateNextOrLoad() {
            if (completed.get()) return
            if (hydrationIndex < hydration.size) {
                hydrating = true
                val (origin, values) = hydration[hydrationIndex]
                webView.loadDataWithBaseURL("$origin/", tracker.hydrationHtml(values), "text/html", "UTF-8", null)
                return
            }
            hydrating = false
            loadTarget()
        }

        private fun loadTarget() {
            val cookieHeader = headers.entries.firstOrNull { it.key.equals("cookie", true) }?.value
            if (!cookieHeader.isNullOrBlank()) CookieManagerCompat.setCookieHeader(url, cookieHeader)
            val navigationHeaders = headers.filterKeys {
                !it.equals("cookie", true) && !it.equals("user-agent", true)
            }
            when {
                html != null -> webView.loadDataWithBaseURL(url, html, "text/html", "UTF-8", null)
                method == "POST" -> webView.postUrl(url, body.toByteArray(Charsets.UTF_8))
                else -> webView.loadUrl(url, navigationHeaders)
            }
        }

        private fun captureResult() {
            if (completed.get()) return
            tracker.observeCookies(webView.url ?: url)
            webView.evaluateJavascript(tracker.captureStorageScript()) { storage ->
                tracker.mergeStorage(storage)
                webView.evaluateJavascript(
                    "(function(){return document.documentElement ? document.documentElement.outerHTML : (document.body ? document.body.innerHTML : '');})()",
                ) { encoded ->
                    val content = try { JSONTokener(encoded).nextValue() as? String ?: "" } catch (_: Exception) { "" }
                    if (content.isEmpty()) fail("empty_page", "Background browser returned an empty page.")
                    else {
                        capturedBody = content
                        capturedFinalUrl = webView.url ?: url
                        tracker.collectableOrigins { origins ->
                            handler.post {
                                if (completed.get()) return@post
                                collectionOrigins = origins
                                collectionIndex = 0
                                collectingStorage = true
                                collectNextOriginOrSucceed()
                            }
                        }
                    }
                }
            }
        }

        private fun collectNextOriginOrSucceed() {
            if (completed.get()) return
            if (collectionIndex < collectionOrigins.size) {
                val origin = collectionOrigins[collectionIndex]
                webView.loadDataWithBaseURL("$origin/", "<!doctype html><meta charset=utf-8>", "text/html", "UTF-8", null)
                return
            }
            collectingStorage = false
            succeed(capturedBody, capturedFinalUrl)
        }

        private fun succeed(content: String, finalUrl: String) {
            if (!completed.compareAndSet(false, true)) return
            val resultFile = File(cacheDir, "source_browser_session/result-${System.nanoTime()}.json")
            resultFile.parentFile?.mkdirs()
            try {
                resultFile.writeText(
                    JSONObject(
                        mapOf(
                            "body" to content,
                            "finalUrl" to finalUrl,
                            "session" to tracker.sessionMap(),
                        ),
                    ).toString(),
                )
                val response = Message.obtain(null, MSG_SUCCESS).apply {
                    data = Bundle().apply {
                        putString(KEY_REQUEST_ID, requestId)
                        putString(KEY_RESULT_FILE, resultFile.absolutePath)
                    }
                }
                finishAfterStorageClear { reply.send(response) }
            } catch (error: Exception) {
                resultFile.delete()
                finishAfterStorageClear {
                    replyError(reply, requestId, "result_failed", error.message ?: "Browser result could not be returned.")
                }
            }
        }

        fun cancel() = fail("cancelled", "Background browser request was cancelled.")

        private fun fail(code: String, message: String) {
            if (!completed.compareAndSet(false, true)) return
            finishAfterStorageClear { replyError(reply, requestId, code, message) }
        }

        private fun finishAfterStorageClear(replyAction: () -> Unit) {
            handler.removeCallbacks(timeout)
            pendingFinish?.let(handler::removeCallbacks)
            webView.stopLoading()
            webView.webViewClient = WebViewClient()
            webView.removeJavascriptInterface(storageBridgeName)
            webView.loadUrl("about:blank")
            webView.removeAllViews()
            webView.destroy()
            SourceBrowserSessionRuntime.clearStorage {
                SourceBrowserSessionRuntime.release(owner)
                if (active === this) active = null
                try { replyAction() } catch (_: Exception) {}
                startNextLoad()
            }
        }
    }

    private fun replyError(reply: Messenger, requestId: String?, code: String, message: String) {
        val response = Message.obtain(null, MSG_ERROR).apply {
            data = Bundle().apply {
                putString(KEY_REQUEST_ID, requestId)
                putString(KEY_ERROR_CODE, code)
                putString(KEY_ERROR_MESSAGE, message)
            }
        }
        try { reply.send(response) } catch (_: Exception) {}
    }

    private fun replySuccess(reply: Messenger) {
        try { reply.send(Message.obtain(null, MSG_SUCCESS)) } catch (_: Exception) {}
    }

    private data class QueuedLoad(val payload: JSONObject, val reply: Messenger)
}

private object CookieManagerCompat {
    fun setCookieHeader(url: String, header: String) {
        val manager = android.webkit.CookieManager.getInstance()
        header.split(';').map(String::trim).filter { it.contains('=') }.forEach {
            manager.setCookie(url, it)
        }
        manager.flush()
    }
}
