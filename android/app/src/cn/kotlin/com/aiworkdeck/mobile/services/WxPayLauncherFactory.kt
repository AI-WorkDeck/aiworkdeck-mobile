package com.aiworkdeck.mobile.services

import android.content.Context
import com.aiworkdeck.mobile.BuildConfig
import com.tencent.mm.opensdk.modelpay.PayReq
import com.tencent.mm.opensdk.openapi.WXAPIFactory

/**
 * 大陆版：微信 OpenSDK 调起 APP 支付（dev-board#428）。AppID 来自 BuildConfig.WXPAY_APP_ID
 * （空串时根本走不到这里，见 wxpayAppEnabled）。结果由 cn.wxapi.WXPayEntryActivity 投回 [WxPayResults]。
 */
fun wxPayLauncher(context: Context): WxPayLauncher? {
    val appId = BuildConfig.WXPAY_APP_ID
    if (appId.isBlank()) return null
    val api = WXAPIFactory.createWXAPI(context.applicationContext, appId, true)
    api.registerApp(appId)
    return object : WxPayLauncher {
        override fun installed(): Boolean = api.isWXAppInstalled
        override fun send(params: AppPayParams): Boolean {
            // 服务端签的 AppID 与本包登记的不是同一个：微信只会回一个笼统的 -1，不如直接按失败处理
            if (params.appId != appId) return false
            val req = PayReq().apply {
                this.appId = params.appId
                partnerId = params.partnerId
                prepayId = params.prepayId
                packageValue = params.packageValue
                nonceStr = params.nonceStr
                timeStamp = params.timeStamp
                sign = params.sign
            }
            return api.sendReq(req)
        }
    }
}
