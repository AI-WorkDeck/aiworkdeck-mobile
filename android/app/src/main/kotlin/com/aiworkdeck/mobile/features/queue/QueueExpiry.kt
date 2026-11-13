package com.aiworkdeck.mobile.features.queue

import com.aiworkdeck.mobile.model.IsoTime
import java.time.Instant
import kotlin.math.ceil

/** 只在还剩不到这么多天时说话，平时不打扰。 */
const val EXPIRY_WARN_DAYS = 3L

/**
 * 中转区还剩几天（向上取整，已过期算 0）。解析不出到期时刻就返回 null——
 * 宁可不提醒，也不要凭空造一个日期吓人。纯函数，JVM 单测直接调。
 */
fun expiryDaysLeft(expiresAt: String?, now: Instant): Long? {
    val at = expiresAt?.let { IsoTime.parse(it) } ?: return null
    val seconds = at.epochSecond - now.epochSecond
    if (seconds <= 0L) return 0L
    return ceil(seconds / 86_400.0).toLong()
}

/** 队列行只在还剩不到 [EXPIRY_WARN_DAYS] 天时提醒（与 iOS 同口径：按秒算，不按向上取整的天数）。 */
fun expiresSoon(expiresAt: String?, now: Instant): Boolean {
    val at = expiresAt?.let { IsoTime.parse(it) } ?: return false
    return at.epochSecond - now.epochSecond < EXPIRY_WARN_DAYS * 86_400
}
