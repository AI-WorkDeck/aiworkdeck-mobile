package com.aiworkdeck.mobile

import com.aiworkdeck.contract.ContractProducts
import com.aiworkdeck.mobile.services.AccountRegion
import com.aiworkdeck.mobile.services.ApiError
import com.aiworkdeck.mobile.services.AppPayParams
import com.aiworkdeck.mobile.services.Backend
import com.aiworkdeck.mobile.services.EnvelopeKind
import com.aiworkdeck.mobile.services.MemorySessionStore
import com.aiworkdeck.mobile.services.PendingRechargeStore
import com.aiworkdeck.mobile.services.PollOutcome
import com.aiworkdeck.mobile.services.RechargeApi
import com.aiworkdeck.mobile.services.RechargeOrder
import com.aiworkdeck.mobile.services.RechargeResult
import com.aiworkdeck.mobile.services.RechargeStatus
import com.aiworkdeck.mobile.services.Unauthorized
import com.aiworkdeck.mobile.services.WxPayOutcome
import com.aiworkdeck.mobile.services.WxPayRecharge
import com.aiworkdeck.mobile.services.awaitWxPayResult
import com.aiworkdeck.mobile.services.isChannelUnavailable
import com.aiworkdeck.mobile.services.pollRechargeStatus
import com.aiworkdeck.mobile.services.wxPayOutcome
import com.aiworkdeck.mobile.services.wxpayAppEnabled
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File

/** 安卓微信 APP 支付充值（dev-board#428）：线上形状、开关、落盘恢复、查单结局。 */
class WxPayRechargeTest {
    private lateinit var server: MockWebServer
    private lateinit var backend: Backend

    @Before fun setUp() {
        server = MockWebServer(); server.start()
        backend = Backend(server.url("/").toString().trimEnd('/'), MemorySessionStore().also { it.save("s1") })
    }

    @After fun tearDown() { server.shutdown() }

    private fun fixture(): JsonObject = Json.parseToJsonElement(File("../../contract/fixtures/billing.json").readText()).jsonObject
    private fun str(e: JsonElement?): String? = if (e == null || e is JsonNull) null else e.jsonPrimitive.content

    // ---- 线上形状：走真实 Backend 解码路径对拍契约夹具 ----

    @Test fun rechargeFixturesDecodeThroughBackend() = runTest {
        val presents = mutableSetOf<String>()
        for (c in fixture()["recharge"]!!.jsonArray.map { it.jsonObject }) {
            val name = c["name"]!!.jsonPrimitive.content
            server.enqueue(MockResponse().setBody(c["json"].toString()))
            val got = backend.billingRecharge(5000, "idem-key-0001")
            val e = c["expect"]!!.jsonObject
            val asMap = mapOf(
                "present" to got.present, "outTradeNo" to got.outTradeNo, "codeUrl" to got.codeUrl, "qrCode" to got.qrCode,
                "redirectUrl" to got.redirectUrl, "signData" to got.signData, "paySig" to got.paySig, "signature" to got.signature,
                "appAccountToken" to got.appAccountToken, "appId" to got.appId, "partnerId" to got.partnerId, "prepayId" to got.prepayId,
                "packageValue" to got.packageValue, "nonceStr" to got.nonceStr, "timeStamp" to got.timeStamp, "sign" to got.sign,
            )
            for ((k, v) in asMap) assertEquals("$name · $k", str(e[k]), v)
            assertEquals(name, e["amountCents"]!!.jsonPrimitive.long, got.amountCents)
            // 只有 present=app 能拿到 PayReq 参数，而且是原样透传
            val params = got.appPayParams()
            if (got.present == "app") {
                assertEquals(AppPayParams(got.appId!!, got.partnerId!!, got.prepayId!!, got.packageValue!!, got.nonceStr!!, got.timeStamp!!, got.sign!!), params)
                assertEquals("Sign=WXPay", params!!.packageValue)
            } else assertNull(name, params)
            presents += got.present
        }
        assertTrue("夹具必须含 present=app", "app" in presents)
    }

    @Test fun rechargeRequestShapeMatchesServerContract() = runTest {
        server.enqueue(MockResponse().setBody("""{"present":"app","outTradeNo":"o1","amountCents":5000,"appId":"wx1","partnerId":"p","prepayId":"pp","packageValue":"Sign=WXPay","nonceStr":"n","timeStamp":"1","sign":"s"}"""))
        backend.billingRecharge(5000, "idem-key-0001")
        val req = server.takeRequest()
        assertEquals("/api/mobile/billing/recharge", req.path)
        assertEquals("POST", req.method)
        assertEquals("s1", req.getHeader("X-Session-Id"))
        val body = Json.parseToJsonElement(req.body.readUtf8()).jsonObject
        assertEquals(setOf("amountCents", "idempotencyKey", "channel"), body.keys)
        assertEquals(5000L, body["amountCents"]!!.jsonPrimitive.long)
        assertEquals("idem-key-0001", body["idempotencyKey"]!!.jsonPrimitive.content)
        assertEquals("wxpay-app", body["channel"]!!.jsonPrimitive.content)
    }

