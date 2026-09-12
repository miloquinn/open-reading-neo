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
        val requestFile = message.data.getString(KEY_REQUEST_FILE)?.let(::File)
        if (requestFile == null || !requestFile.isFile) {
            replyError(reply, null, "invalid_request", "Browser session request payload is missing.")
            return
        }
        val payload = try {
            JSONObject(requestFile.readText())
        } catch (error: Exception) {
            requestFile.delete()
            replyError(reply, null, "invalid_request", error.message ?: "Browser session request is invalid.")
            return
        } finally {
            requestFile.delete()
        }
        val requestId = payload.optString("requestId")
        val sourceId = payload.optString("sourceId")
        val url = payload.optString("url")
        if (requestId.isBlank() || sourceId.isBlank() || url.isBlank()) {
            replyError(reply, requestId, "invalid_request", "sourceId, requestId, and URL are required.")
            return
        }
        if (active != null || !SourceBrowserSessionRuntime.acquire("load:$requestId")) {
            replyError(reply, requestId, "busy", "Another source browser session is active.")
            return
        }
        active = BackgroundLoad(payload, reply).also { it.start() }
    }

    private fun handleCancel(message: Message) {
        val requestId = message.data.getString(KEY_REQUEST_ID)
        if (active?.requestId == requestId) active?.cancel()
    }

    private fun handleClear(message: Message) {
        val reply = message.replyTo ?: return
        if (active != null || !SourceBrowserSessionRuntime.acquire("clear")) {
            replyError(reply, null, "busy", "Another source browser session is active.")
            return
        }
        SourceBrowserSessionRuntime.clearStorage {
            SourceBrowserSessionRuntime.release("clear")
            val response = Message.obtain(null, MSG_SUCCESS).apply {
                data = Bundle().apply { putBoolean("cleared", true) }
            }
            try { reply.send(response) } catch (_: Exception) {}
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private inner class BackgroundLoad(
        private val payload: JSONObject,
        private val reply: Messenger,
    ) {
        val requestId: String = payload.optString("requestId")
        private val owner = "load:$requestId"
        private val sourceId = payload.optString("sourceId")
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
        private var hydrating = false
        private var hydrationIndex = 0
        private val hydration = tracker.hydrationOrigins()
        private var navigationGeneration = 0
        private var pendingFinish: Runnable? = null
        private val timeout = Runnable { fail("timeout", "Background browser timed out while loading this source.") }

        fun start() {
            configureSourceBrowserWebView(webView, headers)
            webView.webViewClient = object : WebViewClient() {
                override fun onPageStarted(view: WebView, startedUrl: String, favicon: android.graphics.Bitmap?) {
                    if (!hydrating) {
                        navigationGeneration++
                        pendingFinish?.let(handler::removeCallbacks)
                        pendingFinish = null
                        tracker.observeCookies(startedUrl)
                    }
                }

                override fun onPageFinished(view: WebView, finishedUrl: String) {
                    if (completed.get()) return
                    if (hydrating) {
                        hydrationIndex++
                        hydrateNextOrLoad()
                        return
                    }
                    tracker.observeCookies(finishedUrl)
                    view.evaluateJavascript(tracker.captureStorageScript()) { tracker.mergeStorage(it) }
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
                    else succeed(content, webView.url ?: url)
                }
            }
        }

        private fun succeed(content: String, finalUrl: String) {
            if (!completed.compareAndSet(false, true)) return
            val resultFile = File(cacheDir, "source_browser_session/result-$requestId.json")
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
                reply.send(response)
            } catch (error: Exception) {
                resultFile.delete()
                replyError(reply, requestId, "result_failed", error.message ?: "Browser result could not be returned.")
            }
            cleanup()
        }

        fun cancel() = fail("cancelled", "Background browser request was cancelled.")

        private fun fail(code: String, message: String) {
            if (!completed.compareAndSet(false, true)) return
            replyError(reply, requestId, code, message)
            cleanup()
        }

        private fun cleanup() {
            handler.removeCallbacks(timeout)
            pendingFinish?.let(handler::removeCallbacks)
            webView.stopLoading()
            webView.webViewClient = WebViewClient()
            webView.loadUrl("about:blank")
            webView.removeAllViews()
            webView.destroy()
            SourceBrowserSessionRuntime.clearStorage {
                SourceBrowserSessionRuntime.release(owner)
                if (active === this) active = null
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
