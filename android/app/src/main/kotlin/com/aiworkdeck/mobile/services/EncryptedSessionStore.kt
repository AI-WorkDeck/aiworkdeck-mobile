package com.aiworkdeck.mobile.services

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/** 加密会话存储：EncryptedSharedPreferences 文件 "session"，键 "sessionId"。仅此文件依赖 Android，不参与 JVM 单测。 */
class EncryptedSessionStore(context: Context) : SessionStore {
    private val prefs = EncryptedSharedPreferences.create(
        context,
        "session",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    override fun current(): String? = prefs.getString(KEY, null)
    /** commit 同步落盘并读回核对：apply 的失败是静默的，登录会「成功」进一个重启即丢的会话。 */
    override fun save(id: String) {
        val written = runCatching { prefs.edit().putString(KEY, id).commit() }.getOrDefault(false)
        if (!written || runCatching { prefs.getString(KEY, null) }.getOrNull() != id) throw SessionSaveFailed()
    }
    override fun clear() { prefs.edit().remove(KEY).apply() }

    private companion object { const val KEY = "sessionId" }
}
