package com.niki.xxread

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import org.json.JSONTokener

class SourceInteractiveBrowserActivity : Activity() {
    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_HTML = "html"
        const val EXTRA_HEADERS = "headers"
        const val RESULT_BODY = "body"
        const val RESULT_URL = "finalUrl"
        const val RESULT_COOKIE = "cookieHeader"
    }

    private lateinit var webView: WebView
    private lateinit var address: TextView
    private lateinit var progress: ProgressBar

    @Suppress("DEPRECATION")
    private val headers: HashMap<String, String> by lazy {
        (intent.getSerializableExtra(EXTRA_HEADERS) as? HashMap<String, String>) ?: hashMapOf()
    }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.getStringExtra(EXTRA_URL).orEmpty()
        if (url.isBlank()) {
            setResult(RESULT_CANCELED)
            finish()
            return
        }
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
            text = getString(R.string.source_browser_cancel)
            setOnClickListener { cancelAndFinish() }
        }
        address = TextView(this).apply {
            text = url
            maxLines = 2
            setTextColor(Color.DKGRAY)
            setPadding(12, 0, 12, 0)
        }
        val done = Button(this).apply {
            text = getString(R.string.source_browser_done)
            isAllCaps = false
            setOnClickListener { captureAndFinish() }
        }
        toolbar.addView(cancel)
        toolbar.addView(address, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        toolbar.addView(done)
        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
        }
        webView = WebView(this)
        root.addView(toolbar)
        root.addView(progress, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 5))
        root.addView(webView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)

        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
            headers.entries.firstOrNull { it.key.equals("user-agent", true) }
                ?.value
                ?.takeIf { it.isNotBlank() }
                ?.let { userAgentString = it }
        }
        webView.setDownloadListener { _, _, _, _, _ -> }
        webView.webChromeClient = object : android.webkit.WebChromeClient() {
            override fun onProgressChanged(view: WebView, newProgress: Int) {
                progress.progress = newProgress
                progress.visibility = if (newProgress >= 100) ProgressBar.GONE else ProgressBar.VISIBLE
            }
        }
        webView.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, nextUrl: String, favicon: android.graphics.Bitmap?) {
                address.text = nextUrl
            }

            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val next = request.url
                if (next.scheme != "http" && next.scheme != "https") return true
                return false
            }
        }
        val cookie = headers.entries.firstOrNull { it.key.equals("cookie", true) }?.value
        if (!cookie.isNullOrBlank()) {
            CookieManager.getInstance().setCookie(url, cookie)
            CookieManager.getInstance().flush()
        }
        val navigationHeaders = headers.filterKeys {
            !it.equals("cookie", true) && !it.equals("user-agent", true)
        }
        val html = intent.getStringExtra(EXTRA_HTML)
        if (!html.isNullOrEmpty()) {
            webView.loadDataWithBaseURL(url, html, "text/html", "UTF-8", null)
        } else {
            webView.loadUrl(url, navigationHeaders)
        }
    }

    private fun captureAndFinish() {
        val current = webView.url ?: intent.getStringExtra(EXTRA_URL).orEmpty()
        webView.evaluateJavascript(
            "(function(){return document.documentElement ? document.documentElement.outerHTML : document.body.innerHTML;})()",
        ) { encoded ->
            val body = try {
                JSONTokener(encoded).nextValue() as? String ?: ""
            } catch (_: Exception) {
                ""
            }
            val data = Intent().apply {
                putExtra(RESULT_BODY, body)
                putExtra(RESULT_URL, current)
                putExtra(RESULT_COOKIE, CookieManager.getInstance().getCookie(current))
            }
            setResult(RESULT_OK, data)
            finish()
        }
    }

    private fun cancelAndFinish() {
        setResult(RESULT_CANCELED)
        finish()
    }

    override fun onBackPressed() {
        if (::webView.isInitialized && webView.canGoBack()) webView.goBack() else cancelAndFinish()
    }

    override fun onDestroy() {
        if (::webView.isInitialized) {
            webView.stopLoading()
            webView.destroy()
        }
        super.onDestroy()
    }
}
