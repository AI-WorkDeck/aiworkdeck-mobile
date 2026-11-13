package com.aiworkdeck.mobile.services

import com.aiworkdeck.mobile.design.tr
import kotlinx.serialization.SerializationException
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.UnknownHostException
import javax.net.ssl.SSLException

/**
 * 给用户看的失败原因，界面与队列行只用这一个。系统异常原文（「Unable to resolve host…」
 * 「timeout」）用户没法据此行动，换成词典里的说法；业务错误（[ApiError]）保留服务端文案。
 *
 * 应用自己用 check/require 抛的 IllegalState/IllegalArgument 带的是 tr() 过的文案，照用；
 * 但 JSON 解析异常与数字格式异常也是 IllegalArgument 的子类、带英文原文，先拦下。
 */
fun userFacingMessage(e: Throwable, fallback: String = tr("error.network")): String = when (e) {
    is Unauthorized -> tr("error.unauthorized")
    is SessionSaveFailed -> tr("error.sessionSaveFailed")
    is ApiError -> e.message?.takeIf { it.isNotBlank() } ?: fallback
    is UnknownHostException, is ConnectException, is NoRouteToHostException, is SSLException -> tr("error.unreachable")
    is IOException -> tr("error.network")
    is SerializationException -> tr("error.badResponse")
    is NumberFormatException -> fallback
    is IllegalStateException, is IllegalArgumentException -> e.message?.takeIf { it.isNotBlank() } ?: fallback
    else -> fallback
}
