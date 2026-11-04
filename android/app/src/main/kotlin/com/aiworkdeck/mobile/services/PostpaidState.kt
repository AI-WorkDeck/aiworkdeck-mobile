// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.services
import kotlinx.serialization.Serializable

@Serializable data class PostpaidState(val billing: PostpaidBilling, val cloudAccess: CloudAccess)
@Serializable data class PostpaidBilling(
    val policyVersion: String, val accepted: Boolean, val acceptEnabled: Boolean, val unit: String,
    val cashCurrency: String, val creditLimitCents: Long, val debtCents: Long,
    val reservedCreditCents: Long, val availableCreditCents: Long,
    val overLimitAt: String? = null, val remindAt: String? = null, val cleanupAt: String? = null,
    val storagePrice: StoragePrice, val egressPrice: EgressPrice? = null,
)
@Serializable data class StoragePrice(val cashCentsPerGiBMonth: Long, val cashCurrency: String, val periodSeconds: Long, val gibBytes: Long)
@Serializable data class EgressPrice(val cashCentsPerGiB: Long, val cashCurrency: String, val gibBytes: Long)