    @Test fun missingPayReqFieldGivesNoParams() {
        val o = RechargeOrder("app", "o1", 5000, appId = "wx1", partnerId = "p", prepayId = "pp", packageValue = "Sign=WXPay", nonceStr = "n", timeStamp = "1")
        assertNull(o.appPayParams())
        assertNull(o.copy(sign = "").appPayParams())
        assertNotNull(o.copy(sign = "s").appPayParams())
    }

    @Test fun statusFixturesDecodeThroughBackend() = runTest {
        for (c in fixture()["status"]!!.jsonArray.map { it.jsonObject }) {
            server.enqueue(MockResponse().setBody(c["json"].toString()))
            val got = backend.billingRechargeStatus("awd/1 2")
            val e = c["expect"]!!.jsonObject
            assertEquals(RechargeStatus(e["status"]!!.jsonPrimitive.content, e["paid"]!!.jsonPrimitive.boolean, e["amountCents"]!!.jsonPrimitive.long), got)
            assertEquals("/api/mobile/billing/recharge/status?outTradeNo=awd%2F1+2", server.takeRequest().path)
        }
    }

    @Test fun envelopeErrorsKeepKindAndOutTradeNo() = runTest {
        server.enqueue(MockResponse().setBody("""{"code":1,"message":"x","kind":"ALREADY_PAID","outTradeNo":"o9"}"""))
        try { backend.billingRecharge(5000, "idem-key-0001"); fail() } catch (e: ApiError) {
            assertEquals(EnvelopeKind.ALREADY_PAID, e.kind); assertEquals("o9", e.outTradeNo)
        }
    }

    // ---- 开关 ----

    @Test fun gateNeedsCnFlavorCnRegionAppIdAndServer() {
        assertTrue(wxpayAppEnabled("cn", AccountRegion.cn, "wx1234567890abcdef", false, null))
        assertTrue(wxpayAppEnabled("cn", AccountRegion.cn, "wx1234567890abcdef", false, EnvelopeKind.NOT_CONNECTED))
        assertTrue(wxpayAppEnabled("cn", AccountRegion.cn, "wx1234567890abcdef", false, EnvelopeKind.UNAVAILABLE))
        // 默认构建：AppID 空串 → 保持今天的说明弹窗
        assertFalse(wxpayAppEnabled("cn", AccountRegion.cn, "", false, null))
        assertFalse(wxpayAppEnabled("intl", AccountRegion.cn, "wx1234567890abcdef", false, null))
        assertFalse(wxpayAppEnabled("cn", AccountRegion.intl, "wx1234567890abcdef", false, null))
        assertFalse(wxpayAppEnabled("cn", AccountRegion.cn, "wx1234567890abcdef", true, null))
        assertFalse(wxpayAppEnabled("cn", AccountRegion.cn, "wx1234567890abcdef", false, EnvelopeKind.DISABLED))
        assertFalse(wxpayAppEnabled("cn", AccountRegion.cn, "wx1234567890abcdef", false, EnvelopeKind.REVIEW_ACCOUNT))
    }

    @Test fun channelUnavailableClassification() {
        assertTrue(isChannelUnavailable(ApiError(1, "m", EnvelopeKind.DISABLED)))
        assertTrue(isChannelUnavailable(ApiError(1, "m", EnvelopeKind.REVIEW_ACCOUNT)))
        assertFalse(isChannelUnavailable(ApiError(503, "m"))) // 裸 503 是瞬时故障
        assertFalse(isChannelUnavailable(ApiError(1, "m", EnvelopeKind.UNAVAILABLE)))
        assertFalse(isChannelUnavailable(ApiError(1, "m")))
        assertFalse(isChannelUnavailable(IllegalStateException()))
    }

    @Test fun buildConfigCarriesTheLinkedAppIdForCn() {
        // 大陆版默认带已关联商户号的移动应用 AppID；国际版不带（不出现微信支付）
        if (BuildConfig.FLAVOR == "cn") assertEquals("wx1dcd3c3bc2db3fe1", BuildConfig.WXPAY_APP_ID)
        else assertEquals("", BuildConfig.WXPAY_APP_ID)
    }

