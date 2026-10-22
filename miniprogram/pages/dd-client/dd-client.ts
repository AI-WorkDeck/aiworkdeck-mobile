// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { DD_CLIENT_PORTAL_URL } from '../../utils/contract/capabilities'
import { t } from '../../utils/i18n'
Page({
  data: { portalUrl: DD_CLIENT_PORTAL_URL },
  onLoad() { wx.setNavigationBarTitle({ title: t('dd.title') }) },
  onPortalError() { wx.showToast({ title: t('dd.openFailed'), icon: 'none' }) },
})
