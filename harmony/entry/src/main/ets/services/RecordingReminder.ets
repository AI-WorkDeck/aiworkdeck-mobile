import { notificationManager } from '@kit.NotificationKit'
import { bundleManager, wantAgent, WantAgent, common } from '@kit.AbilityKit'
import { ServiceLocator } from './ServiceLocator'
import { tr } from '../design/L10n'

/** Permission rejection never prevents recording or causes it to stop. */
export class RecordingReminder {
  private static asked: boolean = false
  private static readonly id: number = 1410

  static async prepare(): Promise<boolean> {
    try {
      if (await notificationManager.isNotificationEnabled()) return true
      if (!RecordingReminder.asked) {
        RecordingReminder.asked = true
        await notificationManager.requestEnableNotification(ServiceLocator.ctx as common.UIAbilityContext)
      }
      return await notificationManager.isNotificationEnabled()
    } catch (_) { return false }
  }

  static async show(): Promise<boolean> {
    try {
      if (!await notificationManager.isNotificationEnabled()) return false
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      const agent: WantAgent = await wantAgent.getWantAgent({
        wants: [{ bundleName: info.name, abilityName: 'EntryAbility' }],
        actionType: wantAgent.OperationType.START_ABILITY, requestCode: RecordingReminder.id,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      })
      await notificationManager.publish({ id: RecordingReminder.id,
        content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: tr('rec.silence.title'), text: tr('rec.silence.message') } },
        wantAgent: agent,
      })
      return true
    } catch (_) { return false }
  }

  static cancel(): void {
    notificationManager.cancel(RecordingReminder.id).catch((): void => {})
  }
}
