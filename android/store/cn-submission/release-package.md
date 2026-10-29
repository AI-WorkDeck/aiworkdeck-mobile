# 本次国内签名候选包

核对日期：2026-10-29；应用 AI WorkDeck；包名 `com.aiworkdeck.mobile.cn`。

| 字段 | 当前核验值 |
| --- | --- |
| 版本 | 1.3.1 / versionCode 6 |
| 源码提交 | `436358f4c4f936de4cc855900b4c5d7a7620c835` |
| 文件 | `AI-WorkDeck-Android-CN-1.3.1-6.apk` |
| 文件大小 | 41,756,413 字节 |
| 文件 SHA-256 | `c437b447a2f887166659017df87dd61e6beb1a73e16164dabc268eb68cc7f91f` |
| 签名证书 SHA-256 | `6f1c370709491cc7ecbfa2d20b7968817bbdebb6d395d0dcf143fc39a5f013df` |
| 与上一次国内正式包签名一致 | 核验记录为 `true` |
| 与备案后台登记签名一致 | 尚未核对；不能用历次发版签名一致替代 |

文件位置：[国内 APK](</Users/zewei/.codex/artifacts/2026-10-29-android-launch-1613/release/AI-WorkDeck-Android-CN-1.3.1-6.apk>)；核验来源：[release-verification.json](</Users/zewei/.codex/artifacts/2026-10-29-android-launch-1613/release/release-verification.json>)。本轮独立重新计算 CN APK 及 Intl APK / AAB 的字节数和 SHA-256，均与该记录一致；签名结论依据主任务的签名工具核验记录。

本包以 1.3.0 的 `ef0cb213` 为稳定基线，只加入 #1615 修复，不包含新个人助理。主线已经集成相同修复且保留个人助理 / 日历功能；主线产物不能代替这里的候选包。若候选代码或文件后续改变，须重新签名、核验并同步本页，不能沿用旧哈希。

## 已核网页

以下地址于 2026-10-29 实测返回 HTTP 200：

- [中国区安卓隐私政策](https://www.aiworkdeck.com/zh/legal/mobile-privacy)
- [中国区账户及数据删除说明](https://www.aiworkdeck.com/zh/legal/mobile-account-deletion)
- [国际区移动端隐私政策](https://workdeck.ai/mobile-account/en/privacy?site=intl)
- [国际区移动端删除说明](https://workdeck.ai/mobile-account/en/deletion?site=intl)

国际入口保留 `site=intl`。PR #305 已完成两区部署；2026-10-29 08:06:25 UTC 从北京无 Cookie GET 验证隐私、删除及注册入口均直接 HTTP 200、零重定向，最终 URL 保留原国际域名与参数，正文为香港运营主体。原先无 Cookie 会跳回中国区的问题已修复。证据为 `/Users/zewei/.codex/artifacts/android-1615/website-deploy-verification/pr305-beijing-no-cookie-live.json`。网页可访问不代表六店后台已经填写或保存。用户已确认两个 `hi` 客服邮箱能正常收信；各店后台联系人和审核测试账号仍须在登录后核对。

## 验证边界

稳定包对应代码的 cn / intl JVM 报告各 124 项且零失败；本轮独立复核了报告和新增上传等待 / 取消测试。主线集成保留 `personalConsentVersion`、全部原有 personal 文案及 `calendarEventId` 传入 Root，主线 cn / intl JVM 报告各 130 项且零失败。共用审核账号的正式 CN 登录、示例采集和中转暂存已实测；上述不替代各店检测、备案后台签名核对，以及尚未覆盖的桌面 ACK、中国区文件预览和独立账号注销分支。正式中文商店截图五张已冻结并逐张目视、尺寸、字节数和哈希核对，见素材清单。
