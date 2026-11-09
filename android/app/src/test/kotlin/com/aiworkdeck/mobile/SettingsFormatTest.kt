package com.aiworkdeck.mobile

import com.aiworkdeck.mobile.features.queue.expiryDaysLeft
import com.aiworkdeck.mobile.features.settings.balanceFailureKey
import com.aiworkdeck.mobile.features.settings.formatBytes
import com.aiworkdeck.mobile.features.settings.formatDateTime
import com.aiworkdeck.mobile.features.settings.formatMoney
import com.aiworkdeck.mobile.services.EnvelopeKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.Instant
import java.time.ZoneId
import java.util.Locale

class SettingsFormatTest {
    @Test fun formatsServerTimeInLocalZoneAndFallsBackToRaw() {
        val utc = ZoneId.of("UTC")
        val shanghai = ZoneId.of("Asia/Shanghai")
        // 同一时刻换时区显示不同的钟点：确实按本机时区换算了
        val a = formatDateTime("2026-11-20T00:00:00Z", Locale.US, utc)
        val b = formatDateTime("2026-11-20T00:00:00Z", Locale.US, shanghai)
        assert(a.contains("12:00") && b.contains("8:00")) { "$a / $b" }
        assertEquals("not a date", formatDateTime("not a date", Locale.US, utc))
    }

    @Test fun formatsBytesWithBinaryStepsAndOneDecimalUnderTen() {
        assertEquals("0 B", formatBytes(0))
        assertEquals("512 B", formatBytes(512))
        assertEquals("1.5 KB", formatBytes(1536))
        assertEquals("2.0 GB", formatBytes(2L * 1024 * 1024 * 1024))
    }

    @Test fun dropsDecimalOnceTheNumberIsBigEnoughToBeNoise() {
        assertEquals("300 MB", formatBytes(300L * 1024 * 1024))
        // 负数只可能是服务端给了脏值，按 0 显示而不是画出个「-1 B」
        assertEquals("0 B", formatBytes(-1))
    }

    @Test fun expiryDaysRoundUpAndClampAtZero() {
        val now = Instant.parse("2026-09-03T00:00:00Z")
        assertEquals(3L, expiryDaysLeft("2026-09-05T18:00:00Z", now))
        assertEquals(1L, expiryDaysLeft("2026-09-03T01:00:00Z", now))
        assertEquals(0L, expiryDaysLeft("2026-09-02T23:00:00Z", now))
        assertNull(expiryDaysLeft(null, now))
        assertNull(expiryDaysLeft("不是时间", now))
    }

    @Test fun formatsMoneyWithCurrencySymbolFromResponse() {
        // 币种符号必须跟着响应里的 currency 走，不能写死 ¥（design doc §5）
        assertEquals("¥1234.56", formatMoney(123456, "CNY"))
        assertEquals("$9.90", formatMoney(990, "USD"))
        assertEquals("¥0.00", formatMoney(0, "CNY"))
    }

    @Test fun formatMoneyFallsBackToCurrencyCodeWhenUnknown() {
        assertEquals("JPY 10.00", formatMoney(1000, "JPY"))
    }

    @Test fun terminalKindsHideTheBalanceRow() {
        // 三个永远不会自己恢复的终态 → null，调用方据此整行不渲染，不给任何误导性指引
        // （dev-board#425 二轮复审 N2，唯一来源 contract/schema/billing.schema.json）：
        // 未关联账户 / 本部署没开通充值 / App 审核演示账号一律关掉余额入口
        assertNull(balanceFailureKey(EnvelopeKind.NOT_CONNECTED))
        assertNull(balanceFailureKey(EnvelopeKind.DISABLED))
        assertNull(balanceFailureKey(EnvelopeKind.REVIEW_ACCOUNT))
    }

    @Test fun everyOtherKindAndMissingKindFallBackToUnavailable() {
        // 一律按 kind 分支，不匹配 message 措辞；宁可少判一次「未关联」，
        // 也不能把真正的上游故障说成「没关联账户」——含 kind 缺席（code=1 但没带这个字段）的情况。
        // 这些才是值得重试的瞬时故障，与上面三个终态刻意不同（N2）。
        assertEquals("balance.unavailable", balanceFailureKey(null))
        assertEquals("balance.unavailable", balanceFailureKey(EnvelopeKind.UNAVAILABLE))
        assertEquals("balance.unavailable", balanceFailureKey(EnvelopeKind.NOT_FOUND))
        assertEquals("balance.unavailable", balanceFailureKey(EnvelopeKind.REJECTED))
        assertEquals("balance.unavailable", balanceFailureKey(EnvelopeKind.ALREADY_PAID))
        assertEquals("balance.unavailable", balanceFailureKey(EnvelopeKind.IDEMPOTENCY_CONFLICT))
    }
}
