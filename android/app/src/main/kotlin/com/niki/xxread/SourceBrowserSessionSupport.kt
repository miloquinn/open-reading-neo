package com.niki.xxread

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Build
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebStorage
import android.webkit.WebView
import android.widget.Toast
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.net.URI
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

internal object SourceBrowserSessionRuntime {
    val supportsIsolatedDataDirectory: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P

    private var owner: String? = null
    private var sourceId: String? = null
    private var cancelAction: (() -> Unit)? = null
    private val idleCallbacks = mutableListOf<() -> Unit>()

    @Synchronized
    fun acquire(candidate: String, source: String? = null, cancel: (() -> Unit)? = null): Boolean {
        if (owner != null) return false
        owner = candidate
        sourceId = source
        cancelAction = cancel
        return true
    }

    fun release(candidate: String) {
        val callbacks: List<() -> Unit>
        synchronized(this) {
            if (owner != candidate) return
            owner = null
            sourceId = null
            cancelAction = null
            callbacks = idleCallbacks.toList()
            idleCallbacks.clear()
        }
        callbacks.forEach { it() }
    }

    @Synchronized
    fun activeSourceId(): String? = sourceId

    fun cancelSource(source: String): Boolean {
        val action = synchronized(this) {
            if (sourceId == source) cancelAction else null
        } ?: return false
        action()
        return true
    }

    fun whenIdle(callback: () -> Unit) {
        val runNow = synchronized(this) {
            if (owner == null) true else {
                idleCallbacks += callback
                false
            }
        }
        if (runNow) callback()
    }

    fun clearStorage(onCookiesCleared: () -> Unit) {
        WebStorage.getInstance().deleteAllData()
        CookieManager.getInstance().removeAllCookies {
            CookieManager.getInstance().flush()
            onCookiesCleared()
        }
    }
}

internal data class SourceBrowserSession(
    val cookies: MutableList<MutableMap<String, Any?>> = mutableListOf(),
    val localStorage: MutableMap<String, MutableMap<String, String>> = linkedMapOf(),
) {
    companion object {
        fun fromJson(raw: String?): SourceBrowserSession {
            if (raw.isNullOrBlank()) return SourceBrowserSession()
            return try {
                val root = JSONTokener(raw).nextValue() as? JSONObject ?: return SourceBrowserSession()
                val cookies = mutableListOf<MutableMap<String, Any?>>()
                val cookieArray = root.optJSONArray("cookies") ?: JSONArray()
                for (index in 0 until cookieArray.length()) {
                    val item = cookieArray.optJSONObject(index) ?: continue
                    @Suppress("UNCHECKED_CAST")
                    cookies += jsonToPlatform(item) as MutableMap<String, Any?>
                }
                val storage = linkedMapOf<String, MutableMap<String, String>>()
                val storageObject = root.optJSONObject("localStorage") ?: JSONObject()
                storageObject.keys().forEach { origin ->
                    val values = storageObject.optJSONObject(origin) ?: return@forEach
                    val entries = linkedMapOf<String, String>()
                    values.keys().forEach { key -> entries[key] = values.optString(key, "") }
                    storage[origin] = entries
                }
                SourceBrowserSession(cookies, storage)
            } catch (_: Exception) {
                SourceBrowserSession()
            }
        }
    }

    fun toPlatformMap(): Map<String, Any?> = mapOf(
        "cookies" to cookies.map { LinkedHashMap(it) },
        "localStorage" to localStorage.mapValues { LinkedHashMap(it.value) },
    )
}

