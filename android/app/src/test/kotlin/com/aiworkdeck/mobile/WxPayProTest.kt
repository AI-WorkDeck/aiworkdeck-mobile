package com.aiworkdeck.mobile

import com.aiworkdeck.contract.ContractCapabilities
import com.aiworkdeck.mobile.features.settings.proUnavailableKey
import com.aiworkdeck.mobile.services.AccountRegion
import com.aiworkdeck.mobile.services.ApiError
import com.aiworkdeck.mobile.services.Backend
import com.aiworkdeck.mobile.services.EnvelopeKind
import com.aiworkdeck.mobile.services.MemorySessionStore
import com.aiworkdeck.mobile.services.PendingRechargeStore
import com.aiworkdeck.mobile.services.RechargeResult
import com.aiworkdeck.mobile.services.WxPayOutcome
import com.aiworkdeck.mobile.services.WxPayRecharge
import com.aiworkdeck.mobile.services.proRechargeApi
import com.aiworkdeck.mobile.services.showsWxpayPro
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/** Personal Pro with WeChat APP pay on Android cn (POLISH M3): wire shapes, gating, WxPayRecharge reuse. */
class WxPayProTest {
    private lateinit var server: MockWebServer
    private lateinit var backend: Backend

    @Before fun setUp() {
        server = MockWebServer(); server.start()
        backend = Backend(server.url("/").toString().trimEnd('/'), MemorySessionStore().also { it.save("s1") })
    }

    @After fun tearDown() { server.shutdown() }

    private class Disk(var value: String? = null) { var writes = 0 }
    private fun store(disk: Disk, key: String) = PendingRechargeStore({ disk.value }, { disk.value = it; disk.writes++ }, { key })

    private val appOrder = """{"present":"app","outTradeNo":"PRO-1","amountCents":990,"skuId":"pro_monthly_intro",
        "appId":"wxapp","partnerId":"1900000109","prepayId":"wx201410272009395522657a690389285100",
        "packageValue":"Sign=WXPay","nonceStr":"n0nce","timeStamp":"1700000000","sign":"SIGN"}"""

    // ---- gating ----

    @Test fun `Pro sheet only in the cn build, mainland account, flag on`() {
        assertTrue(showsWxpayPro("cn", AccountRegion.cn, enabled = true))
        assertFalse("flag off", showsWxpayPro("cn", AccountRegion.cn, enabled = false))
        assertFalse("intl account in cn build", showsWxpayPro("cn", AccountRegion.intl, enabled = true))
        for (r in AccountRegion.entries) assertFalse("Play build never", showsWxpayPro("intl", r, enabled = true))
        // Ships dark: the contract flag defaults to false
        assertFalse(ContractCapabilities.androidWxpayPro)
        assertFalse(showsWxpayPro("cn", AccountRegion.cn))
    }

    @Test fun `unavailable reasons map to a short line`() {
        assertEquals("subscription.wxpay.appleActive", proUnavailableKey("appstore_subscription_active"))
        assertEquals("subscription.store.closed", proUnavailableKey("disabled"))
        assertEquals("subscription.store.closed", proUnavailableKey("channel_unavailable"))
        assertEquals("subscription.store.closed", proUnavailableKey(null))
        assertEquals("recharge.openHint", proUnavailableKey("not_connected"))
    }

    // ---- wire shapes ----

    @Test fun quoteParsesAvailableShape() = runTest {
        server.enqueue(MockResponse().setBody("""{"available":true,"skuId":"pro_monthly_intro","amountCents":990,"standardAmountCents":14900,"introEligible":true,"introRemainingMonths":3,"days":30}"""))
        val q = backend.billingProQuote()
        assertTrue(q.available)
        assertEquals("pro_monthly_intro", q.skuId)
        assertEquals(990L, q.amountCents)
        assertEquals(14900L, q.standardAmountCents)
        assertTrue(q.introEligible)
        assertEquals(3, q.introRemainingMonths)
        assertEquals(30, q.days)
        assertNull(q.reason)
        val req = server.takeRequest()
        assertEquals("GET", req.method)
        assertEquals("/api/mobile/billing/subscription/wxpay/quote", req.path)
        assertEquals("s1", req.getHeader("X-Session-Id"))
    }

    @Test fun quoteParsesUnavailableShape() = runTest {
        for (reason in listOf("disabled", "channel_unavailable", "appstore_subscription_active", "not_connected")) {
            server.enqueue(MockResponse().setBody("""{"available":false,"reason":"$reason"}"""))
            val q = backend.billingProQuote()
            assertFalse(q.available)
            assertEquals(reason, q.reason)
            assertNull(q.skuId)
        }
    }

