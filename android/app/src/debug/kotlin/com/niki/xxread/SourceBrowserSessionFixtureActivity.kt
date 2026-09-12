package com.niki.xxread

import android.annotation.SuppressLint
import android.app.Activity
import android.os.Bundle
import android.util.Log
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.LinearLayout
import android.widget.TextView

/** Debug-only native fixture for the immediate cross-origin localStorage redirect case. */
class SourceBrowserSessionFixtureActivity : Activity() {
    private val tracker = SourceBrowserSessionTracker(SourceBrowserSession())
    private lateinit var webView: WebView
    private lateinit var status: TextView
    private var origins = emptyList<String>()
    private var originIndex = 0
    private var collecting = false

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        status = TextView(this).apply { text = "Running source browser session fixture…" }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(status, LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        }
        setContentView(root)
        if (!SourceBrowserSessionRuntime.supportsIsolatedDataDirectory) {
            finishFixture(false, "Requires Android 9+")
            return
        }
        webView = WebView(this)
        root.addView(webView, LinearLayout.LayoutParams(1, 1))
        configureSourceBrowserWebView(webView, emptyMap())
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                if (request.url.host == "final.fixture.invalid") {
                    view.loadDataWithBaseURL(
                        "https://final.fixture.invalid/",
                        "<script>localStorage.setItem('final','present')</script>",
                        "text/html",
                        "UTF-8",
                        null,
                    )
                    return true
                }
                return false
            }

            override fun onPageFinished(view: WebView, url: String) {
                if (collecting) {
                    view.evaluateJavascript(tracker.captureStorageScript()) { value ->
                        tracker.mergeStorage(value)
                        originIndex++
                        collectNext()
                    }
                    return
                }
                if (url.startsWith("https://final.fixture.invalid")) {
                    tracker.collectableOrigins { values ->
                        view.post {
                            origins = values
                            originIndex = 0
                            collecting = true
                            collectNext()
                        }
                    }
                }
            }
        }
        SourceBrowserSessionRuntime.clearStorage {
            tracker.recordVisitedUrl("https://auth.fixture.invalid/")
            tracker.recordVisitedUrl("https://final.fixture.invalid/")
            webView.loadDataWithBaseURL(
                "https://auth.fixture.invalid/",
                "<script>localStorage.setItem('auth','present');location.href='https://final.fixture.invalid/'</script>",
                "text/html",
                "UTF-8",
                null,
            )
        }
    }

    private fun collectNext() {
        if (originIndex < origins.size) {
            webView.loadDataWithBaseURL(
                "${origins[originIndex]}/",
                "<!doctype html>",
                "text/html",
                "UTF-8",
                null,
            )
            return
        }
        @Suppress("UNCHECKED_CAST")
        val storage = tracker.sessionMap()["localStorage"] as? Map<String, Map<String, String>> ?: emptyMap()
        val passed = storage["https://auth.fixture.invalid"]?.get("auth") == "present" &&
            storage["https://final.fixture.invalid"]?.get("final") == "present"
        finishFixture(passed, storage.toString())
    }

    private fun finishFixture(passed: Boolean, detail: String) {
        val message = "${if (passed) "PASS" else "FAIL"}: $detail"
        Log.i("SourceBrowserFixture", message)
        status.text = message
    }

    override fun onDestroy() {
        if (::webView.isInitialized) webView.destroy()
        super.onDestroy()
    }
}
