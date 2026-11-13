// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.services

import android.app.Activity
import android.content.Context
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.ConsumeParams
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import com.android.billingclient.api.consumePurchase
import com.android.billingclient.api.queryProductDetails
import com.android.billingclient.api.queryPurchasesAsync
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

fun createPlayBillingGateway(context: Context, onAsyncPurchase: () -> Unit): PlayBillingGateway =
    AndroidPlayBillingGateway(context.applicationContext, onAsyncPurchase)

private class AndroidPlayBillingGateway(
    context: Context,
    private val onAsyncPurchase: () -> Unit,
) : PlayBillingGateway {
    override val supported: Boolean = true

    private val connectMutex = Mutex()
    private val productsCache = LinkedHashMap<String, ProductDetails>()
    private var pendingPurchaseDeferred: CompletableDeferred<PlayPurchaseLaunchResult>? = null

    private val listener = PurchasesUpdatedListener { billingResult, purchases ->
        val deferred = pendingPurchaseDeferred
        if (deferred != null && !deferred.isCompleted) {
            pendingPurchaseDeferred = null
            deferred.complete(mapUpdateResult(billingResult, purchases))
        } else if (billingResult.responseCode == BillingClient.BillingResponseCode.OK &&
            purchases.orEmpty().any { it.purchaseState == Purchase.PurchaseState.PURCHASED }
        ) {
            onAsyncPurchase()
        }
    }

    private val client: BillingClient = BillingClient.newBuilder(context)
        .setListener(listener)
        .enablePendingPurchases(
            PendingPurchasesParams.newBuilder()
                .enableOneTimeProducts()
                .build()
        )
        .enableAutoServiceReconnection()
        .build()

    private suspend fun ensureConnected(): Boolean {
        if (client.isReady) return true
        return connectMutex.withLock {
            if (client.isReady) return@withLock true
            val signal = CompletableDeferred<Boolean>()
            client.startConnection(object : BillingClientStateListener {
                override fun onBillingSetupFinished(result: BillingResult) {
                    if (!signal.isCompleted) {
                        signal.complete(result.responseCode == BillingClient.BillingResponseCode.OK)
                    }
                }
                override fun onBillingServiceDisconnected() {
                    if (!signal.isCompleted) signal.complete(false)
                }
            })
            withTimeoutOrNull(15_000) { signal.await() } ?: false
        }
    }

    override suspend fun queryTiers(productIds: List<String>): Map<String, String> {
        if (productIds.isEmpty() || !ensureConnected()) return emptyMap()
        val products = productIds.map { id ->
            QueryProductDetailsParams.Product.newBuilder()
                .setProductId(id)
                .setProductType(BillingClient.ProductType.INAPP)
                .build()
        }
        val params = QueryProductDetailsParams.newBuilder().setProductList(products).build()
        val result = client.queryProductDetails(params)
        if (result.billingResult.responseCode != BillingClient.BillingResponseCode.OK) {
            return emptyMap()
        }
        val map = LinkedHashMap<String, String>()
        for (details in result.productDetailsList.orEmpty()) {
            val formatted = details.oneTimePurchaseOfferDetailsList
                ?.firstOrNull()
                ?.formattedPrice
                ?: details.oneTimePurchaseOfferDetails?.formattedPrice
                ?: continue
            productsCache[details.productId] = details
            map[details.productId] = formatted
        }
        return map
    }

    override suspend fun launchPurchase(
        activity: Activity,
        productId: String,
        obfuscatedAccountId: String,
        outTradeNo: String,
    ): PlayPurchaseLaunchResult {
        if (!ensureConnected()) return PlayPurchaseLaunchResult.Failed
        val details = productsCache[productId] ?: run {
            queryTiers(listOf(productId))
            productsCache[productId]
        } ?: return PlayPurchaseLaunchResult.Failed

        val offerToken = details.oneTimePurchaseOfferDetailsList?.firstOrNull()?.offerToken
            ?: details.oneTimePurchaseOfferDetails?.offerToken
        val productParams = BillingFlowParams.ProductDetailsParams.newBuilder()
            .setProductDetails(details)
            .apply { if (!offerToken.isNullOrEmpty()) setOfferToken(offerToken) }
            .build()
        val flowParams = BillingFlowParams.newBuilder()
            .setProductDetailsParamsList(listOf(productParams))
            .setObfuscatedAccountId(obfuscatedAccountId)
            .setObfuscatedProfileId(outTradeNo)
            .build()

        val deferred = CompletableDeferred<PlayPurchaseLaunchResult>()
        pendingPurchaseDeferred = deferred
        val launchResult = withContext(Dispatchers.Main) {
            client.launchBillingFlow(activity, flowParams)
        }
        if (launchResult.responseCode != BillingClient.BillingResponseCode.OK) {
            pendingPurchaseDeferred = null
            return if (launchResult.responseCode == BillingClient.BillingResponseCode.USER_CANCELED) {
                PlayPurchaseLaunchResult.Cancelled
            } else {
                PlayPurchaseLaunchResult.Failed
            }
        }
        return deferred.await()
    }

    override suspend fun queryUnconsumedPurchases(): List<UnconsumedPlayPurchase> {
        if (!ensureConnected()) return emptyList()
        val params = QueryPurchasesParams.newBuilder()
            .setProductType(BillingClient.ProductType.INAPP)
            .build()
        val result = client.queryPurchasesAsync(params)
        if (result.billingResult.responseCode != BillingClient.BillingResponseCode.OK) {
            return emptyList()
        }
        return result.purchasesList
            .filter { it.purchaseState == Purchase.PurchaseState.PURCHASED }
            .mapNotNull { it.toUnconsumedOrNull() }
    }

    override suspend fun consume(purchaseToken: String): Boolean {
        if (!ensureConnected()) return false
        val params = ConsumeParams.newBuilder().setPurchaseToken(purchaseToken).build()
        val result = client.consumePurchase(params)
        return result.billingResult.responseCode == BillingClient.BillingResponseCode.OK
    }

    private fun mapUpdateResult(result: BillingResult, purchases: List<Purchase>?): PlayPurchaseLaunchResult {
        return when (result.responseCode) {
            BillingClient.BillingResponseCode.USER_CANCELED -> PlayPurchaseLaunchResult.Cancelled
            BillingClient.BillingResponseCode.OK -> {
                val list = purchases.orEmpty()
                val purchased = list.firstOrNull { it.purchaseState == Purchase.PurchaseState.PURCHASED }
                    ?.toUnconsumedOrNull()
                when {
                    purchased != null -> PlayPurchaseLaunchResult.Purchased(purchased)
                    list.any { it.purchaseState == Purchase.PurchaseState.PENDING } -> PlayPurchaseLaunchResult.Pending
                    else -> PlayPurchaseLaunchResult.Failed
                }
            }
            else -> PlayPurchaseLaunchResult.Failed
        }
    }

    private fun Purchase.toUnconsumedOrNull(): UnconsumedPlayPurchase? {
        val productId = products.firstOrNull()?.takeIf { it.isNotBlank() } ?: return null
        val token = purchaseToken.takeIf { it.isNotBlank() } ?: return null
        return UnconsumedPlayPurchase(
            productId = productId,
            purchaseToken = token,
            obfuscatedAccountId = accountIdentifiers?.obfuscatedAccountId,
            obfuscatedProfileId = accountIdentifiers?.obfuscatedProfileId,
        )
    }
}
