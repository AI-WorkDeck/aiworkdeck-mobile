package com.aiworkdeck.mobile.features.settings

import com.aiworkdeck.mobile.model.IsoTime
import com.aiworkdeck.mobile.services.EnvelopeKind
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

private val UNITS = arrayOf("B", "KB", "MB", "GB", "TB")

/**
 * 字节数给人看。1024 进位（与 iOS `ByteCountFormatter.countStyle = .binary` 同口径，
 * 两端显示同一个配额时不会差出 5%）。小于 10 保留一位小数，10 以上取整——
 * 「4.7 GB / 20 GB」有用，「4.73 GB」只是噪音。
 *
 * 纯函数，不碰 Android，JVM 单测直接调。
 */
fun formatBytes(bytes: Long): String {
    var v = bytes.coerceAtLeast(0L).toDouble()
    var i = 0
    while (v >= 1024.0 && i < UNITS.size - 1) { v /= 1024.0; i++ }
    val n = if (i == 0) v.toLong().toString()
    else String.format(Locale.US, if (v < 10.0) "%.1f" else "%.0f", v)
    return "$n ${UNITS[i]}"
}

private val CURRENCY_SYMBOLS = mapOf("CNY" to "¥", "USD" to "$")

/**
 * 整数分格式化成带币种符号的金额，两位小数。币种符号必须来自响应里的 `currency`字段——
 * 写死 ¥ 会让 USD 站点显示错币种（design doc §5）。未识别的币种回退显示币种代码本身。
 *
 * 纯函数，不碰 Android，JVM 单测直接调。
 */
fun formatMoney(cents: Long, currency: String): String {
    val symbol = CURRENCY_SYMBOLS[currency] ?: "$currency "
    return "$symbol${String.format(Locale.US, "%.2f", cents / 100.0)}"
}

/**
 * 余额行读取失败时怎么显示，按信封的 kind 分支——绝不匹配 message 措辞。服务端 message
 * 经 LangText 按语言产文案，英文部署下会整条变英文，历史上按中文串匹配在这种情况下必然
 * 全部落空（dev-board#425 复审 C2）。
 *
 * NOT_CONNECTED / DISABLED / REVIEW_ACCOUNT 三种 kind 返回 null，调用方应把余额那一整行
 * 都不渲染：这三种都是永远不会自己恢复的终态（未关联 / 本部署没开通充值 / 审核演示账号），
 * 把它们显示成「稍后再试」是让用户去重试一句永不改变的报错（dev-board#425 二轮复审 N2，
 * 唯一来源见 contract/schema/billing.schema.json 的 UI 映射表）。
 *
 * 其余一切失败（含 kind 缺席，即 code=1 但没带这个字段的非 billing 专有失败，比如缺
 * idempotencyKey）一律返回 "balance.unavailable"——这些才是值得让用户再试一次的瞬时故障，
 * 宁可少判一次「未关联」，也不能把真正的上游故障说成「没关联账户」。
 *
 * 纯函数，不碰 Android，JVM 单测直接调。
 */
fun balanceFailureKey(kind: EnvelopeKind?): String? = when (kind) {
    EnvelopeKind.NOT_CONNECTED, EnvelopeKind.DISABLED, EnvelopeKind.REVIEW_ACCOUNT -> null
    else -> "balance.unavailable"
}

/**
 * 服务端给的 ISO 时刻（后付费提醒 / 清理时间）按本机时区、界面语言的短格式显示。
 * 解析不了就原样给出——宁可难看，也不能把日期吞掉。
 *
 * 纯函数，不碰 Android，JVM 单测直接调。
 */
fun formatDateTime(raw: String, locale: Locale, zone: ZoneId = ZoneId.systemDefault()): String {
    val instant = IsoTime.parse(raw, zone) ?: return raw
    return DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT).withLocale(locale).format(instant.atZone(zone))
}
