// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.services

import android.app.Activity
import com.aiworkdeck.contract.ContractProduct
import com.aiworkdeck.contract.ContractProducts
import com.aiworkdeck.mobile.design.tr
import java.util.UUID

/** 经契约与 Google Play 商品库求交后的可售充值档位。展示价格只来自 Play 商品库。 */
data class PlayTier(
    val productId: String,
    val amountCents: Int,
    val formattedPrice: String,
)

/** 一笔待确认/待消耗的 Google Play 一次性商品购买。 */
data class UnconsumedPlayPurchase(
    val productId: String,
    val purchaseToken: String,
    val obfuscatedAccountId: String? = null,
    val obfuscatedProfileId: String? = null,
)

sealed interface PlayPurchaseLaunchResult {
    data class Purchased(val purchase: UnconsumedPlayPurchase) : PlayPurchaseLaunchResult
    data object Cancelled : PlayPurchaseLaunchResult
    data object Pending : PlayPurchaseLaunchResult
    data object Failed : PlayPurchaseLaunchResult
}

/** Play Billing 网关抽象；intl 走 Billing Library，cn 为无 GMS 的空实现。 */
interface PlayBillingGateway {
    val supported: Boolean
    suspend fun queryTiers(productIds: List<String>): Map<String, String>
    suspend fun launchPurchase(
        activity: Activity,
        productId: String,
        obfuscatedAccountId: String,
        outTradeNo: String,
    ): PlayPurchaseLaunchResult
    suspend fun queryUnconsumedPurchases(): List<UnconsumedPlayPurchase>
    suspend fun consume(purchaseToken: String): Boolean
}

/** 同一账户同一档位未入账前复用同一把幂等键，防止重复下单。 */
interface PlayIdempotencyStore {
    fun take(scope: String?, productId: String): String
    fun clear(scope: String?, productId: String)
}

class MemoryPlayIdempotencyStore : PlayIdempotencyStore {
    private val map = LinkedHashMap<String, String>()
    override fun take(scope: String?, productId: String): String {
        val key = "${scope.orEmpty()}:$productId"
        return map.getOrPut(key) { UUID.randomUUID().toString() }
    }
    override fun clear(scope: String?, productId: String) {
        map.remove("${scope.orEmpty()}:$productId")
    }
}

sealed interface PlayPurchaseOutcome {
    data class Paid(val status: RechargeStatus) : PlayPurchaseOutcome
    data object PendingLong : PlayPurchaseOutcome
    data object Cancelled : PlayPurchaseOutcome
    data object Failed : PlayPurchaseOutcome
}

/**
 * Google Play 消耗型充值编排器（dev-board#665）：
 * 取交集档位 → 幂等下单取 appAccountToken → 调起 Play 收银台 →
 * 仅在 confirm-googleplay 返回 paid=true 后才 consumeAsync。
 */
