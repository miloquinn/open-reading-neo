package com.niki.xxread

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.webkit.WebResourceRequest
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
        const val EXTRA_SOURCE_ID = "sourceId"
        const val EXTRA_URL = "url"
        const val EXTRA_HEADERS_JSON = "headersJson"
        const val EXTRA_SESSION_JSON = "sessionJson"
        const val EXTRA_TITLE = "title"
        const val EXTRA_DONE_LABEL = "doneLabel"
        const val EXTRA_CANCEL_LABEL = "cancelLabel"
        const val RESULT_FILE = "resultFile"
    }

    private lateinit var webView: WebView
    private lateinit var address: TextView
    private lateinit var progress: ProgressBar
    private lateinit var doneButton: Button
    private val owner: String by lazy { "open:${intent.getStringExtra(EXTRA_SOURCE_ID).orEmpty()}:${hashCode()}" }
    private val url: String by lazy { intent.getStringExtra(EXTRA_URL).orEmpty() }
    private val headers: Map<String, String> by lazy { headersFromJson(intent.getStringExtra(EXTRA_HEADERS_JSON)) }
    private val tracker: SourceBrowserSessionTracker by lazy {
        SourceBrowserSessionTracker(SourceBrowserSession.fromJson(intent.getStringExtra(EXTRA_SESSION_JSON)))
    }
    private var acquired = false
    private var finishingWithResult = false
    private var hydrating = false
    private var hydrationIndex = 0
    private val hydration by lazy { tracker.hydrationOrigins() }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (url.isBlank() || intent.getStringExtra(EXTRA_SOURCE_ID).isNullOrBlank()) {
            setResult(RESULT_CANCELED)
            finish()
            return
        }
        acquired = SourceBrowserSessionRuntime.acquire(owner)
        if (!acquired) {
            setResult(RESULT_CANCELED, Intent().putExtra("errorCode", "busy"))
            finish()
            return
        }
        title = intent.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() } ?: getString(R.string.source_browser_login_title)
        buildUi()
        configureSourceBrowserWebView(webView, headers)
        webView.setDownloadListener { _, _, _, _, _ -> }
        webView.webChromeClient = object : android.webkit.WebChromeClient() {
            override fun onProgressChanged(view: WebView, newProgress: Int) {
                progress.progress = newProgress
                progress.visibility = if (newProgress >= 100) ProgressBar.GONE else ProgressBar.VISIBLE
            }
        }
        webView.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, nextUrl: String, favicon: android.graphics.Bitmap?) {
                if (!hydrating) {
                    address.text = nextUrl
                    tracker.observeCookies(nextUrl)
                }
            }

            override fun onPageFinished(view: WebView, finishedUrl: String) {
                if (hydrating) {
                    hydrationIndex++
                    hydrateNextOrLoad()
                    return
                }
                address.text = finishedUrl
                tracker.observeCookies(finishedUrl)
                view.evaluateJavascript(tracker.captureStorageScript()) { tracker.mergeStorage(it) }
            }

            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val scheme = request.url.scheme
                return scheme != "http" && scheme != "https"
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
            text = intent.getStringExtra(EXTRA_CANCEL_LABEL)?.takeIf { it.isNotBlank() }
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
            text = intent.getStringExtra(EXTRA_DONE_LABEL)?.takeIf { it.isNotBlank() }
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
        webView.loadUrl(url, navigationHeaders)
    }

    private fun captureAndFinish() {
        if (finishingWithResult || hydrating) return
        finishingWithResult = true
        doneButton.isEnabled = false
        val current = webView.url ?: url
        tracker.observeCookies(current)
        webView.evaluateJavascript(tracker.captureStorageScript()) { storage ->
            tracker.mergeStorage(storage)
            webView.evaluateJavascript(
                "(function(){return document.documentElement ? document.documentElement.outerHTML : (document.body ? document.body.innerHTML : '');})()",
            ) { encoded ->
                val body = try { JSONTokener(encoded).nextValue() as? String ?: "" } catch (_: Exception) { "" }
                val resultFile = File(cacheDir, "source_browser_session/open-${System.nanoTime()}.json")
                try {
                    resultFile.parentFile?.mkdirs()
                    resultFile.writeText(
                        JSONObject(
                            mapOf(
                                "body" to body,
                                "finalUrl" to current,
                                "session" to tracker.sessionMap(),
                            ),
                        ).toString(),
                    )
                    setResult(RESULT_OK, Intent().putExtra(RESULT_FILE, resultFile.absolutePath))
                } catch (error: Exception) {
                    setResult(
                        RESULT_CANCELED,
                        Intent().putExtra("errorCode", "result_failed").putExtra("errorMessage", error.message),
                    )
                }
                finish()
            }
        }
    }

    private fun cancelAndFinish() {
        setResult(RESULT_CANCELED, Intent().putExtra("errorCode", "cancelled"))
        finish()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (::webView.isInitialized && !hydrating && webView.canGoBack()) webView.goBack() else cancelAndFinish()
    }

    override fun onDestroy() {
        if (::webView.isInitialized) {
            webView.stopLoading()
            webView.webViewClient = WebViewClient()
            webView.destroy()
        }
        if (acquired) {
            SourceBrowserSessionRuntime.clearStorage { SourceBrowserSessionRuntime.release(owner) }
            acquired = false
        }
        super.onDestroy()
    }
}
