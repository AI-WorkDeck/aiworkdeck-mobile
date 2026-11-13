// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile

import android.app.Activity
import com.aiworkdeck.contract.ContractProduct
import com.aiworkdeck.contract.ContractProducts
import com.aiworkdeck.mobile.services.ApiError
import com.aiworkdeck.mobile.services.Backend
import com.aiworkdeck.mobile.services.EnvelopeKind
import com.aiworkdeck.mobile.services.MemoryPlayIdempotencyStore
import com.aiworkdeck.mobile.services.MemorySessionStore
import com.aiworkdeck.mobile.services.PlayBillingGateway
import com.aiworkdeck.mobile.services.PlayPurchaseLaunchResult
import com.aiworkdeck.mobile.services.PlayPurchaseOutcome
import com.aiworkdeck.mobile.services.PlayRechargeCoordinator
import com.aiworkdeck.mobile.services.PlayTier
import com.aiworkdeck.mobile.services.UnconsumedPlayPurchase
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** dev-board#665：Google Play 消耗型内购档位求交、幂等下单、strict paid-before-consume、重放恢复。 */
class PlayRechargeTest {
    private class FakePlayGateway(
        override val supported: Boolean = true,
        private val prices: Map<String, String> = mapOf(
            "credits.usd.10" to "$9.99",
            "credits.usd.20" to "$19.99",
            "credits.usd.50" to "$49.99",
        ),
        private val unconsumed: List<UnconsumedPlayPurchase> = emptyList(),
    ) : PlayBillingGateway {
        val consumedTokens = mutableListOf<String>()

        override suspend fun queryTiers(productIds: List<String>): Map<String, String> = prices
        override suspend fun launchPurchase(
            activity: Activity,
            productId: String,
            obfuscatedAccountId: String,
            outTradeNo: String,
        ): PlayPurchaseLaunchResult = PlayPurchaseLaunchResult.Failed
        override suspend fun queryUnconsumedPurchases(): List<UnconsumedPlayPurchase> = unconsumed
        override suspend fun consume(purchaseToken: String): Boolean {
            consumedTokens.add(purchaseToken)
            return true
        }
    }

    @Test fun intersectsContractProductsInContractOrder() {
        val contract = listOf(
            ContractProduct("credits.usd.10", 1000),
            ContractProduct("credits.usd.20", 2000),
            ContractProduct("credits.usd.50", 5000),
        )
        val tiers = PlayRechargeCoordinator.intersectTiers(
            contract,
            mapOf("credits.usd.50" to "$49.99", "credits.usd.10" to "$9.99", "unknown.sku" to "$1.00"),
        )
        assertEquals(
            listOf(
                PlayTier("credits.usd.10", 1000, "$9.99"),
                PlayTier("credits.usd.50", 5000, "$49.99"),
            ),
            tiers,
        )
        assertEquals(listOf("credits.usd.10", "credits.usd.20", "credits.usd.50"), ContractProducts.googleplay.map { it.productId })
    }