internal class SourceBrowserSessionTracker(private val session: SourceBrowserSession) {
    private val visitedOrigins = linkedSetOf<String>()
    fun restoreCookies(done: () -> Unit) {
        val manager = CookieManager.getInstance()
        manager.setAcceptCookie(true)
        val restorable = session.cookies.mapNotNull { cookie ->
            val expiresAt = (cookie["expiresAt"] as? Number)?.toLong()
            if (expiresAt != null && expiresAt <= System.currentTimeMillis()) return@mapNotNull null
            val name = cookie["name"]?.toString()?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            val value = cookie["value"]?.toString() ?: ""
            val domain = cookie["domain"]?.toString()?.trim()?.trimStart('.')
            val cookieUrl = cookie["cookieUrl"]?.toString()?.takeIf { it.startsWith("http://") || it.startsWith("https://") }
                ?: domain?.takeIf { it.isNotBlank() }?.let {
                    val scheme = if (cookie["secure"] == true) "https" else "http"
                    "$scheme://$it${cookie["path"]?.toString()?.takeIf(String::isNotBlank) ?: "/"}"
                }
                ?: return@mapNotNull null
            cookieUrl to buildString {
                append(name).append('=').append(value)
                cookie["path"]?.toString()?.takeIf { it.isNotBlank() }?.let { append("; Path=").append(it) }
                if (cookie["hostOnly"] != true && !domain.isNullOrBlank()) append("; Domain=").append(domain)
                if (cookie["secure"] == true) append("; Secure")
                if (cookie["httpOnly"] == true) append("; HttpOnly")
                expiresAt?.let { expiry ->
                    append("; Expires=").append(httpDate(expiry))
                }
                cookie["sameSite"]?.toString()?.takeIf { it.isNotBlank() }?.let {
                    append("; SameSite=").append(it)
                }
            }
        }
        if (restorable.isEmpty()) {
            done()
            return
        }
        var remaining = restorable.size
        restorable.forEach { (url, value) ->
            manager.setCookie(url, value) {
                remaining--
                if (remaining == 0) {
                    manager.flush()
                    done()
                }
            }
        }
    }

    fun hydrationOrigins(): List<Pair<String, Map<String, String>>> = session.localStorage.entries
        .mapNotNull { (origin, values) -> normalizedOrigin(origin)?.let { it to values } }

    fun hydrationHtml(values: Map<String, String>): String {
        val encoded = JSONObject.quote(JSONObject(values).toString())
            .replace("<", "\\u003c")
            .replace(">", "\\u003e")
            .replace("&", "\\u0026")
            .replace("\u2028", "\\u2028")
            .replace("\u2029", "\\u2029")
        return """<!doctype html><meta charset="utf-8"><script>
            try {
              var values = JSON.parse($encoded);
              Object.keys(values).forEach(function(key) { localStorage.setItem(key, String(values[key])); });
            } catch (_) {}
        </script>""".trimIndent()
    }

    fun captureStorageScript(): String = """
        (function() {
          var values = Object.create(null);
          try {
            for (var i = 0; i < localStorage.length; i++) {
              var key = localStorage.key(i);
              values[key] = localStorage.getItem(key);
            }
          } catch (_) {}
          return JSON.stringify({origin: location.origin, values: values});
        })()
    """.trimIndent()

    fun mergeStorage(encoded: String?) {
        try {
            val raw = JSONTokener(encoded ?: "null").nextValue() as? String ?: return
            mergeStoragePayload(raw)
        } catch (_: Exception) {
        }
    }

    fun mergeStoragePayload(raw: String?) {
        if (raw.isNullOrEmpty()) return
        try {
            val payload = JSONObject(raw)
            val origin = normalizedOrigin(payload.optString("origin")) ?: return
            val valuesObject = payload.optJSONObject("values") ?: return
            val values = linkedMapOf<String, String>()
            valuesObject.keys().forEach { key -> values[key] = valuesObject.optString(key, "") }
            session.localStorage[origin] = values
        } catch (_: Exception) {
        }
    }

    fun installCaptureHooksScript(bridgeName: String): String = """
        (function() {
          if (window.__xxreadStorageHooksInstalled) return;
          window.__xxreadStorageHooksInstalled = true;
          function snapshot() {
            var values = Object.create(null);
            try {
              for (var i = 0; i < localStorage.length; i++) {
                var key = localStorage.key(i);
                values[key] = localStorage.getItem(key);
              }
              window[${JSONObject.quote(bridgeName)}].capture(JSON.stringify({origin: location.origin, values: values}));
            } catch (_) {}
          }
          try {
            var setItem = Storage.prototype.setItem;
            var removeItem = Storage.prototype.removeItem;
            var clear = Storage.prototype.clear;
            Storage.prototype.setItem = function(k, v) { setItem.call(this, k, v); if (this === localStorage) snapshot(); };
            Storage.prototype.removeItem = function(k) { removeItem.call(this, k); if (this === localStorage) snapshot(); };
            Storage.prototype.clear = function() { clear.call(this); if (this === localStorage) snapshot(); };
          } catch (_) {}
          window.addEventListener('pagehide', snapshot);
          document.addEventListener('visibilitychange', function() { if (document.visibilityState === 'hidden') snapshot(); });
          snapshot();
        })()
    """.trimIndent()

