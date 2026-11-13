package com.aiworkdeck.mobile.cn.wxapi

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.aiworkdeck.mobile.BuildConfig
import com.aiworkdeck.mobile.services.WxPayResults
import com.aiworkdeck.mobile.services.wxPayOutcome
import com.tencent.mm.opensdk.constants.ConstantsAPI
import com.tencent.mm.opensdk.modelbase.BaseReq
import com.tencent.mm.opensdk.modelbase.BaseResp
import com.tencent.mm.opensdk.openapi.IWXAPI
import com.tencent.mm.opensdk.openapi.IWXAPIEventHandler
import com.tencent.mm.opensdk.openapi.WXAPIFactory

/**
 * 微信支付回调入口。类名与包名（applicationId + ".wxapi.WXPayEntryActivity"）是微信写死的约定，不能改。
 * 只把 errCode 转成 WxPayOutcome 投给充值页，然后立刻关掉；**这个结果不是到账凭据**——
 * 充值页拿到后一律去查单（外部伪造一个「成功」也只会触发一次查单）。
 */
class WXPayEntryActivity : Activity(), IWXAPIEventHandler {
    private lateinit var api: IWXAPI

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        api = WXAPIFactory.createWXAPI(this, BuildConfig.WXPAY_APP_ID, true)
        if (!api.handleIntent(intent, this)) finish()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (!api.handleIntent(intent, this)) finish()
    }

    override fun onReq(req: BaseReq?) { finish() }

    override fun onResp(resp: BaseResp?) {
        if (resp?.type == ConstantsAPI.COMMAND_PAY_BY_WX) WxPayResults.deliver(wxPayOutcome(resp.errCode))
        finish()
    }
}