    @Test fun tiersComeFromContract() {
        assertEquals(listOf(5000L, 10000L, 30000L), ContractProducts.wxpayApp)
    }

    @Test fun sdkErrCodeMapping() {
        assertEquals(WxPayOutcome.SUCCESS, wxPayOutcome(0))
        assertEquals(WxPayOutcome.CANCELLED, wxPayOutcome(-2))
        assertEquals(WxPayOutcome.FAILED, wxPayOutcome(-1))
        assertEquals(WxPayOutcome.FAILED, wxPayOutcome(-5))
    }

    @Test fun sdkResultWinsAndResumeFallsBackToUnknown() = runTest {
        val results = MutableSharedFlow<WxPayOutcome>(replay = 1)
        results.emit(WxPayOutcome.CANCELLED)
        assertEquals(WxPayOutcome.CANCELLED, awaitWxPayResult(results, MutableSharedFlow<Unit>()))
        // 微信没回调：回到前台 grace 之后按 UNKNOWN 交给查单
        val resumed = MutableSharedFlow<Unit>(replay = 1)
        resumed.emit(Unit)
        assertEquals(WxPayOutcome.UNKNOWN, awaitWxPayResult(MutableSharedFlow(), resumed, graceMs = 3000))
    }

    // ---- 落盘与恢复 ----

    private class Disk { var value: String? = null; var writes = 0 }
    private fun store(disk: Disk, keys: Iterator<String> = generateSequence { java.util.UUID.randomUUID().toString() }.iterator()) =
        PendingRechargeStore({ disk.value }, { disk.value = it; disk.writes++ }, { keys.next() })

    @Test fun keyIsPersistedBeforeUseAndReusedForSameAmount() {
        val disk = Disk()
        val s = store(disk, generateSequence(1) { it + 1 }.map { "key-$it" }.iterator())
        assertEquals("key-1", s.takeKey("acct", 5000))
        assertNotNull("先落盘再发请求", disk.value)
        assertEquals("key-1", s.takeKey("acct", 5000))
        assertEquals("key-2", s.takeKey("acct", 10000))
        assertEquals("换账号不复用别人的键", "key-3", s.takeKey("other", 10000))
        assertNull(s.current("acct"))
    }

    @Test fun outTradeNoSurvivesRestartAndClearIsScoped() {
        val disk = Disk()
        store(disk, listOf("key-1").iterator()).apply { takeKey("acct", 5000); attach("acct", "key-1", "o1"); attach("acct", "stale-key", "o2") }
        val reopened = store(disk) // 模拟进程重启：只剩磁盘上的字符串
        assertEquals("o1", reopened.current("acct")?.outTradeNo)
        reopened.clear("other")
        assertNotNull(reopened.current("acct"))
        reopened.clear("acct")
        assertNull(disk.value)
    }

    @Test fun corruptDiskValueIsIgnored() {
        val disk = Disk().apply { value = "{not json" }
        assertNull(store(disk).current("acct"))
    }

    // ---- 查单轮询 ----

    private fun st(status: String) = RechargeStatus(status, status == "paid", 5000)

    @Test fun pollOutcomes() = runTest {
        val noSleep: suspend (Long) -> Unit = {}
        val seq = ArrayDeque(listOf(st("pending"), st("pending"), st("paid")))
        assertEquals(PollOutcome.PAID, pollRechargeStatus({ seq.removeFirst() }, sleep = noSleep))
        assertEquals(PollOutcome.CLOSED, pollRechargeStatus({ st("expired") }, sleep = noSleep))
        assertEquals(PollOutcome.CLOSED, pollRechargeStatus({ st("closed") }, sleep = noSleep))
        var calls = 0
        assertEquals(PollOutcome.PENDING, pollRechargeStatus({ calls++; st("pending") }, tries = 8, sleep = noSleep))
        assertEquals(8, calls)
        // 单次查单失败不打断
        var n = 0
        assertEquals(PollOutcome.PAID, pollRechargeStatus({ if (n++ == 0) throw java.io.IOException() else st("paid") }, sleep = noSleep))
        // 登录失效往上抛
        try { pollRechargeStatus({ throw Unauthorized() }, sleep = noSleep); fail() } catch (_: Unauthorized) {}
    }

    @Test fun pollSleepsBetweenAttemptsAndOptionallyFirst() = runTest {
        val sleeps = mutableListOf<Long>()
        pollRechargeStatus({ st("pending") }, tries = 3, intervalMs = 1500, delayFirst = false, sleep = { sleeps += it })
        assertEquals(listOf(1500L, 1500L), sleeps)
    }

