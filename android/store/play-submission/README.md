# Google Play 首次发布材料（2026-10-29）

台账：dev-board#1613；配套修复 #1615、网页 #1616。目标包：Android 1.3.1 / versionCode 6 / com.aiworkdeck.mobile。

用户已授权走完 Play 上架流程。软著受理日 2026-09-22，目前审查中，继续正常等待；Play 材料与国内软著审查分别推进。

## 发布边界

从已打包的稳定提交 ef0cb213 叠加本次首次上架修复构建，不把 main 后续个人助理/日历功能加入首发。Play 分发包切换中国区后仍不显示外部充值或尽调商业网页入口；注册与密码重置使用无购买导航的手机专用网页。

## 材料

- `listing-en-US.txt`：英文标题、简短说明、正文与版本说明；默认 en-GB 可复用。
- `listing-zh-CN.txt`：简体中文版本。
- `data-safety.md`：依据当前稳定代码与生产只读核验填写的声明。
- `foreground-services.md`：后台录音和用户主动传输的说明与录像要求。
- 原位商店图标：`../icon-512.png`；英文特色图片：`../feature-graphic-1024x500-en.png`。

审核专用登录信息只写入受控商店后台，不入库。实际登录选 Mainland China → Phone → App review access，使用原位专用审核身份及固定码。该身份已有测试余额，本次设置90天免费审核权益，至2027-01-27；未创建付费订单。后续上架审核前重新核验权限有效期。

## 公开网址

- Play 应用内隐私政策：`https://workdeck.ai/mobile-account/en/privacy?site=intl`
- 商店账户/部分数据删除申请：`https://workdeck.ai/en/legal/mobile-account-deletion`
- 国际手机注册/重置：`https://workdeck.ai/mobile-account/en?site=intl&flow=register` / `?flow=reset`
- 中国区手机注册/重置：`https://www.aiworkdeck.com/mobile-account/zh?flow=register` / `?flow=reset`

移动账户/政策页面已随官网 PR302 部署两区；PR305 补不保存Cookie时的区域保持和正式包视频，最终公网核验记录在执行证据目录。

## 本次进度

- 稳定发布提交：`436358f4c4f936de4cc855900b4c5d7a7620c835`。Intl AAB SHA-256：`d0ad256f0f3cd6ac71a43601accb4512a4a6932cb4bd1f16a6d29c26b8cc0657`；API 回执 versionCode 6、哈希相同。
- 主线集成 PR77 已于 2026-10-29 合并为 `f94da556d1d006d20fc298487011f5a055fdbda8`。后续个人助理/日历保留在主线，没有加入本次稳定发布包。
- Console 已保存无广告、非政府、无金融功能、无健康功能、无广告 ID；类别 Productivity；18+目标用户；IARC 分级 Everyone/PEGI3 等；隐私政策、审核专用登录与9类数据安全。
- Microphone 选 Background audio input；Data sync 选 Network processing / Other（upload/download）；分别填写正式包演示视频。发布校验中的权限错误已解除。
- 已保存生产版 1.3.1(6)，177个地区（176个列名地区及Rest of world），不包含中国大陆。发布总览共13项待提交变更，包含三语详情及所有声明。
- en-GB/en-US/zh-CN 各5张正式Intl包实图均已上传并回读哈希及顺序。中文图从正式Intl包切换中文后获取，国内CN包图片未混用到Play（渠道入口不同）。
- 唯一发布提示为未提供混淆映射；此稳定包未启用R8混淆，未编造映射文件。

2026-10-29 Google 自动快速检查已通过，页面显示可提交审核；此时尚未点击最终 Submit changes for review。后续会话继续时，宿主的本地浏览器使用被关闭，阻止最后的 Console 点击，已请用户恢复入口或自行提交。API提交素材不等于Console已送审。最终状态须回读；没有 In review 前不写已提审，没有公开商店页前不写已上线。

## 产物与证据

正式包、签名与哈希：`~/.codex/artifacts/2026-10-29-android-launch-1613/release/`。
实际截图与录像：`~/.codex/artifacts/android-1615/`。
完整执行证据：`~/.codex/artifacts/2026-10-29-android-launch-1613/STATUS.md`。

## 验证范围

稳定版两 flavor 各124项JVM；主线各130项及249项Node；PR Android、contract、iPhone及duo检查均通过。真实模拟器执行首次隐私拒绝/同意、审核登录、照片和录音、后台通知、中转暂存及PNG云预览。模拟器结果不替代真机来电/锁屏完整矩阵。电脑离线，暂存不能称为已落盘。
