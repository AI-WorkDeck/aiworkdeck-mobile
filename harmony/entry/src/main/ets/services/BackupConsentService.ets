import { ServiceLocator } from './ServiceLocator'
import { BackupConsent } from '../model/ProjectFiles'
import { tr } from '../design/L10n'
import { ScreenshotMode } from '../ScreenshotMode'
import { ApiError } from '../model/Envelope'

export class BackupConsentService {
  private static prompting: boolean = false

  static async promptFirstUse(ui: UIContext, alive: () => boolean): Promise<void> {
    if (ScreenshotMode.enabled || BackupConsentService.prompting) return
    BackupConsentService.prompting = true
    try {
      const session: string | null = await ServiceLocator.session.current()
      if (session === null) return
      const current: BackupConsent = await ServiceLocator.backend.backupConsent()
      if (!alive() || session !== await ServiceLocator.session.current() || current.decided) return
      await BackupConsentService.choose(ui, current, session, alive)
    } catch (_) {
      if (alive()) ui.getPromptAction().showToast({ message: tr('backup.error') })
    } finally { BackupConsentService.prompting = false }
  }

  static async choose(ui: UIContext, current: BackupConsent, session: string, alive: () => boolean): Promise<BackupConsent> {
    const decision: boolean | null = await new Promise<boolean | null>((resolve: (value: boolean | null) => void): void => {
      ui.showAlertDialog({ title: tr('backup.title'),
        message: current.enabled ? tr('backup.disableMessage') : tr('backup.message') +
          (current.subscriptionActive ? '' : '\n\n' + tr('backup.subscriptionRequired')),
        autoCancel: true, cancel: (): void => resolve(null),
        primaryButton: { value: tr(current.enabled ? 'common.cancel' : 'backup.decline'), action: (): void => resolve(current.enabled ? null : false) },
        secondaryButton: { value: tr(current.enabled ? 'backup.disable' : current.subscriptionActive ? 'backup.enable' : 'backup.decline'),
          action: (): void => resolve(!current.enabled && current.subscriptionActive) },
      })
    })
    if (!alive() || session !== await ServiceLocator.session.current()) throw new ApiError(1, tr('backup.error'))
    if (decision !== null) await ServiceLocator.backend.setBackupConsent(decision, session)
    const updated: BackupConsent = await ServiceLocator.backend.backupConsent()
    if (!alive() || session !== await ServiceLocator.session.current()) throw new ApiError(1, tr('backup.error'))
    return updated
  }
}