    // ---- 整笔流程 ----

    private val appOrder = RechargeOrder("app", "o1", 5000, appId = "wx1", partnerId = "p", prepayId = "pp",
        packageValue = "Sign=WXPay", nonceStr = "n", timeStamp = "1", sign = "s")

    private class FakeApi(var orders: ArrayDeque<Any>, var statuses: ArrayDeque<RechargeStatus> = ArrayDeque()) : RechargeApi {
        val keys = mutableListOf<String>(); val statusCalls = mutableListOf<String>()
        override suspend fun order(amountCents: Long, idempotencyKey: String): RechargeOrder {
            keys += idempotencyKey
            return when (val o = orders.removeFirst()) { is Exception -> throw o; else -> o as RechargeOrder }
        }
        override suspend fun status(outTradeNo: String): RechargeStatus { statusCalls += outTradeNo; return statuses.removeFirstOrNull() ?: RechargeStatus("pending", false, 5000) }
    }

    private fun flow(api: FakeApi, disk: Disk, outcome: WxPayOutcome) =
        WxPayRecharge(api, store(disk), "acct", pay = { outcome }, sleep = {})

    @Test fun successIsConfirmedByPollingThenCleared() = runTest {
        val disk = Disk()
        val api = FakeApi(ArrayDeque(listOf(appOrder)), ArrayDeque(listOf(st("pending"), st("paid"))))
        assertEquals(RechargeResult.Paid, flow(api, disk, WxPayOutcome.SUCCESS).purchase(5000))
        assertEquals(listOf("o1", "o1"), api.statusCalls)
        assertNull(disk.value)
    }

    @Test fun sdkSuccessWithoutPaidStatusIsStillConfirming() = runTest {
        val disk = Disk()
        val api = FakeApi(ArrayDeque(listOf(appOrder)))
        assertEquals(RechargeResult.Pending, flow(api, disk, WxPayOutcome.SUCCESS).purchase(5000))
        assertEquals("o1", store(disk).current("acct")?.outTradeNo)
    }

    @Test fun unknownSdkResultStillPolls() = runTest {
        val api = FakeApi(ArrayDeque(listOf(appOrder)), ArrayDeque(listOf(st("paid"))))
        assertEquals(RechargeResult.Paid, flow(api, Disk(), WxPayOutcome.UNKNOWN).purchase(5000))
    }

    @Test fun cancelKeepsKeySoRetryReusesIt() = runTest {
        val disk = Disk()
        val api = FakeApi(ArrayDeque(listOf(appOrder, appOrder)))
        assertEquals(RechargeResult.Cancelled, flow(api, disk, WxPayOutcome.CANCELLED).purchase(5000))
        assertTrue(api.statusCalls.isEmpty())
        flow(api, disk, WxPayOutcome.CANCELLED).purchase(5000)
        assertEquals(api.keys[0], api.keys[1])
    }

    @Test fun notInstalledAndFailedMapToMessages() = runTest {
        assertEquals(RechargeResult.NotInstalled, flow(FakeApi(ArrayDeque(listOf(appOrder))), Disk(), WxPayOutcome.NOT_INSTALLED).purchase(5000))
        assertEquals(RechargeResult.Failed(), flow(FakeApi(ArrayDeque(listOf(appOrder))), Disk(), WxPayOutcome.FAILED).purchase(5000))
        // present 不是 app 或缺字段：不调微信
        var paid = false
        val r = WxPayRecharge(FakeApi(ArrayDeque(listOf(appOrder.copy(present = "qrcode")))), store(Disk()), "acct", pay = { paid = true; WxPayOutcome.SUCCESS }, sleep = {}).purchase(5000)
        assertEquals(RechargeResult.Failed(), r); assertFalse(paid)
    }

    @Test fun channelUnavailableNeverCallsWeChat() = runTest {
        for (e in listOf(ApiError(1, "m", EnvelopeKind.DISABLED), ApiError(1, "m", EnvelopeKind.REVIEW_ACCOUNT))) {
            var called = false
            val r = WxPayRecharge(FakeApi(ArrayDeque(listOf(e))), store(Disk()), "acct", pay = { called = true; WxPayOutcome.SUCCESS }, sleep = {}).purchase(5000)
            assertEquals(RechargeResult.ChannelUnavailable, r); assertFalse(called)
        }
    }