    @Test fun createOrderReusesIdempotencyKeyAndRetriesOnceOnConflict() = runTest {
        val server = MockWebServer().apply { start() }
        try {
            val session = MemorySessionStore().apply { save("sid-1") }
            val backend = Backend(server.url("/").toString().trimEnd('/'), session)
            val idem = MemoryPlayIdempotencyStore()
            val coord = PlayRechargeCoordinator(backend, FakePlayGateway(), idem)
            val tier = PlayTier("credits.usd.10", 1000, "$9.99")

            // 第一次返回 ALREADY_PAID，应清键并重拿一把新键重试一次成功
            server.enqueue(MockResponse().setBody("""{"code":1,"kind":"ALREADY_PAID","message":"已支付"}"""))
            server.enqueue(MockResponse().setBody("""{"present":"native","outTradeNo":"OT-gp-2","amountCents":1000,"appAccountToken":"acct-tok-1"}"""))

            val order = coord.createOrder(tier, "scope-a")
            assertEquals("OT-gp-2", order.outTradeNo)
            assertEquals("acct-tok-1", order.appAccountToken)

            val r1 = server.takeRequest()
            val r2 = server.takeRequest()
            val b1 = r1.body.readUtf8()
            val b2 = r2.body.readUtf8()
            assertEquals("/api/mobile/billing/recharge", r1.path)
            assertTrue(b1.contains(""""channel":"googleplay""""))
            assertTrue(b1.contains(""""productId":"credits.usd.10""""))
            assertNotEquals(b1, b2)

            // 未消耗/取消时应继续复用同一把键
            val sameKey = idem.take("scope-a", "credits.usd.10")
            assertTrue(b2.contains(""""idempotencyKey":"$sameKey""""))
        } finally {
            server.shutdown()
        }
    }

    @Test fun neverConsumesUnlessConfirmReturnsPaidTrue() = runTest {
        val server = MockWebServer().apply { start() }
        try {
            val session = MemorySessionStore().apply { save("sid-1") }
            val backend = Backend(server.url("/").toString().trimEnd('/'), session)
            val gateway = FakePlayGateway()
            val idem = MemoryPlayIdempotencyStore()
            val coord = PlayRechargeCoordinator(backend, gateway, idem)
            val purchase = UnconsumedPlayPurchase("credits.usd.10", "tok-abc", "acct-tok", "OT-gp-1")

            // pending -> paid=false：不 consume，不清幂等键
            idem.take("scope-a", "credits.usd.10")
            server.enqueue(MockResponse().setBody("""{"status":"pending","paid":false,"amountCents":1000}"""))
            val pending = coord.confirmAndConsume(purchase, "OT-gp-1", "scope-a")
            assertTrue(pending is PlayPurchaseOutcome.PendingLong)
            assertTrue(gateway.consumedTokens.isEmpty())

            // paid=true：consume 并清幂等键
            server.enqueue(MockResponse().setBody("""{"status":"paid","paid":true,"amountCents":1000}"""))
            val paid = coord.confirmAndConsume(purchase, "OT-gp-1", "scope-a")
            assertTrue(paid is PlayPurchaseOutcome.Paid)
            assertEquals(listOf("tok-abc"), gateway.consumedTokens)

            val confirmReq = server.takeRequest()
            assertEquals("/api/mobile/billing/recharge/confirm-googleplay", confirmReq.path)
            val reqBody = confirmReq.body.readUtf8()
            assertTrue(reqBody.contains(""""outTradeNo":"OT-gp-1""""))
            assertTrue(reqBody.contains(""""productId":"credits.usd.10""""))
            assertTrue(reqBody.contains(""""purchaseToken":"tok-abc""""))
        } finally {
            server.shutdown()
        }
    }

    @Test fun replayUnconsumedRetriesWithoutOutTradeNoOnNotFound() = runTest {
        val server = MockWebServer().apply { start() }
        try {
            val session = MemorySessionStore().apply { save("sid-1") }
            val backend = Backend(server.url("/").toString().trimEnd('/'), session)
            val gateway = FakePlayGateway(
                unconsumed = listOf(
                    UnconsumedPlayPurchase("credits.usd.20", "tok-rec-1", "acct-tok", "OT-stale"),
                ),
            )
            val coord = PlayRechargeCoordinator(backend, gateway, MemoryPlayIdempotencyStore())

            server.enqueue(MockResponse().setBody("""{"code":1,"kind":"NOT_FOUND","message":"未找到订单"}"""))
            server.enqueue(MockResponse().setBody("""{"status":"paid","paid":true,"amountCents":2000}"""))

            val landed = coord.replayUnconsumed("scope-a")
            assertEquals(1, landed)
            assertEquals(listOf("tok-rec-1"), gateway.consumedTokens)

            val req1 = server.takeRequest().body.readUtf8()
            val req2 = server.takeRequest().body.readUtf8()
            assertTrue(req1.contains(""""outTradeNo":"OT-stale""""))
            assertFalse(req2.contains("outTradeNo"))
        } finally {
            server.shutdown()
        }
    }
}