    fun observeCookies(url: String?) {
        if (url.isNullOrBlank() || (!url.startsWith("http://") && !url.startsWith("https://"))) return
        recordVisitedUrl(url)
        val header = CookieManager.getInstance().getCookie(url).orEmpty()
        val uri = try { URI(url) } catch (_: Exception) { return }
        val observed = parseCookieHeader(header)
        val origin = "${uri.scheme}://${uri.host}${if (uri.port == -1) "" else ":${uri.port}"}"
        val rootObserved = parseCookieHeader(CookieManager.getInstance().getCookie("$origin/").orEmpty())
        val consumedKnown = mutableSetOf<Int>()
        observed.forEach { (name, value) ->
            val knownIndex = session.cookies.indices.firstOrNull { index ->
                index !in consumedKnown && session.cookies[index]["name"] == name &&
                    cookieApplies(session.cookies[index], uri)
            }
            if (knownIndex != null) {
                session.cookies[knownIndex]["value"] = value
                consumedKnown += knownIndex
            } else {
                val visibleAtRoot = rootObserved.any { it.first == name && it.second == value }
                val observedPath = if (visibleAtRoot) "/" else uri.path.ifBlank { "/" }
                val cookieUrl = origin + observedPath
                if (visibleAtRoot) {
                    session.cookies.removeAll {
                        it["attributesKnown"] == false && it["name"] == name &&
                            it["value"] == value && it["domain"] == uri.host && it["path"] != "/"
                    }
                }
                val existing = session.cookies.firstOrNull {
                    it["attributesKnown"] == false && it["name"] == name && it["cookieUrl"] == cookieUrl
                }
                val record = existing ?: linkedMapOf<String, Any?>(
                    "name" to name,
                    "domain" to uri.host,
                    "path" to observedPath,
                    "secure" to uri.scheme.equals("https", true),
                    "hostOnly" to true,
                    "expiresAt" to null,
                    "cookieUrl" to cookieUrl,
                    "attributesKnown" to false,
                ).also(session.cookies::add)
                record["value"] = value
            }
        }
        val observedNames = observed.mapTo(mutableSetOf()) { it.first }
        session.cookies.removeAll { cookie ->
            cookieApplies(cookie, uri) && cookie["name"]?.toString() !in observedNames
        }
    }

    fun sessionMap(): Map<String, Any?> = session.toPlatformMap()

    fun recordVisitedUrl(url: String?) {
        val origin = url?.let(::normalizedOrigin) ?: return
        synchronized(visitedOrigins) { visitedOrigins += origin }
    }

    fun collectableOrigins(done: (List<String>) -> Unit) {
        WebStorage.getInstance().getOrigins { stored ->
            val origins = linkedSetOf<String>()
            origins += session.localStorage.keys.mapNotNull(::normalizedOrigin)
            synchronized(visitedOrigins) { origins += visitedOrigins }
            stored?.keys?.forEach { raw ->
                if (raw != null) normalizedOrigin(raw.toString())?.let(origins::add)
            }
            done(origins.toList())
        }
    }

    private fun cookieApplies(cookie: Map<String, Any?>, uri: URI): Boolean {
        if (cookie["secure"] == true && !uri.scheme.equals("https", true)) return false
        val domain = cookie["domain"]?.toString()?.trimStart('.')?.lowercase() ?: return false
        val host = uri.host?.lowercase() ?: return false
        val domainMatches = if (cookie["hostOnly"] == true) host == domain else host == domain || host.endsWith(".$domain")
        if (!domainMatches) return false
        val path = cookie["path"]?.toString()?.takeIf { it.startsWith('/') } ?: "/"
        return (uri.path.ifBlank { "/" }).startsWith(path)
    }

    private fun parseCookieHeader(header: String): List<Pair<String, String>> = header.split(';').mapNotNull { part ->
        val separator = part.indexOf('=')
        if (separator <= 0) null else part.substring(0, separator).trim() to part.substring(separator + 1).trim()
    }
}

internal class SourceStorageJavascriptBridge(private val capture: (String) -> Unit) {
    @JavascriptInterface
    fun capture(payload: String) = capture.invoke(payload)
}