    @Test fun alreadyPaidGoesStraightToStatus() = runTest {
        val api = FakeApi(ArrayDeque(listOf(ApiError(1, "m", EnvelopeKind.ALREADY_PAID, "o7"))), ArrayDeque(listOf(st("paid"))))
        var called = false
        val r = WxPayRecharge(api, store(Disk()), "acct", pay = { called = true; WxPayOutcome.SUCCESS }, sleep = {}).purchase(5000)
        assertEquals(RechargeResult.PreviousPaid, r); assertFalse(called); assertEquals(listOf("o7"), api.statusCalls)
    }

    @Test fun earlierUnconfirmedPaymentIsReportedNotRecharged() = runTest {
        val disk = Disk()
        // 第一次：付了但轮询窗口内没到账 → Pending，单子留在盘上
        val first = FakeApi(ArrayDeque(listOf(appOrder)))
        assertEquals(RechargeResult.Pending, flow(first, disk, WxPayOutcome.SUCCESS).purchase(5000))
        // 再点同一档：先查到上一笔已到账 → PreviousPaid，不下新单、不调起微信
        var called = false
        val second = FakeApi(ArrayDeque(), ArrayDeque(listOf(st("paid"))))
        val r = WxPayRecharge(second, store(disk), "acct", pay = { called = true; WxPayOutcome.SUCCESS }, sleep = {}).purchase(5000)
        assertEquals(RechargeResult.PreviousPaid, r); assertFalse(called); assertTrue(second.keys.isEmpty())
        // 再点一次就是一笔新的充值（新键）
        val third = FakeApi(ArrayDeque(listOf(appOrder)), ArrayDeque(listOf(st("paid"))))
        assertEquals(RechargeResult.Paid, flow(third, disk, WxPayOutcome.SUCCESS).purchase(5000))
        assertNotEquals(first.keys[0], third.keys[0])
    }

    @Test fun idempotencyConflictRetriesOnceWithNewKey() = runTest {
        val conflict = ApiError(1, "m", EnvelopeKind.IDEMPOTENCY_CONFLICT, "o8")
        val api = FakeApi(ArrayDeque(listOf(conflict, appOrder)), ArrayDeque(listOf(st("paid"))))
        assertEquals(RechargeResult.Paid, flow(api, Disk(), WxPayOutcome.SUCCESS).purchase(5000))
        assertEquals(2, api.keys.size); assertNotEquals(api.keys[0], api.keys[1])
        // 只重来一次
        val api2 = FakeApi(ArrayDeque(listOf(conflict, conflict)))
        try { flow(api2, Disk(), WxPayOutcome.SUCCESS).purchase(5000); fail() } catch (e: ApiError) { assertEquals(EnvelopeKind.IDEMPOTENCY_CONFLICT, e.kind) }
    }

    @Test fun transientErrorsPropagateForMessage() = runTest {
        try { flow(FakeApi(ArrayDeque(listOf(ApiError(1, "m", EnvelopeKind.UNAVAILABLE)))), Disk(), WxPayOutcome.SUCCESS).purchase(5000); fail() }
        catch (e: ApiError) { assertEquals(EnvelopeKind.UNAVAILABLE, e.kind) }
    }

    @Test fun resumeAfterRestart() = runTest {
        val disk = Disk()
        // 第一次：付完还没确认到账，进程被杀
        flow(FakeApi(ArrayDeque(listOf(appOrder))), disk, WxPayOutcome.SUCCESS).purchase(5000)
        // 重启：进页面静默查一次，只查一次
        val api = FakeApi(ArrayDeque(), ArrayDeque(listOf(st("pending"))))
        assertEquals(RechargeResult.Pending, flow(api, disk, WxPayOutcome.SUCCESS).resume(quick = true))
        assertEquals(1, api.statusCalls.size)
        // 用户点「查询未完成的支付」：到账了，清掉
        val api2 = FakeApi(ArrayDeque(), ArrayDeque(listOf(st("pending"), st("paid"))))
        assertEquals(RechargeResult.Paid, flow(api2, disk, WxPayOutcome.SUCCESS).resume(quick = false))
        assertNull(disk.value)
        assertEquals(RechargeResult.NothingPending, flow(api2, disk, WxPayOutcome.SUCCESS).resume(quick = false))
    }

    @Test fun closedOrderClearsSlotSoNextAttemptGetsNewKey() = runTest {
        val disk = Disk()
        val api = FakeApi(ArrayDeque(listOf(appOrder, appOrder)), ArrayDeque(listOf(st("closed"))))
        assertEquals(RechargeResult.Failed(), flow(api, disk, WxPayOutcome.SUCCESS).purchase(5000))
        assertNull(disk.value)
        flow(api, disk, WxPayOutcome.CANCELLED).purchase(5000)
        assertNotEquals(api.keys[0], api.keys[1])
    }
}
