package com.aiworkdeck.mobile.services

import android.content.Context

/** 国际版不带微信 OpenSDK，也不开微信 APP 支付（wxpayAppEnabled 对 intl 恒 false）。 */
@Suppress("UNUSED_PARAMETER")
fun wxPayLauncher(context: Context): WxPayLauncher? = null
