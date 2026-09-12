package com.niki.xxread

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import org.json.JSONObject
import org.json.JSONTokener
import java.io.File

class SourceBrowserSessionActivity : Activity() {
    companion object {
        const val EXTRA_REQUEST_FILE = "requestFile"
        const val RESULT_FILE = "resultFile"
    }

    private lateinit var webView: WebView
    private lateinit var address: TextView
    private lateinit var progress: ProgressBar
    private lateinit var doneButton: Button
    private val payload: JSONObject by lazy {
        val file = intent.getStringExtra(EXTRA_REQUEST_FILE)?.let(::File)
        try { JSONObject(file?.readText().orEmpty()) } catch (_: Exception) { JSONObject() }
            .also { file?.delete() }
    }
    private val sourceId: String by lazy { payload.optString("sourceId") }
    private val owner: String by lazy { "open:$sourceId:${hashCode()}" }
    private val url: String by lazy { payload.optString("url") }
    private val headers: Map<String, String> by lazy { headersFromJson(payload.optJSONObject("headers")?.toString()) }
    private val suppliedHtml: String? by lazy { payload.optString("html").takeIf { it.isNotEmpty() } }
    private val tracker: SourceBrowserSessionTracker by lazy {
        SourceBrowserSessionTracker(SourceBrowserSession.fromJson(payload.optJSONObject("session")?.toString()))
    }
    private var acquired = false
    private var finishingWithResult = false
    private var hydrating = false
    private var hydrationIndex = 0
    private var collectingStorage = false
    private var collectionIndex = 0
    private var collectionOrigins = emptyList<String>()
    private var capturedBody = ""
    private var capturedFinalUrl = ""
    private val storageBridgeName = "xxreadSourceStorage"
    private val hydration by lazy { tracker.hydrationOrigins() }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!isSafeSourceBrowserUrl(url) || sourceId.isBlank()) {
            setResult(RESULT_CANCELED)
            finish()
            return
        }
        if (!SourceBrowserSessionRuntime.supportsIsolatedDataDirectory) {
            setResult(
                RESULT_CANCELED,
                Intent().putExtra("errorCode", "unsupported").putExtra(
                    "errorMessage",
                    "Isolated source browser sessions require Android 9 or newer.",
                ),
            )
            finish()
            return
        }
        acquired = SourceBrowserSessionRuntime.acquire(owner, sourceId) {
            runOnUiThread { cancelAndFinish() }
        }
        if (!acquired) {
            setResult(RESULT_CANCELED, Intent().putExtra("errorCode", "busy"))
            finish()
            return
        }
        title = payload.optString("title").takeIf { it.isNotBlank() } ?: getString(R.string.source_browser_login_title)
        buildUi()
        configureSourceBrowserWebView(webView, headers)
        webView.addJavascriptInterface(
            SourceStorageJavascriptBridge { raw -> webView.post { tracker.mergeStoragePayload(raw) } },
            storageBridgeName,
        )
        webView.setDownloadListener { _, _, _, _, _ -> }
        webView.webChromeClient = object : android.webkit.WebChromeClient() {
            override fun onProgressChanged(view: WebView, newProgress: Int) {
                progress.progress = newProgress
                progress.visibility = if (newProgress >= 100) ProgressBar.GONE else ProgressBar.VISIBLE
            }
        }
        webView.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, nextUrl: String, favicon: android.graphics.Bitmap?) {
                if (!hydrating && !collectingStorage) {
                    address.text = nextUrl
                    tracker.observeCookies(nextUrl)
                }
            }

            override fun onPageFinished(view: WebView, finishedUrl: String) {
                if (collectingStorage) {
                    collectionOrigins.getOrNull(collectionIndex)?.let(tracker::observeCookies)
                    view.evaluateJavascript(tracker.captureStorageScript()) { storage ->
                        if (completed) return@evaluateJavascript
                        tracker.mergeStorage(storage)
                        collectionIndex++
                        collectNextOriginOrFinish()
                    }
                    return
                }
                if (hydrating) {
                    hydrationIndex++
                    hydrateNextOrLoad()
                    return
                }
                address.text = finishedUrl
                tracker.observeCookies(finishedUrl)
                view.evaluateJavascript(tracker.captureStorageScript()) { tracker.mergeStorage(it) }
                view.evaluateJavascript(tracker.installCaptureHooksScript(storageBridgeName), null)
            }

            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val scheme = request.url.scheme
                return scheme != "http" && scheme != "https"
            }

            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                tracker.recordVisitedUrl(request.url.toString())
                return null
            }
        }
        SourceBrowserSessionRuntime.clearStorage {
            if (!isFinishing) tracker.restoreCookies { hydrateNextOrLoad() }
        }
    }

    private fun buildUi() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.WHITE)
        }
        val toolbar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(12, 8, 12, 8)
        }
        val cancel = Button(this).apply {
            text = payload.optString("cancelLabel").takeIf { it.isNotBlank() }
                ?: getString(R.string.source_browser_cancel)
            isAllCaps = false
            setOnClickListener { cancelAndFinish() }
        }
        address = TextView(this).apply {
            text = url
            maxLines = 2
            setTextColor(Color.DKGRAY)
            setPadding(12, 0, 12, 0)
        }
        doneButton = Button(this).apply {
            text = payload.optString("doneLabel").takeIf { it.isNotBlank() }
                ?: getString(R.string.source_browser_done)
            isAllCaps = false
            setOnClickListener { captureAndFinish() }
        }
        toolbar.addView(cancel)
        toolbar.addView(address, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        toolbar.addView(doneButton)
        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply { max = 100 }
        webView = WebView(this)
        root.addView(toolbar)
        root.addView(progress, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 5))
        root.addView(webView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)
    }

    private fun hydrateNextOrLoad() {
        if (isFinishing) return
        if (hydrationIndex < hydration.size) {
            hydrating = true
            val (origin, values) = hydration[hydrationIndex]
            webView.loadDataWithBaseURL("$origin/", tracker.hydrationHtml(values), "text/html", "UTF-8", null)
            return
        }
        hydrating = false
        val cookieHeader = headers.entries.firstOrNull { it.key.equals("cookie", true) }?.value
        if (!cookieHeader.isNullOrBlank()) {
            cookieHeader.split(';').map(String::trim).filter { it.contains('=') }.forEach {
                android.webkit.CookieManager.getInstance().setCookie(url, it)
            }
            android.webkit.CookieManager.getInstance().flush()
        }
        val navigationHeaders = headers.filterKeys {
            !it.equals("cookie", true) && !it.equals("user-agent", true)
        }
        if (suppliedHtml != null) {
            webView.loadDataWithBaseURL(url, suppliedHtml!!, "text/html", "UTF-8", null)
        } else {
            webView.loadUrl(url, navigationHeaders)
        }
    }

    private var completed = false

    private fun captureAndFinish() {
        if (completed || finishingWithResult || hydrating) return
        finishingWithResult = true
        doneButton.isEnabled = false
        val current = webView.url ?: url
        tracker.observeCookies(current)
        webView.evaluateJavascript(tracker.captureStorageScript()) { storage ->
            tracker.mergeStorage(storage)
            webView.evaluateJavascript(
                "(function(){return document.documentElement ? document.documentElement.outerHTML : (document.body ? document.body.innerHTML : '');})()",
            ) { encoded ->
                if (completed) return@evaluateJavascript
                capturedBody = try { JSONTokener(encoded).nextValue() as? String ?: "" } catch (_: Exception) { "" }
                capturedFinalUrl = current
                tracker.collectableOrigins { origins ->
                    webView.post {
                        if (completed) return@post
                        collectionOrigins = origins
                        collectionIndex = 0
                        collectingStorage = true
                        collectNextOriginOrFinish()
                    }
                }
            }
        }
    }

    private fun collectNextOriginOrFinish() {
        if (completed) return
        if (collectionIndex < collectionOrigins.size) {
            val origin = collectionOrigins[collectionIndex]
            webView.loadDataWithBaseURL("$origin/", "<!doctype html><meta charset=utf-8>", "text/html", "UTF-8", null)
            return
        }
        collectingStorage = false
        val resultFile = File(cacheDir, "source_browser_session/open-${System.nanoTime()}.json")
        try {
            resultFile.parentFile?.mkdirs()
            resultFile.writeText(
                JSONObject(
                    mapOf(
                        "body" to capturedBody,
                        "finalUrl" to capturedFinalUrl,
                        "session" to tracker.sessionMap(),
                    ),
                ).toString(),
            )
            completed = true
            finishWithClearedStorage(RESULT_OK, Intent().putExtra(RESULT_FILE, resultFile.absolutePath))
        } catch (error: Exception) {
            completed = true
            finishWithClearedStorage(
                RESULT_CANCELED,
                Intent().putExtra("errorCode", "result_failed").putExtra("errorMessage", error.message),
            )
        }
    }

    private fun cancelAndFinish() {
        if (completed) return
        completed = true
        finishWithClearedStorage(RESULT_CANCELED, Intent().putExtra("errorCode", "cancelled"))
    }

    private fun finishWithClearedStorage(resultCode: Int, data: Intent) {
        if (!acquired) {
            setResult(resultCode, data)
            finish()
            return
        }
        SourceBrowserSessionRuntime.clearStorage {
            SourceBrowserSessionRuntime.release(owner)
            acquired = false
            setResult(resultCode, data)
            finish()
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (::webView.isInitialized && !hydrating && webView.canGoBack()) webView.goBack() else cancelAndFinish()
    }

    override fun onDestroy() {
        if (::webView.isInitialized) {
            webView.stopLoading()
            webView.webViewClient = WebViewClient()
            webView.removeJavascriptInterface(storageBridgeName)
            webView.destroy()
        }
        if (acquired) {
            SourceBrowserSessionRuntime.release(owner)
            acquired = false
        }
        super.onDestroy()
    }
}
