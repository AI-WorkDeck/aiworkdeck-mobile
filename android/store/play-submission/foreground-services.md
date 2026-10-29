# 前台服务申报与演示

## Microphone

功能：用户主动开始的现场录音。用户切换应用或锁屏后继续录制，持续通知显示状态并可停止。若在后台被立即停止，会中断用户正在记录的现场内容；不可延迟为稍后执行。录音由用户开始与停止，不自动监听。

演示须完整显示：打开应用 → 选择录音 → 主动开始 → 回到系统桌面 → 通知持续显示 → 回到应用 → 停止 → 已保存录音。使用专用审核账号和非私人测试内容，不录真实会议或私人环境声音。

## Data sync

功能：用户把现场采集材料归档到所选项目时，上传队列将文件传入区域中转服务供自己的电脑领取。用户在上传过程中切走后，前台通知显示正在传输状态；若立刻中止，用户已发起的归档无法完成。失败可重试，完成后服务停止。

演示须显示：选择演示项目 → 主动采集/归档 → 上传队列 → 切后台查看通知 → 上传完成/等待电脑状态。不得用示例截图模式代替真实上传结果。

## 已录制的正式包证据

版本：1.3.1 / versionCode 6；稳定提交 436358f4c4f936de4cc855900b4c5d7a7620c835。Manifest 只声明 microphone 与 dataSync 前台服务用途。

- 录音：https://workdeck.ai/android-review/1.3.1/recording.mp4?site=intl （22.53 秒，2,763,167 字节，SHA-256 `53e50463a90cc179cbe6c65b65fb453becff4f0254a3583fda7f28948538afa5`）
- 传输：https://workdeck.ai/android-review/1.3.1/transfer.mp4?site=intl （50.02 秒，4,099,295 字节，SHA-256 `d53156c2bb3733bcd0182394a6563bf74bc7f211974dfed1dadbe33919f7fb79`）

视频来自正式签名 Intl 包和专用模拟器，标题为 AI WorkDeck，没有 Dev 标识。录音显示开始、后台通知、停止与保存。传输视频显示真实上传及后台通知，视频结束时当前件仍在上传，不把视频称为“全程传完”；后续真实队列截图中五件均为 Staged，等待离线电脑领取，不能称为已落盘。没有展示后台定位、自动恢复录音。

录音英文申报说明：
> Users start audio recording from Quick capture to document field work. Recording continues while they switch apps or lock the screen, with an ongoing notification and a stop action. Delaying or interrupting it would lose the ongoing recording. Users explicitly start and stop each recording; the app does not listen automatically.

传输英文申报说明：
> Users capture photos, video or audio and file them into their selected project. A foreground data-sync service keeps this user-initiated file upload running when the user switches apps, with an ongoing upload notification. Interruption would leave the requested transfer incomplete. Files are staged in the regional relay until the user's desktop receives them; failures can be retried. The service stops after its work ends.

官方依据：[前台服务要求](https://support.google.com/googleplay/android-developer/answer/13392821)。
