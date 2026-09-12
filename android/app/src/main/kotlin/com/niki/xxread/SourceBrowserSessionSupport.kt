package com.niki.xxread

import android.os.Build
import android.webkit.CookieManager
import android.webkit.WebStorage
import android.webkit.WebView
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.net.URI
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

internal object SourceBrowserSessionRuntime {
    private var owner: String? = null

    @Synchronized
    fun acquire(candidate: String): Boolean {
        if (owner != null) return false
        owner = candidate
        return true
    }

    @Synchronized
    fun release(candidate: String) {
        if (owner == candidate) owner = null
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
    private val visitedUrls = linkedSetOf<String>()

    fun restoreCookies(done: () -> Unit) {
        val manager = CookieManager.getInstance()
        manager.setAcceptCookie(true)
        val restorable = session.cookies.mapNotNull { cookie ->
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
                (cookie["expiresAt"] as? Number)?.toLong()?.let { expiresAt ->
                    append("; Expires=").append(httpDate(expiresAt))
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
        val encoded = JSONObject(values).toString()
        return """<!doctype html><meta charset=\"utf-8\"><script>
            try {
              var values = $encoded;
              Object.keys(values).forEach(function(key) { localStorage.setItem(key, String(values[key])); });
            } catch (_) {}
        </script>""".trimIndent()
    }

    fun captureStorageScript(): String = """
        (function() {
          var values = {};
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
            val payload = JSONObject(raw)
            val origin = normalizedOrigin(payload.optString("origin")) ?: return
            val valuesObject = payload.optJSONObject("values") ?: return
            val values = linkedMapOf<String, String>()
            valuesObject.keys().forEach { key -> values[key] = valuesObject.optString(key, "") }
            session.localStorage[origin] = values
        } catch (_: Exception) {
        }
    }

    fun observeCookies(url: String?) {
        if (url.isNullOrBlank() || (!url.startsWith("http://") && !url.startsWith("https://"))) return
        visitedUrls += url
        val header = CookieManager.getInstance().getCookie(url) ?: return
        val uri = try { URI(url) } catch (_: Exception) { return }
        val observed = header.split(';').mapNotNull { part ->
            val separator = part.indexOf('=')
            if (separator <= 0) null else part.substring(0, separator).trim() to part.substring(separator + 1).trim()
        }
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
                val origin = "${uri.scheme}://${uri.host}${if (uri.port == -1) "" else ":${uri.port}"}"
                val existing = session.cookies.firstOrNull {
                    it["attributesKnown"] == false && it["name"] == name && it["cookieUrl"] == origin + "/"
                }
                val record = existing ?: linkedMapOf<String, Any?>(
                    "name" to name,
                    "domain" to uri.host,
                    "path" to "/",
                    "secure" to uri.scheme.equals("https", true),
                    "hostOnly" to true,
                    "expiresAt" to null,
                    "cookieUrl" to origin + "/",
                    "attributesKnown" to false,
                ).also(session.cookies::add)
                record["value"] = value
            }
        }
    }

    fun sessionMap(): Map<String, Any?> = session.toPlatformMap()

    private fun cookieApplies(cookie: Map<String, Any?>, uri: URI): Boolean {
        val domain = cookie["domain"]?.toString()?.trimStart('.')?.lowercase() ?: return false
        val host = uri.host?.lowercase() ?: return false
        val domainMatches = if (cookie["hostOnly"] == true) host == domain else host == domain || host.endsWith(".$domain")
        if (!domainMatches) return false
        val path = cookie["path"]?.toString()?.takeIf { it.startsWith('/') } ?: "/"
        return (uri.path.ifBlank { "/" }).startsWith(path)
    }
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

internal fun platformToJson(value: Any?): String = when (value) {
    is Map<*, *> -> JSONObject(value).toString()
    is List<*> -> JSONArray(value).toString()
    null -> "null"
    else -> JSONObject.wrap(value).toString()
}

private fun jsonToPlatform(value: Any?): Any? = when (value) {
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
