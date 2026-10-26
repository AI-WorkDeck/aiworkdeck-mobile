import { t } from '../../utils/i18n'
import { accountFlowUrl } from '../../utils/account-flow'

/** Fixed origin only: never accept an arbitrary URL or pass credentials in the URL. */
Page({
  data: { url: '', failed: false, errorText: t('login.webError'), hint: t('login.webFallback'), copyText: t('login.copyWebAddress') },
  onLoad(query: Record<string, string | undefined>) {
    this.setData({
      url: accountFlowUrl(query.flow, query.ref),
      errorText: t('login.webError'),
      hint: t('login.webFallback'),
      copyText: t('login.copyWebAddress'),
    })
  },
  onWebError() { this.setData({ failed: true }) },
  onCopyUrl() { wx.setClipboardData({ data: this.data.url }) },
})
