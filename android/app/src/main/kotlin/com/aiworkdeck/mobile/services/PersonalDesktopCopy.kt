// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.services

import com.aiworkdeck.mobile.model.ProjectLocation
import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.design.tr
import kotlinx.serialization.Serializable
import java.util.UUID

private fun copyUuid(value: String?): Boolean = value != null && runCatching { UUID.fromString(value).toString().equals(value, ignoreCase = true) }.getOrDefault(false)
data class PersonalCopyDestination(val project: RelayProject, val desktop: ProjectLocation? = null) {
    val id: String get() = desktop?.let { "desktop:${it.deviceId}:${it.key}" } ?: "cloud:${personalCopyTarget(project)}"
    val label: String get() = project.name + " · " + (desktop?.let { it.deviceName ?: it.deviceId } ?: tr("personal.copy.cloud"))
    companion object {
        fun eligible(location: ProjectLocation): Boolean = location.kind == "desktop" && location.archiveOnly != true && location.owned == true &&
            copyUuid(location.projectUid) && !location.projectType.isNullOrBlank() && location.projectType !in setOf("SCRATCH", "LOOSE_FILES")
        fun targets(projects: List<RelayProject>): List<PersonalCopyDestination> = projects.flatMap { project ->
            buildList { if (personalCopyTarget(project) != null) add(PersonalCopyDestination(project))
                if (!project.isDefault) project.locations.orEmpty().filter(::eligible).forEach { add(PersonalCopyDestination(project, it)) } }
        }
        fun needsUpgrade(projects: List<RelayProject>): Boolean = projects.any { project -> project.locations.orEmpty().any {
            it.kind == "desktop" && (it.owned == null || it.projectType.isNullOrBlank() || !copyUuid(it.projectUid))
        } }
    }
}
@Serializable data class DesktopCopyRequest(val requestId: String = UUID.randomUUID().toString(), val sourceConversationId: String,
    val targetProjectUid: String, val targetDeviceId: String, val targetProjectKey: String)
@Serializable data class DesktopCopyReceipt(val requestId: String, val status: String, val sourcePreserved: Boolean, val filesCopied: Boolean,
    val sourceConversationId: String, val conversationId: String, val targetProjectUid: String, val targetDeviceId: String,
    val targetProjectKey: String, val messageCount: Int, val expiresAt: String, val error: String? = null, val deliveredAt: String? = null) {
    val terminal: Boolean get() = status in setOf("DELIVERED", "FAILED", "EXPIRED")
    val request: DesktopCopyRequest get() = DesktopCopyRequest(requestId, sourceConversationId, targetProjectUid, targetDeviceId, targetProjectKey)
    fun validate(expected: DesktopCopyRequest) {
        check(request == expected && copyUuid(requestId) && copyUuid(sourceConversationId) && copyUuid(targetProjectUid) && copyUuid(conversationId) &&
            sourcePreserved && !filesCopied && messageCount >= 0 && status in setOf("QUEUED", "DELIVERED", "FAILED", "EXPIRED") &&
            runCatching { java.time.Instant.parse(expiresAt) }.isSuccess) { tr("error.badResponse") }
    }
}
@Serializable data class PersonalDesktopCopy(val request: DesktopCopyRequest, val receipt: DesktopCopyReceipt? = null) {
    val statusKey: String get() = "personal.copy." + when(receipt?.status) { "QUEUED" -> "queued"; "DELIVERED" -> "delivered"; "FAILED" -> "failed"; "EXPIRED" -> "expired"; else -> "unknown" }
    val canRetry: Boolean get() = receipt == null || receipt.status in setOf("FAILED", "EXPIRED")
}
