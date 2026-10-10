package com.aiworkdeck.mobile.services

import kotlinx.serialization.Serializable

@Serializable
data class AccountUser(
    val id: Long,
    val username: String,
    val displayName: String,
    val avatarUrl: String? = null,
    val role: String? = null,
)

@Serializable
data class LoginResult(
    val sessionId: String,
    val isNewUser: Boolean? = null,
    val mustBindPhone: Boolean? = null,
    val user: AccountUser,
)

@Serializable
data class MediaStatus(
    val clientMediaId: String,
    val delivered: Boolean,
    val waitingSeconds: Long,
    val expiresAt: String? = null,
    val projectUid: String? = null,
    val fileUid: String? = null,
    val fileId: Long? = null,
)

@Serializable
data class MediaUsage(val usedBytes: Long, val quotaBytes: Long,
    val persistentUsedBytes: Long? = null, val persistentQuotaBytes: Long? = null,
    val persistentQuotaAvailable: Boolean? = null)

@Serializable
data class SubscriptionBalance(val active: Boolean, val availableCents: Long,
    val monthlyLimitCents: Long, val monthlyUsedCents: Long,
    val weeklyLimitCents: Long, val weeklyUsedCents: Long)

/** 统一账户余额（dev-board#425/#429）。金额整数分；plan 是计费档位（paid/free），
 * 不是套餐名，上游没给这个字段时才是 null——不得直接渲染给用户。 */
@Serializable
data class BillingBalance(val balanceCents: Long, val currency: String, val plan: String? = null,
    val subscription: SubscriptionBalance? = null)

/**
 * 信封 code=1 时 /api/mobile/billing 系列接口附带的机器可读判别位（dev-board#425 复审 C2）。
 * 四端一律按它分支，禁止匹配 message 措辞——message 经服务端 LangText 按语言产文案，
 * 英文部署下会整条变英文，硬编码中文串必然全部落空。取值与 contract/api/mobile-v1.yaml
 * 的 Envelope.kind 同一套。
 */
enum class EnvelopeKind {
    DISABLED, UNAVAILABLE, NOT_CONNECTED, NOT_FOUND, REJECTED, REVIEW_ACCOUNT, ALREADY_PAID, IDEMPOTENCY_CONFLICT;

    companion object {
        /** 未知/缺席的 kind 一律解成 null，不猜、不抛——调用方按「读不到」降级。 */
        fun fromRaw(raw: String?): EnvelopeKind? = raw?.let { r -> entries.firstOrNull { it.name == r } }
    }
}

@Serializable
data class UploadResult(val code: Int, val id: Long, val clientMediaId: String, val delivered: Boolean,
                        val projectUid: String? = null, val fileUid: String? = null, val fileId: Long? = null)
