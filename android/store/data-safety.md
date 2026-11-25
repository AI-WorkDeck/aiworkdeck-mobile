# Google Play Data safety 填表草稿（国际版 / intl flavor）

仅覆盖国际版（`com.aiworkdeck.mobile`，上架 Google Play）。事实来源见任务交底的「数据处理事实」，
以及代码里能直接核实的部分（`android/app/build.gradle.kts` 无广告/分析 SDK 依赖、
`AndroidManifest.xml` 的 `android:allowBackup="false"`）。凡是交底事实里没写清楚、
只能靠猜的地方，标「待核」，不要替 Play 表单编答案。

## 1. Data collection and security（顶层三问）

| 问题 | 答案 |
|---|---|
| Does your app collect or share any of the required user data types? | 是 |
| Is all of the user data collected by your app encrypted in transit? | 是（全部走 HTTPS，`addin.workdeck.ai` / `addin.aiworkdeck.com`） |
| Do you provide a way for users to request that their data is deleted? | 是（应用内设置页可注销账号；另见下方「数据删除」） |

## 2. 数据类型逐项申报

### Personal info（个人信息）
| 数据类型 | 是否收集 | 是否共享 | 用途 | 是否可选 | 备注 |
|---|---|---|---|---|---|
| Email address | 是 | 否 | 账号功能（Account management） | 是，二选一——登录页 `MethodPicker`（`LoginScreen.kt`）在任何 flavor 下都能在邮箱/手机号之间自由切换，`BuildConfig.DEFAULT_LOGIN` 只决定默认选中哪一种，不限制能不能切到另一种；用户选邮箱验证码登录时必需，选手机号登录时不涉及 | 国际版默认邮箱（`DEFAULT_LOGIN="mail"`） |
| Phone number | 是——**此前草稿误判为「国际版不收集」，已订正**：`LoginScreen.kt` 的方式切换不按 flavor 限制，国际版界面同样提供手机号验证码登录选项 | 否 | 账号功能（Account management） | 是，二选一，理由同上；用户选手机号验证码登录时必需，选邮箱登录时不涉及 | 国内版默认手机号（`DEFAULT_LOGIN="sms"`）；国际版虽默认邮箱，但 UI 未屏蔽手机号选项，Play 端需如实申报为「收集」 |
| User IDs | 是（账号会话标识、`session token`） | 否 | 账号功能、App functionality | 否 | 存于设备 `EncryptedSharedPreferences`，不进系统备份 |

### Location（位置信息）
| 数据类型 | 是否收集 | 是否共享 | 用途 | 是否可选 | 备注 |
|---|---|---|---|---|---|
| Precise location | 是 | 否（仅传给开发者自有中转服务器，不算「第三方共享」） | App functionality（写入每张影像的归档信息：GPS 坐标 + 精度） | 是，用户可拒绝定位权限，拍摄仍可进行，只是归档信息不含坐标（见 `permissions.md`） | 与所拍摄的照片/视频/音频文件一起上传，不是独立的位置遥测 |

### Photos and videos / Audio files（用户生成内容）
| 数据类型 | 是否收集 | 是否共享 | 用途 | 是否可选 | 备注 |
|---|---|---|---|---|---|
| Photos | 是 | 否（仅上传到开发者自有中转服务器） | App functionality | 否，核心功能 | HTTPS 上传，桌面端确认落盘后中转副本删除；未取回的保留 30 天兜底 |
| Videos | 是 | 否 | App functionality | 否，核心功能 | 同上 |
| Voice or sound recordings | 是 | 否 | App functionality | 否，核心功能（录音模式） | 同上 |

### Device or other IDs（设备或其他标识符）
| 数据类型 | 是否收集 | 是否共享 | 用途 | 是否可选 | 备注 |
|---|---|---|---|---|---|
| Device or other IDs | 是（应用自行生成的随机设备 UUID，随上传件一起发送） | 否 | App functionality（用于中转服务器识别上传来源/去重，非广告用途） | 否 | **待核**：这是应用生成的随机 UUID，不是硬件 IMEI/SSAID；是否落在 Play 该类别的「必须申报」范围内、还是可以不申报，需要对照 Play 最新分类说明确认 |

### 未收集的类型（明确勾「否」）
- Ads/analytics 相关的所有数据类型（App activity 里的 App interactions、Advertising ID 等）：否——依赖清单里没有任何广告 SDK 或分析 SDK（`android/app/build.gradle.kts` 已核实，只有 CameraX / Media3 / WorkManager / OkHttp / Coil / kotlinx 等功能性依赖）。
- Financial info、Health and fitness、Messages、Web browsing、Contacts、Calendar：否，功能不涉及。
- Name：**待核**——交底事实没提到是否单独采集用户姓名字段；若账号资料页有「姓名」字段需要补充申报，若没有则保持「否」。

## 3. Data sharing（数据共享）

全部「否」：不与第三方共享任何数据。开发者自有的中转服务器（relay server）不构成 Play 定义下的
「第三方共享」——数据仍在开发者控制范围内，且只是转存后即删除，不用于开发者自身以外的任何用途。
无广告 SDK、无分析 SDK，因此不存在"App activity"类别下的第三方数据流出。

## 4. Security practices（安全实践）

| 问题 | 答案 |
|---|---|
| Is data encrypted in transit? | 是，HTTPS |
| Can users request data deletion? | 是 |
| Data encrypted at rest（服务器端） | **待核**——交底事实只说明设备端 session token 用 `EncryptedSharedPreferences` 加密存储，未说明中转服务器磁盘/数据库层是否加密静态数据 |
| Independent security review | **待核**——未获知是否有第三方安全审计 |

## 5. 数据删除路径

- **应用内删除**：设置页可注销账号（触发账号删除）+ 本机数据删除（设备上缓存的影像与队列记录清除）。
- **服务端自动删除**：中转服务器上的影像副本，在桌面端确认文件已落盘后立即删除；未取回的中转文件最长保留 30 天，这只是兜底上限，不是主要删除机制（交底事实原文）。
- **账号删除是否需要额外的网页入口（Play 政策要求账号可创建即需可网页删除的场景）**：**待核**——若账号只能通过 App 内验证码流程创建（无独立网页注册页），按 Play 现行政策应用内删除入口通常已满足要求；若官网另有网页注册入口，则还需要提供网页删除入口链接，需核实 `aiworkdeck.com` 官网是否有独立注册流程。
- Account deletion 表单里如需要填一个可直接访问的 URL：**待核**，交底事实未提供专门的「账号删除」网页链接（只给了隐私政策 URL `https://www.aiworkdeck.com/en/legal/privacy`）。

## 6. 备份与本地存储

- `AndroidManifest.xml` 声明 `android:allowBackup="false"` 且引用 `data_extraction_rules`，
  即取证影像与账号数据不进入 Android 自动备份/云备份——这条不是 Play Data safety 表单的必填项，
  但可以在「Data protection」补充说明里提一句，作为额外的安全实践佐证。
