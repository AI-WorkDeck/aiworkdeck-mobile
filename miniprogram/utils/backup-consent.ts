import { backupConsent, setBackupConsent, getSession, type BackupConsent } from './api'
import { t } from './i18n'

let promptSession: string | null = null
/** No local grant: only a saved server decision authorizes backup and later offline retrieval. */
export async function chooseBackupConsent(current: BackupConsent): Promise<BackupConsent> {
  const session = getSession()
  const { confirm } = await wx.showModal({
    title: t('backup.title'),
    content: t('backup.message') + (current.subscriptionActive ? '' : '\n\n' + t('backup.subscriptionRequired')),
    showCancel: current.subscriptionActive,
    confirmText: t(current.subscriptionActive ? 'backup.enable' : 'backup.decline'),
    cancelText: t('backup.decline'),
  })
  if (session !== getSession()) throw new Error(t('backup.error'))
  return setBackupConsent(current.subscriptionActive && confirm)
}
export async function promptBackupOnFirstUse(): Promise<void> {
  const session = getSession()
  if (!session || promptSession === session) return
  promptSession = session
  try {
    const current = await backupConsent()
    if (session !== getSession()) return
    if (!current.decided) await chooseBackupConsent(current)
  } catch {
    if (session === getSession()) wx.showToast({ icon: 'none', title: t('backup.error') })
  } finally { if (promptSession === session) promptSession = null }
}
