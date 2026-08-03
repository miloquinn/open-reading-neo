package com.niki.xxread

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONTokener
import java.util.concurrent.atomic.AtomicBoolean

class SourceWebViewBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    companion object {
        private const val CHANNEL = "com.niki.xxread/source_webview"
    }

    private val handler = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, CHANNEL)
    private val activeViews = mutableSetOf<WebView>()

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "load") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val url = call.argument<String>("url")
            if (url.isNullOrBlank()) {
                result.error("invalid_url", "Background browser URL is empty.", null)
                return@setMethodCallHandler
            }
            val method = call.argument<String>("method")?.uppercase() ?: "GET"
            val headers = (call.argument<Map<*, *>>("headers") ?: emptyMap<Any, Any>())
                .entries
                .associate { "${it.key}" to "${it.value}" }
            val body = call.argument<String>("body") ?: ""
            val webJs = call.argument<String>("webJs")
            val html = call.argument<String>("html")
            val timeoutMs = (call.argument<Number>("timeoutMs")?.toLong() ?: 15_000L)
                .coerceIn(2_000L, 30_000L)
            load(url, method, headers, body, webJs, html, timeoutMs, result)
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun load(
        url: String,
        method: String,
        headers: Map<String, String>,
        body: String,
        webJs: String?,
        html: String?,
        timeoutMs: Long,
        result: MethodChannel.Result,
    ) {
        val completed = AtomicBoolean(false)
        val webView = WebView(context)
        var navigationGeneration = 0
        var pendingCapture: Runnable? = null
        activeViews.add(webView)
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            javaScriptCanOpenWindowsAutomatically = false
            mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
            headers.entries.firstOrNull { it.key.equals("user-agent", true) }
                ?.value
                ?.takeIf { it.isNotBlank() }
                ?.let { userAgentString = it }
        }

        fun cleanup() {
            handler.post {
                pendingCapture?.let(handler::removeCallbacks)
                pendingCapture = null
                activeViews.remove(webView)
                webView.stopLoading()
                webView.webViewClient = WebViewClient()
                webView.loadUrl("about:blank")
                webView.clearHistory()
                webView.removeAllViews()
                webView.destroy()
            }
        }

        fun fail(code: String, message: String) {
            if (!completed.compareAndSet(false, true)) return
            result.error(code, message, null)
            cleanup()
        }

        fun capture() {
            if (completed.get()) return
            webView.evaluateJavascript(
                "(function(){return document.documentElement ? document.documentElement.outerHTML : document.body.innerHTML;})()",
            ) { encoded ->
                if (!completed.compareAndSet(false, true)) return@evaluateJavascript
                val html = try {
                    JSONTokener(encoded).nextValue() as? String ?: ""
                } catch (_: Exception) {
                    ""
                }
                if (html.isEmpty()) {
                    result.error("empty_page", "Background browser returned an empty page.", null)
                } else {
                    result.success(
                        mapOf(
                            "body" to html,
                            "finalUrl" to (webView.url ?: url),
                            "cookieHeader" to CookieManager.getInstance()
                                .getCookie(webView.url ?: url),
                        ),
                    )
                }
                cleanup()
            }
        }

        webView.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, startedUrl: String, favicon: android.graphics.Bitmap?) {
                navigationGeneration++
                pendingCapture?.let(handler::removeCallbacks)
                pendingCapture = null
            }

            override fun onPageFinished(view: WebView, finishedUrl: String) {
                if (completed.get() || finishedUrl == "about:blank") return
                val finishedGeneration = navigationGeneration
                pendingCapture?.let(handler::removeCallbacks)
                pendingCapture = Runnable {
                    if (completed.get()) return@Runnable
                    if (finishedGeneration != navigationGeneration || view.progress < 100) {
                        return@Runnable
                    }
                    if (webJs.isNullOrBlank()) {
                        capture()
                    } else {
                        view.evaluateJavascript(webJs) {
                            handler.postDelayed({ capture() }, 250L)
                        }
                    }
                }
                handler.postDelayed(pendingCapture!!, 750L)
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError,
            ) {
                if (request.isForMainFrame) {
                    fail("load_failed", "Background browser load failed: ${error.description}")
                }
            }
        }

        handler.postDelayed({
            fail("timeout", "Background browser timed out while loading this source.")
        }, timeoutMs)

        val cookie = headers.entries.firstOrNull { it.key.equals("cookie", true) }?.value
        if (!cookie.isNullOrBlank()) {
            CookieManager.getInstance().setCookie(url, cookie)
            CookieManager.getInstance().flush()
        }
        val navigationHeaders = headers.filterKeys {
            !it.equals("cookie", true) && !it.equals("user-agent", true)
        }
        if (!html.isNullOrEmpty()) {
            webView.loadDataWithBaseURL(url, html, "text/html", "UTF-8", null)
        } else if (method == "POST") {
            webView.postUrl(url, body.toByteArray(Charsets.UTF_8))
        } else {
            webView.loadUrl(url, navigationHeaders)
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        val views = activeViews.toList()
        activeViews.clear()
        for (view in views) {
            view.stopLoading()
            view.destroy()
        }
    }
}