    @Test fun quoteEnvelopeErrorThrowsWithKind() = runTest {
        server.enqueue(MockResponse().setBody("""{"code":1,"message":"Busy","kind":"UNAVAILABLE"}"""))
        val e = runCatching { backend.billingProQuote() }.exceptionOrNull() as ApiError
        assertEquals(EnvelopeKind.UNAVAILABLE, e.kind)
    }

    @Test fun orderPostsSkuAmountKeyAndParsesAppPay() = runTest {
        server.enqueue(MockResponse().setBody(appOrder))
        val order = backend.billingProOrder("pro_monthly_intro", 990, "idem-key-pro-0001")
        assertEquals("PRO-1", order.outTradeNo)
        assertEquals(990L, order.amountCents)
        assertNotNull(order.appPayParams())
        val req = server.takeRequest()
        assertEquals("POST", req.method)
        assertEquals("/api/mobile/billing/subscription/wxpay/order", req.path)
        val body = Json.parseToJsonElement(req.body.readUtf8()).jsonObject
        assertEquals(setOf("skuId", "amountCents", "idempotencyKey"), body.keys)
        assertEquals("pro_monthly_intro", body["skuId"]!!.jsonPrimitive.content)
        assertEquals(990L, body["amountCents"]!!.jsonPrimitive.long)
        assertEquals("idem-key-pro-0001", body["idempotencyKey"]!!.jsonPrimitive.content)
    }

    @Test fun orderErrorsKeepKindAndOutTradeNo() = runTest {
        server.enqueue(MockResponse().setBody("""{"code":1,"message":"Price changed","kind":"REJECTED"}"""))
        assertEquals(EnvelopeKind.REJECTED, (runCatching { backend.billingProOrder("pro_monthly", 14900, "k") }.exceptionOrNull() as ApiError).kind)
        server.enqueue(MockResponse().setBody("""{"code":1,"message":"Paid","kind":"ALREADY_PAID","outTradeNo":"PRO-0"}"""))
        val paid = runCatching { backend.billingProOrder("pro_monthly", 14900, "k") }.exceptionOrNull() as ApiError
        assertEquals(EnvelopeKind.ALREADY_PAID, paid.kind)
        assertEquals("PRO-0", paid.outTradeNo)
    }

    // ---- WxPayRecharge reuse ----

    @Test fun proPurchaseGoesThroughWxPayRechargeWithProStoreAndQuotedSku() = runTest {
        val proDisk = Disk()
        server.enqueue(MockResponse().setBody(appOrder))
        server.enqueue(MockResponse().setBody("""{"status":"paid","paid":true,"amountCents":990}"""))
        var launched: String? = null
        val flow = WxPayRecharge(proRechargeApi(backend, "pro_monthly_intro"), store(proDisk, "pro-key-0001"), "acct",
            pay = { launched = it.prepayId; WxPayOutcome.SUCCESS }, sleep = {})

        assertEquals(RechargeResult.Paid, flow.purchase(990))

        val order = server.takeRequest()
        assertEquals("/api/mobile/billing/subscription/wxpay/order", order.path)
        val body = Json.parseToJsonElement(order.body.readUtf8()).jsonObject
        assertEquals("pro_monthly_intro", body["skuId"]!!.jsonPrimitive.content)
        assertEquals("pro-key-0001", body["idempotencyKey"]!!.jsonPrimitive.content)
        assertEquals("/api/mobile/billing/recharge/status?outTradeNo=PRO-1", server.takeRequest().path)
        assertEquals("wx201410272009395522657a690389285100", launched)
        assertTrue("key persisted in the Pro slot before the request", proDisk.writes >= 2)
        assertNull("Pro slot cleared once paid", proDisk.value)
    }

    @Test fun cancelledProPurchaseKeepsKeyAndOrderInProSlot() = runTest {
        val proDisk = Disk()
        server.enqueue(MockResponse().setBody(appOrder))
        val flow = WxPayRecharge(proRechargeApi(backend, "pro_monthly_intro"), store(proDisk, "pro-key-0002"), "acct",
            pay = { WxPayOutcome.CANCELLED }, sleep = {})
        assertEquals(RechargeResult.Cancelled, flow.purchase(990))
        assertTrue(proDisk.value!!.contains("pro-key-0002"))
        assertTrue(proDisk.value!!.contains("PRO-1"))
    }
}
