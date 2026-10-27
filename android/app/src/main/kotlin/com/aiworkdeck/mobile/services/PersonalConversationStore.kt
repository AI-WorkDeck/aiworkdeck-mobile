// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.services

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Only the latest conversation and unfinished input are retained; credentials are never stored here. */
class PersonalConversationStore(
    private val currentScope: () -> String?,
    private val read: () -> String?,
    private val write: (String?) -> Unit,
) {
    @Serializable private data class Saved(val scope: String, val conversation: PersonalConversation)
    private val scope = currentScope()
    private val revision = generation
    private val json = Json { ignoreUnknownKeys = true }
    fun isCurrent(): Boolean = scope != null && scope == currentScope() && revision == generation
    fun load(): PersonalConversation {
        if (!isCurrent()) return PersonalConversation()
        val saved = runCatching { json.decodeFromString<Saved>(read().orEmpty()) }.getOrNull()
        if (saved == null || saved.scope != scope) { write(null); return PersonalConversation() }
        return saved.conversation
    }
    fun save(value: PersonalConversation): Boolean {
        if (!isCurrent()) return false
        write(json.encodeToString(Saved(scope!!, value)))
        return true
    }
    companion object {
        private var generation = 0L
        private const val FILE = "personal-conversation"
        fun open(context: Context, backend: Backend): PersonalConversationStore {
            val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
            return PersonalConversationStore(backend::personalAccountScope, { prefs.getString("latest", null) }, {
                prefs.edit().apply { if (it == null) remove("latest") else putString("latest", it) }.commit()
            })
        }
        fun clear(context: Context) { invalidate(); context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit().clear().commit() }
        internal fun invalidate() { generation++ }
    }
}

fun personalSourceDate(value: String?): String = runCatching {
    java.time.format.DateTimeFormatter.ofLocalizedDateTime(java.time.format.FormatStyle.SHORT)
        .withLocale(java.util.Locale.forLanguageTag(com.aiworkdeck.mobile.design.L10n.locale)).withZone(java.time.ZoneId.systemDefault()).format(java.time.Instant.parse(value))
}.getOrDefault("")
