// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.services.firm

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/** Trial codes in their own encrypted file "firm-trial", written with commit() and read back (like the session). */
class EncryptedFirmTrialStore(context: Context) : FirmTrialStore {
    private val prefs = runCatching {
        EncryptedSharedPreferences.create(
            context, "firm-trial",
            MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }.getOrNull()

    override fun read(account: String): String? = runCatching { prefs?.getString(account, null) }.getOrNull()
    /** False when the encrypted store is unusable (e.g. after a device restore): joining then fails instead of sending the session. */
    override fun save(account: String, code: String): Boolean {
        val p = prefs ?: return false
        val written = runCatching { p.edit().putString(account, code).commit() }.getOrDefault(false)
        return written && read(account) == code
    }
    override fun clear(account: String) { runCatching { prefs?.edit()?.remove(account)?.commit() } }
}

class SharedPrefsFirmSettings(context: Context) : FirmSettings {
    private val prefs = context.getSharedPreferences("firm", Context.MODE_PRIVATE)
    override fun links(key: String): List<String> = prefs.getString(key, null)?.split("\n")?.filter { it.isNotEmpty() } ?: emptyList()
    override fun setLinks(key: String, value: List<String>) {
        prefs.edit().apply { if (value.isEmpty()) remove(key) else putString(key, value.joinToString("\n")) }.apply()
    }
    override fun string(key: String): String? = prefs.getString(key, null)
    override fun setString(key: String, value: String?) { prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply() }
}