internal fun configureSourceBrowserWebView(webView: WebView, headers: Map<String, String>) {
    webView.settings.apply {
        javaScriptEnabled = true
        domStorageEnabled = true
        databaseEnabled = true
        allowFileAccess = false
        allowContentAccess = false
        javaScriptCanOpenWindowsAutomatically = true
        mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
        headers.entries.firstOrNull { it.key.equals("user-agent", true) }
            ?.value?.takeIf { it.isNotBlank() }?.let { userAgentString = it }
    }
    CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)
}

internal fun headersFromJson(raw: String?): Map<String, String> {
    if (raw.isNullOrBlank()) return emptyMap()
    return try {
        val objectValue = JSONObject(raw)
        objectValue.keys().asSequence().associateWith { objectValue.optString(it, "") }
    } catch (_: Exception) {
        emptyMap()
    }
}

internal fun isSafeSourceBrowserUrl(raw: String): Boolean = try {
    val uri = URI(raw)
    (uri.scheme == "http" || uri.scheme == "https") && !uri.host.isNullOrBlank() && uri.userInfo == null
} catch (_: Exception) {
    false
}

internal fun configureSourceBrowserWindow(activity: Activity, root: android.view.View) {
    WindowCompat.setDecorFitsSystemWindows(activity.window, false)
    WindowCompat.getInsetsController(activity.window, root).apply {
        isAppearanceLightStatusBars = true
        isAppearanceLightNavigationBars = true
    }
    ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
        val systemBars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
        view.setPadding(systemBars.left, systemBars.top, systemBars.right, systemBars.bottom)
        insets
    }
    ViewCompat.requestApplyInsets(root)
}

internal fun openExternalSourceBrowserUrl(activity: Activity, webView: WebView, raw: String) {
    try {
        val intent = if (raw.startsWith("intent:", ignoreCase = true)) {
            Intent.parseUri(raw, Intent.URI_INTENT_SCHEME).apply {
                action = Intent.ACTION_VIEW
                addCategory(Intent.CATEGORY_BROWSABLE)
                component = null
                selector = null
                flags = 0
            }
        } else {
            Intent(Intent.ACTION_VIEW, android.net.Uri.parse(raw)).apply {
                addCategory(Intent.CATEGORY_BROWSABLE)
            }
        }
        activity.startActivity(intent)
    } catch (_: ActivityNotFoundException) {
        val fallback = try {
            Intent.parseUri(raw, Intent.URI_INTENT_SCHEME)
                .getStringExtra("browser_fallback_url")
        } catch (_: Exception) {
            null
        }
        if (fallback != null && isSafeSourceBrowserUrl(fallback)) {
            webView.loadUrl(fallback)
        } else {
            Toast.makeText(activity, R.string.source_browser_external_unavailable, Toast.LENGTH_LONG).show()
        }
    } catch (_: Exception) {
        Toast.makeText(activity, R.string.source_browser_external_unavailable, Toast.LENGTH_LONG).show()
    }
}

internal fun platformToJson(value: Any?): String = when (value) {
    is Map<*, *> -> JSONObject(value).toString()
    is List<*> -> JSONArray(value).toString()
    null -> "null"
    else -> JSONObject.wrap(value)?.toString() ?: "null"
}

internal fun jsonToPlatform(value: Any?): Any? = when (value) {
    is JSONObject -> {
        val map = linkedMapOf<String, Any?>()
        value.keys().forEach { key -> map[key] = jsonToPlatform(value.opt(key)) }
        map
    }
    is JSONArray -> MutableList(value.length()) { index -> jsonToPlatform(value.opt(index)) }
    JSONObject.NULL -> null
    else -> value
}

private fun normalizedOrigin(raw: String): String? = try {
    val uri = URI(raw)
    if ((uri.scheme != "http" && uri.scheme != "https") || uri.host.isNullOrBlank()) null
    else "${uri.scheme}://${uri.host}${if (uri.port == -1) "" else ":${uri.port}"}"
} catch (_: Exception) {
    null
}

private fun httpDate(epochMillis: Long): String = SimpleDateFormat(
    "EEE, dd MMM yyyy HH:mm:ss 'GMT'",
    Locale.US,
).apply { timeZone = TimeZone.getTimeZone("GMT") }.format(Date(epochMillis))
