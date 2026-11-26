// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.services

import android.content.Context
import com.aiworkdeck.mobile.BuildConfig
import okhttp3.OkHttpClient
import java.io.File
import java.security.KeyStore
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import javax.net.ssl.X509ExtendedTrustManager
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLSocket
import java.net.Socket

/**
 * Debug builds only: point account traffic at a staging server on this device's loopback instead of production
 * (POLISH M38). On a real phone, `adb reverse tcp:18044 tcp:18044` carries it to the lane Mac's tunnel to staging:
 *
 *   adb shell am start -n <pkg>/com.aiworkdeck.mobile.MainActivity --es awdAccountBase https://localhost:18044
 *
 * `--es awdAccountBase ""` goes back to the region's host. Only https on localhost / 127.0.0.1 is accepted, so the
 * override can never send a session anywhere else. The staging CA is not in the repo: copy it to
 * `files/awd-staging-ca.pem` with `run-as`; it is trusted for those two hosts only, in addition to the system CAs.
 * Release builds ignore all of this.
 */
object DebugAccountBase {
    const val EXTRA = "awdAccountBase"
    const val CA_FILE = "awd-staging-ca.pem"
    private const val PREFS = "debugAccountBase"
    private val LOOPBACK = setOf("localhost", "127.0.0.1")

    @Volatile var base: String? = null
        private set

    /** A valid override (https, loopback host, no path) normalised without a trailing slash, else null. */
    fun parse(raw: String?): String? {
        val url = raw?.trim()?.removeSuffix("/")?.takeIf { it.isNotEmpty() } ?: return null
        val uri = runCatching { java.net.URI(url) }.getOrNull() ?: return null
        if (uri.scheme != "https" || uri.host !in LOOPBACK || !uri.path.isNullOrEmpty() || uri.query != null) return null
        return url
    }

    /** App start: restore the override saved by an earlier launch. */
    fun load(context: Context, debug: Boolean = BuildConfig.DEBUG) {
        if (!debug) return
        base = parse(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("base", null))
    }

    /**
     * Launch extra: absent = keep; "" = clear; otherwise set if valid. Returns true when the host changed, so the
     * caller drops the session that belonged to the other server.
     */
    fun apply(context: Context, extra: String?, debug: Boolean = BuildConfig.DEBUG): Boolean {
        if (!debug || extra == null) return false
        val next = parse(extra)
        if (next == null && extra.isNotBlank()) return false
        if (next == base) return false
        base = next
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("base", next).apply()
        return true
    }

    /** Debug builds with a staging CA file: a client that also trusts it for loopback hosts. Otherwise the default. */
    fun client(filesDir: File, debug: Boolean = BuildConfig.DEBUG): OkHttpClient {
        val ca = File(filesDir, CA_FILE)
        if (!debug || !ca.isFile) return OkHttpClient()
        val cert = ca.inputStream().use { CertificateFactory.getInstance("X.509").generateCertificate(it) as X509Certificate }
        val system = trustManager(null)
        val staging = trustManager(KeyStore.getInstance(KeyStore.getDefaultType()).apply { load(null, null); setCertificateEntry("awd-staging", cert) })
        // The staging CA counts only when the peer is a loopback host; everything else must pass the system CAs.
        val tm = object : X509ExtendedTrustManager() {
            private fun check(chain: Array<X509Certificate>, authType: String, host: String?) {
                try { system.checkServerTrusted(chain, authType) } catch (e: CertificateException) {
                    if (host !in LOOPBACK) throw e
                    staging.checkServerTrusted(chain, authType)
                }
            }
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String, socket: Socket?) =
                check(chain, authType, (socket as? SSLSocket)?.handshakeSession?.peerHost)
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String, engine: SSLEngine?) =
                check(chain, authType, engine?.peerHost)
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) = check(chain, authType, null)
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String, socket: Socket?) = system.checkClientTrusted(chain, authType)
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String, engine: SSLEngine?) = system.checkClientTrusted(chain, authType)
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = system.checkClientTrusted(chain, authType)
            override fun getAcceptedIssuers(): Array<X509Certificate> = system.acceptedIssuers
        }
        val ssl = SSLContext.getInstance("TLS").apply { init(null, arrayOf(tm), null) }
        return OkHttpClient.Builder().sslSocketFactory(ssl.socketFactory, tm).build()
    }

    private fun trustManager(store: KeyStore?): X509TrustManager =
        TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(store) }
            .trustManagers.filterIsInstance<X509TrustManager>().first()
}
