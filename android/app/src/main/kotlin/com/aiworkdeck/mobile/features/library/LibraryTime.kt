package com.aiworkdeck.mobile.features.library

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/**
 * 图集与查看器上的时刻。格子上只到分（一格里塞不下更多），全屏看大图时到秒——核对
 * 取证件要精确到那一下。一律本机时区：现场的人核对的是他自己的表。
 */
object LibraryTime {
    private val hm = DateTimeFormatter.ofPattern("HH:mm")
    private val hms = DateTimeFormatter.ofPattern("HH:mm:ss")

    fun clock(instant: Instant, zone: ZoneId = ZoneId.systemDefault()): String = hm.format(instant.atZone(zone))
    fun precise(instant: Instant, zone: ZoneId = ZoneId.systemDefault()): String = hms.format(instant.atZone(zone))

    /** 日期（界面语言的写法），查看器顶栏用。 */
    fun day(instant: Instant, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = uiLocale()): String =
        DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(locale).format(instant.atZone(zone))

    /** 日期 + 到秒的时刻，详情里的拍摄时间用。 */
    fun full(instant: Instant, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = uiLocale()): String =
        DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM).withLocale(locale).format(instant.atZone(zone))

    private fun uiLocale(): Locale = Locale.forLanguageTag(com.aiworkdeck.mobile.design.L10n.locale)
}
