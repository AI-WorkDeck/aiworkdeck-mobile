package com.aiworkdeck.mobile

import com.aiworkdeck.mobile.features.settings.formatMoney
import com.aiworkdeck.mobile.services.ApiError
import com.aiworkdeck.mobile.services.Backend
import com.aiworkdeck.mobile.services.EnvelopeKind
import com.aiworkdeck.mobile.services.MemorySessionStore
import com.aiworkdeck.mobile.services.Unauthorized
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * 契约夹具适配：contract/fixtures/billing.json（dev-board#425 复审 C2）。它不是
 * `{cases:[...]}` 结构——四个段（balance/recharge/status/envelope）各自是顶层数组，
 * ContractFixturesTest.kt 的 cases(name) 辅助函数读不了，这里按段名直接取。
 *
 * 走真实的 Backend 网络解码路径（MockWebServer，同 BackendTest.kt 写法），而不是另外
 * 摆一遍 kotlinx.serialization——checkEnvelopeCode 的 kind/outTradeNo 解析改坏了会在
 * 这里先炸，不用等到设置页手测才发现。recharge/status 两段由 WxPayRechargeTest 消费
 * （微信 APP 支付，dev-board#428）。
 */
class BillingFixturesTest {
    private lateinit var server: MockWebServer
    private lateinit var backend: Backend

    @Before fun setUp() {
        server = MockWebServer()
        server.start()
        backend = Backend(server.url("/").toString().trimEnd('/'), MemorySessionStore())
    }

    @After fun tearDown() { server.shutdown() }

    private fun fixture(): JsonObject =
        Json.parseToJsonElement(File("../../contract/fixtures/billing.json").readText()).jsonObject

    /**
     * balance：裸对象成功路径。plan 是计费档位（paid/free），上游没给时才是 null——
     * 解码结果必须原样保留（不能把缺席悄悄补成某个默认档位）。安卓端目前没有任何代码
     * 读 BillingBalance.plan 去渲染（已用 grep 核实：android/app/src/main 里没有 `.plan`
     * 用法），本测试只保证解码正确，plan 不被当套餐名处理是靠「压根不读它」做到的。
     */
    @Test fun balanceDecodesBareObjectIncludingNullPlan() = runTest {
        for (c in fixture()["balance"]!!.jsonArray.map { it.jsonObject }) {
            val name = c["name"]!!.jsonPrimitive.content
            server.enqueue(MockResponse().setBody(c["json"].toString()))
            val got = backend.billingBalance()
            val e = c["expect"]!!.jsonObject
            assertEquals(name, e["balanceCents"]!!.jsonPrimitive.long, got.balanceCents)
            assertEquals(name, e["currency"]!!.jsonPrimitive.content, got.currency)
            val wantPlan = e["plan"]!!.let { if (it is JsonNull) null else it.jsonPrimitive.content }
            assertEquals(name, wantPlan, got.plan)
            assertEquals(name, e["billingLine"]?.jsonPrimitive?.content, got.billingLine)
        }
    }

    /**
     * balance.display：金额展示口径的唯一来源是 contract/schema/billing.schema.json 的说明段
     * （符号按 currency 取 + 两位小数、无千分位、不跟设备 locale），fixtures/billing.json 每条
     * 用例的 display 就是这条规则的期望输出。这里直接读夹具的 display 字符串跟 [formatMoney]
     * 对拍，而不是在测试里另抄一遍数字——契约改了这张表，这条测试才会跟着变，不用手改
     * （dev-board#425 二轮复审 N7）。
     */
    @Test fun balanceDisplayMatchesFixtureFormatting() {
        for (c in fixture()["balance"]!!.jsonArray.map { it.jsonObject }) {
            val name = c["name"]!!.jsonPrimitive.content
            val j = c["json"]!!.jsonObject
            val wantDisplay = c["display"]!!.jsonPrimitive.content
            val cents = j["balanceCents"]!!.jsonPrimitive.long
            val currency = j["currency"]!!.jsonPrimitive.content
            assertEquals(name, wantDisplay, formatMoney(cents, currency))
        }
    }

    /**
     * envelope：kind/outTradeNo 是机器可读判别位。缺席的可选键必须解成 null（不是空串，
     * 更不能猜一个出来）；八个 kind 全部取值都要能经真实解码路径正确落到 ApiError.kind 上。
     * code=4010 那条不产出 ApiError——checkEnvelopeCode 对它是清会话 + 抛 Unauthorized，
     * 单独断言。
     */
    @Test fun envelopeDecodesKindAndOutTradeNoOrNullWhenAbsent() = runTest {
        val seenKinds = mutableSetOf<EnvelopeKind>()
        for (c in fixture()["envelope"]!!.jsonArray.map { it.jsonObject }) {
            val name = c["name"]!!.jsonPrimitive.content
            val e = c["expect"]!!.jsonObject
            val wantCode = e["code"]!!.jsonPrimitive.int
            server.enqueue(MockResponse().setBody(c["json"].toString()))

            if (wantCode == 4010) {
                try {
                    backend.billingBalance()
                    fail("$name: expected Unauthorized")
                } catch (expected: Unauthorized) {
                    // 4010 没有信封字段可读，Unauthorized 本身不携带 kind/outTradeNo
                }
                continue
            }

            try {
                backend.billingBalance()
                fail("$name: expected ApiError")
            } catch (err: ApiError) {
                val wantMessage = e["message"]!!.let { if (it is JsonNull) null else it.jsonPrimitive.content }
                val wantKind = e["kind"]!!.let { if (it is JsonNull) null else EnvelopeKind.valueOf(it.jsonPrimitive.content) }
                val wantOutTradeNo = e["outTradeNo"]!!.let { if (it is JsonNull) null else it.jsonPrimitive.content }
                assertEquals(name, wantCode, err.code)
                assertEquals(name, wantMessage, err.message)
                assertEquals(name, wantKind, err.kind)
                assertEquals(name, wantOutTradeNo, err.outTradeNo)
                err.kind?.let { seenKinds += it }
            }
        }
        assertEquals("夹具应覆盖全部 8 个 kind", EnvelopeKind.entries.toSet(), seenKinds)
    }
}
