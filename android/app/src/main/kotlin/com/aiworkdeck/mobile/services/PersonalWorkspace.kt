// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.services

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

@Serializable data class PersonalStatus(val enabled: Boolean, val subscriptionActive: Boolean, val backupEnabled: Boolean, val summaryCount: Int, val reason: String? = null, val consentEnabled: Boolean? = null)
@Serializable data class PersonalSettings(val enabled: Boolean, val subscriptionActive: Boolean)
@Serializable data class PersonalSource(val deviceId: String, val projectKey: String, val projectName: String, val sourceUpdatedAt: String? = null)
@Serializable data class PersonalReply(val conversationId: String, val requestId: String, val answer: String, val sources: List<PersonalSource> = emptyList(), val status: String = "completed")
@Serializable data class PersonalHistoryMessage(val role: String, val content: String, val requestId: String? = null, val sources: List<PersonalSource> = emptyList())
@Serializable data class PersonalHistory(val conversationId: String, val messages: List<PersonalHistoryMessage> = emptyList())
@Serializable data class PersonalConversation(val conversationId: String? = null, val pending: PersonalQuestion? = null)
@Serializable data class PersonalQuestion(val conversationId: String? = null, val message: String, val requestId: String = UUID.randomUUID().toString())
@Serializable data class PersonalCalendarFile(val fileId: JsonElement, val fileName: String)
@Serializable data class PersonalCalendarEvent(val id: String, val deviceId: String, val projectKey: String, val projectUid: String? = null,
    val projectName: String, val title: String, val dueDate: String, val dueTime: String? = null, val timeZone: String,
    val remindAt: String? = null, val status: String, val updatedAt: String? = null, val files: List<PersonalCalendarFile> = emptyList()) {
    val projectIdentity: String get() = projectUid ?: "$deviceId:$projectKey"
    val reminder: Instant? get() = runCatching { Instant.parse(remindAt) }.getOrNull()
    fun within(days: Int, now: Instant = Instant.now()): Boolean = runCatching {
        val date = LocalDate.parse(dueDate)
        val today = now.atZone(ZoneId.of(timeZone)).toLocalDate()
        status == "OPEN" && !date.isBefore(today) && date.isBefore(today.plusDays(days.toLong()))
    }.getOrDefault(false)
}
@Serializable data class PersonalCalendar(val enabled: Boolean, val subscriptionActive: Boolean, val events: List<PersonalCalendarEvent> = emptyList(), val syncedAt: String? = null)

fun reminderEvents(events: List<PersonalCalendarEvent>, now: Instant = Instant.now()): List<PersonalCalendarEvent> =
    events.filter { it.status == "OPEN" && it.reminder?.isAfter(now) == true }.sortedBy { it.reminder }.take(50)