class PlayRechargeCoordinator(
    private val backend: Backend,
    private val gateway: PlayBillingGateway,
    private val idempotency: PlayIdempotencyStore,
    private val contractProducts: List<ContractProduct> = ContractProducts.googleplay,
) {
    val isSupported: Boolean get() = gateway.supported

    suspend fun loadTiers(): List<PlayTier> {
        if (!gateway.supported) return emptyList()
        val prices = gateway.queryTiers(contractProducts.map { it.productId })
        return intersectTiers(contractProducts, prices)
    }

    suspend fun createOrder(tier: PlayTier, scope: String?): RechargeOrder {
        return createOrderInternal(tier, scope, retryOnKeyConflict = true)
    }

    private suspend fun createOrderInternal(
        tier: PlayTier,
        scope: String?,
        retryOnKeyConflict: Boolean,
    ): RechargeOrder {
        val key = idempotency.take(scope, tier.productId)
        val order = try {
            backend.billingRecharge(
                amountCents = tier.amountCents.toLong(),
                idempotencyKey = key,
                channel = CHANNEL_GOOGLEPLAY,
                productId = tier.productId,
            )
        } catch (e: ApiError) {
            if (retryOnKeyConflict && (e.kind == EnvelopeKind.ALREADY_PAID || e.kind == EnvelopeKind.IDEMPOTENCY_CONFLICT)) {
                idempotency.clear(scope, tier.productId)
                return createOrderInternal(tier, scope, retryOnKeyConflict = false)
            }
            throw e
        }
        val token = order.appAccountToken?.trim()
        if (order.present != "native" || token.isNullOrEmpty()) {
            throw ApiError(1, tr("recharge.failed"))
        }
        return order
    }

    suspend fun purchase(activity: Activity, tier: PlayTier, scope: String?): PlayPurchaseOutcome {
        val order = createOrder(tier, scope)
        val token = order.appAccountToken ?: throw ApiError(1, tr("recharge.failed"))
        return when (val result = gateway.launchPurchase(activity, tier.productId, token, order.outTradeNo)) {
            is PlayPurchaseLaunchResult.Purchased -> confirmAndConsume(result.purchase, order.outTradeNo, scope)
            PlayPurchaseLaunchResult.Cancelled -> PlayPurchaseOutcome.Cancelled
            PlayPurchaseLaunchResult.Pending -> PlayPurchaseOutcome.PendingLong
            PlayPurchaseLaunchResult.Failed -> PlayPurchaseOutcome.Failed
        }
    }

    /** 先向服务端 confirm-googleplay 验单入账；仅 paid=true 才 consume 并清幂等键。 */
    suspend fun confirmAndConsume(
        purchase: UnconsumedPlayPurchase,
        outTradeNo: String?,
        scope: String?,
    ): PlayPurchaseOutcome {
        val normalizedTradeNo = outTradeNo?.trim()?.takeIf { OUT_TRADE_NO_RE.matches(it) }
        val status = backend.billingConfirmGooglePlay(
            productId = purchase.productId,
            purchaseToken = purchase.purchaseToken,
            outTradeNo = normalizedTradeNo,
        )
        if (!status.paid) return PlayPurchaseOutcome.PendingLong
        gateway.consume(purchase.purchaseToken)
        idempotency.clear(scope, purchase.productId)
        return PlayPurchaseOutcome.Paid(status)
    }

    /** 恢复未消耗购买（进程被杀、网络中断或延时付款批准后的兜底）。返回本次成功入账笔数。 */
    suspend fun replayUnconsumed(scope: String?): Int {
        if (!gateway.supported) return 0
        val knownIds = contractProducts.map { it.productId }.toSet()
        val purchases = try {
            gateway.queryUnconsumedPurchases()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            return 0
        }
        var landed = 0
        for (p in purchases) {
            if (p.productId !in knownIds) continue
            val recoveredTradeNo = p.obfuscatedProfileId?.trim()?.takeIf { OUT_TRADE_NO_RE.matches(it) }
            val settled = tryConfirmForReplay(p, recoveredTradeNo, scope)
            if (settled) landed += 1
        }
        return landed
    }

    private suspend fun tryConfirmForReplay(
        purchase: UnconsumedPlayPurchase,
        outTradeNo: String?,
        scope: String?,
    ): Boolean {
        return try {
            confirmAndConsume(purchase, outTradeNo, scope) is PlayPurchaseOutcome.Paid
        } catch (e: ApiError) {
            // 若携带的 outTradeNo 未命中，再以 null 重试一次让官网凭 obfuscatedExternalAccountId 反查
            if (e.kind == EnvelopeKind.NOT_FOUND && outTradeNo != null) {
                try {
                    confirmAndConsume(purchase, null, scope) is PlayPurchaseOutcome.Paid
                } catch (e2: kotlinx.coroutines.CancellationException) {
                    throw e2
                } catch (_: Exception) {
                    false
                }
            } else {
                false
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            false
        }
    }

    companion object {
        const val CHANNEL_GOOGLEPLAY = "googleplay"
        private val OUT_TRADE_NO_RE = Regex("^[A-Za-z0-9_-]{1,64}$")

        fun intersectTiers(
            contract: List<ContractProduct>,
            storePrices: Map<String, String>,
        ): List<PlayTier> = contract.mapNotNull { product ->
            val price = storePrices[product.productId]?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            PlayTier(product.productId, product.amountCents, price)
        }
    }
}
