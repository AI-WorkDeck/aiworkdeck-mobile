// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.services

import kotlinx.serialization.Serializable

@Serializable data class CloudAccess(
    val canUse: Boolean, val canWrite: Boolean, val canRead: Boolean,
    val reason: String, val epoch: Long? = null, val includedStorageBytes: Long? = null,
    val caseId: String? = null, val cleanupEligible: Boolean? = null,
    val notificationStatus: String? = null, val frozen: Boolean? = null, val cleanupState: String? = null,
)
