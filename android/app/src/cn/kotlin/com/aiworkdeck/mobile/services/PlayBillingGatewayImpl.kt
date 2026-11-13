// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.services

import android.app.Activity
import android.content.Context

fun createPlayBillingGateway(context: Context, onAsyncPurchase: () -> Unit): PlayBillingGateway =
    NoOpPlayBillingGateway

private object NoOpPlayBillingGateway : PlayBillingGateway {
    override val supported: Boolean = false
    override suspend fun queryTiers(productIds: List<String>): Map<String, String> = emptyMap()
    override suspend fun launchPurchase(
        activity: Activity,
        productId: String,
        obfuscatedAccountId: String,
        outTradeNo: String,
    ): PlayPurchaseLaunchResult = PlayPurchaseLaunchResult.Failed
    override suspend fun queryUnconsumedPurchases(): List<UnconsumedPlayPurchase> = emptyList()
    override suspend fun consume(purchaseToken: String): Boolean = false
}
