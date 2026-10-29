# 数据安全申报依据

对象：稳定版 ef0cb213 + #1615，Android Play 1.3.1（6）。2026-10-29 已在 Console 完整保存并回读确认；保存不等于 Google 已审核。

- 收集数据：是。传输加密：是（HTTPS）。
- 账户创建：Username, password and other authentication。普通注册需邮箱/手机号验证码，然后设置密码；审核固定码不是普通用户创建方式。
- 请求账户删除：是，已填写 https://workdeck.ai/en/legal/mobile-account-deletion ，公开页可访问；用户确认支持邮箱正常收信。
- 请求部分数据删除：是，同一公开页说明申请方式。
- 独立安全审核、印度 UPI 认证：不声明。

| 数据类型 | 收集 | 必需性 | 用途 |
|---|---|---|---|
| Email address | 是 | 选择邮箱账户时需要；中国区手机号账户可不提供 | 账户管理、应用功能、安全 |
| Phone number | 是 | 选择中国区手机号账户时需要；国际邮箱账户可不提供 | 账户管理、应用功能、安全 |
| User IDs | 是 | 账户功能必需 | 账户管理、应用功能、安全 |
| Photos | 是 | 用户选用采集/传输时 | 应用功能 |
| Videos | 是 | 用户选用采集/传输时 | 应用功能 |
| Voice or sound recordings | 是 | 用户选用录音/传输时 | 应用功能 |
| Files and docs | 是 | 用户选用项目文件功能时 | 应用功能 |
| Device or other IDs | 是 | 设备关联与传输必需，使用安装随机UUID | 应用功能、安全 |
| Purchase history | 是 | 查询既有余额、订阅与传输计费时 | 应用功能、账户管理 |

上述收集均不按“仅在内存中临时处理”豁免。当前未接广告/行为分析 SDK，不声明广告、营销、个性化或分析用途。

不申报上传定位：当前 Android CaptureManifest 中的精确/近似位置仅保存在本地；上传 multipart 不带该记录，相机文件也未注入 GPS EXIF/视频位置。可选本地定位仍在隐私政策说明。当前没有读取通讯录、短信、通话记录或系统日历的功能。

分享：按 Google 对受托处理者和用户主动传输的例外填写不分享。适用前提是云服务、邮件短信仅作为服务处理者，采集内容只投递到用户授权的桌面/项目，不出售、不用于广告或模型训练。新增用途或 SDK 后必须重新核验。

保留：两区当前生产 backend.jar 实际实现30天中转清理，两个 OSS 桶实际 mobile-relay/ 生命周期35天兜底；持久备份为另一条明确选择的功能，不套用中转期限。账户删除不远程删除手机、相册、导出或已归档电脑的副本；依法保留的记录及异步存储清理在网页逐项说明。

官方依据：[填写数据安全部分](https://support.google.com/googleplay/android-developer/answer/10787469)、[账户删除要求](https://support.google.com/googleplay/android-developer/answer/13327111)。

## 已公布的后续定位政策

截至2026-10-29，Google已公布 Android17/API37 的一次性精确定位 Location Button 要求，2026年11月开放声明、2027-01-27起执行。当前首发没有后台定位；下一次定位适配应评估拍摄标记使用 Location Button，不能用本次前台权限改动宣称已满足未来接口要求。依据：[最小定位范围](https://support.google.com/googleplay/android-developer/answer/17033915)。
