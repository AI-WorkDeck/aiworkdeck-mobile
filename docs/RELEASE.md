# 正式上架流程

本页介绍 iOS 与微信小程序的商店流程。Android 签名交付见 [android/README.md](../android/README.md)，
鸿蒙见 [harmony/README.md](../harmony/README.md)。iOS 走 App Store 审核，小程序走微信公众平台审核。
TestFlight / 体验版的日常发布见 `fastlane/Fastfile` 的 `beta` 与
`scripts/mp-upload.js`，这份文档只讲**正式上架**。

分工的口径：能用 API 做的都收在 `scripts/asc-listing.py`，凭据从
`fastlane/.env` 读（内容见 `5-Tech/EXTERNAL_SERVICES.md` §6）。剩下几项
Apple 没开放 API，只能在网页做，逐条列在第 3 节——那几项没做完，提审会被挡。

尽调协作的版本安排、在审版本保护和命令见 [本轮发布准备](releases/2026-10-22-dd-client.md)。

```bash
set -a; . fastlane/.env; set +a
.venv/bin/python scripts/asc-listing.py status   # 提审前体检，随时可跑
```

## 1. iOS App 的基本信息

| 项 | 值 |
|---|---|
| Bundle ID | `com.aiworkdeck.mobile.cn`（`.cn` 后缀与 App 备案绑定，不可改） |
| ASC App ID | 6803309103 |
| 发布主体 | 北京京微资易（`8WKHZVR2W8`） |
| 上架区域 | **全球 175 个区**（2026-09-05 起） |
| 文案语言 | zh-Hans（主语言）+ en-US（1.0.1 起） |
| fastlane lane | `release`（CI 是 `ci_appstore`） |
| Xcode target | `Workdeck` + `WorkdeckLiveActivity` + `WorkdeckWatch`（scheme `Workdeck`） |

> 历史：iOS 曾有第二条 App 记录（香港主体，`com.aiworkdeck.mobile`，Team
> `X9B97KVA84`），1.0.0(19) 被 4.3(a) Spam 驳回，2026-09-05 起整体并入北京主体，
> 那条 App 记录已删除、工程与 CI 里的对应部分已清理（dev-board#445、#446、#450）。

### 1.1 描述文件

App 是**三个 bundle**：主 App、录音 Live Activity 扩展和 Watch App，
各要一份 App Store 描述文件。三份都不走 `sigh`（Distribution 证书 579SG95VN2 的
私钥是本机 openssl 生成的，fastlane 拿不到），由人在 ASC 建好后进 CI secret。

| Bundle ID | 描述文件名 | 来源 |
|---|---|---|
| `com.aiworkdeck.mobile.cn` | `AI WorkDeck AppStore` | 人工在 ASC 建，CI secret `APPSTORE_PROFILE_B64` |
| `com.aiworkdeck.mobile.cn.LiveActivity` | `AI WorkDeck LiveActivity AppStore` | 用 ASC API 建（同一张 Distribution 证书 579SG95VN2），CI secret `LA_PROFILE_B64`；文件与 ID 见总表 §6.7 |
| `com.aiworkdeck.mobile.cn.watchkitapp` | `AI WorkDeck Watch AppStore` | CI secret `WATCH_PROFILE_B64`；文件与 ID 见总表 §6.7 |

扩展的描述文件或 secret 缺失时，`ci_appstore` 会在 exportArchive 因扩展没有描述文件
而失败——先把 secret 补上再跑。

## 2. 命令序列

先读 ASC 的当前版本状态。存在正在审核的版本时，可以上传下一版本的 TestFlight 构建，
但不要直接运行 `setversion` / `text` / `attach`：脚本没有找到可编辑版本时会返回最新版本，
可能选中现有审单。等待现有版本上架，再创建本次版本记录并核对版本号后继续。

**先看打包机的系统**：`sw_vers` 显示 beta（BuildVersion 形如 `26A5421a`，
数字长、小写字母结尾）就**不要在本机打正式包**——包里的 `BuildMachineOSBuild`
会带 beta 系统号，提审必被 ITMS-90111 打回，Xcode/SDK 是正式版也救不回来
（2026-09-01 三个包实测；Apple 邮件只提 Xcode/SDK，别被带偏）。本机是 beta 时
走 CI：push 一个 commit message 含 `[appstore]` 的提交，GitHub Actions 会在
发行版 macOS 上打包上传（`.github/workflows/appstore-build.yml`，签名材料在
repo secrets，lane 是 `ci_appstore`）。

```bash
set -a; . fastlane/.env; set +a

# 打包并上传（构建号自动取线上最大值 +1）——仅当本机是发行版 macOS
fastlane ios release

# 等构建处理完（几分钟，ASC 上从 PROCESSING 变 VALID），然后挂版本
.venv/bin/python scripts/asc-listing.py attach <构建号>

# 文案 / 分级 / 定价 / 区域（已经跑过一遍，改了再跑）
.venv/bin/python scripts/asc-listing.py text
.venv/bin/python scripts/asc-listing.py rating
.venv/bin/python scripts/asc-listing.py price
.venv/bin/python scripts/asc-listing.py availability

# 体检 → 提审
.venv/bin/python scripts/asc-listing.py status
.venv/bin/python scripts/asc-listing.py submit --yes
```

`submit` 不加 `--yes` 只打印将要提交什么，不会真提交。

`release` 与 `beta` 走的是**同一条上传通道**：ASC 里 TestFlight 与
App Store 共用同一批构建，选哪个发布是版本记录那边的事。一度改用
`upload_to_app_store`（deliver）一把梭，fastlane 2.235.0 上它在 spaceship 解析
回包时抛 `No data`（上游已知问题），而升 fastlane 会连带动到现役的 beta lane，
所以 App Store 侧全部改成直接打 REST API。

## 3. 只能在网页做的几项

Apple 没开放 API，或属于必须由人做的声明。**这几项不做完，提审必被挡。**

### 3.1 App 隐私（营养标签）

ASC →「App 隐私」→ 逐项勾。按代码实际行为，答案是：

| 数据类型 | 用途 | 是否关联身份 | 是否用于追踪 |
|---|---|---|---|
| 联系信息 → 邮箱地址 | App 功能 | 是 | 否 |
| 联系信息 → 电话号码 | App 功能 | 是 | 否 |
| 位置 → 精确位置 | App 功能 | 是 | 否 |
| 用户内容 → 照片或视频 | App 功能 | 是 | 否 |
| 用户内容 → 音频数据 | App 功能 | 是 | 否 |

依据：手机号/邮箱是登录标识；GPS 坐标与精度写进每张影像的归档信息
（`CaptureManifest`）；照片/录像/录音经中转区传到桌面端。没有广告标识符、
没有第三方分析 SDK，所以「用于追踪」一律否。

### 3.2 中国大陆 ICP 备案号

ASC → App 信息 →「App Store 法规和许可 / 中国大陆 ICP 备案号」填
`京ICP备2024096997号-13A`。会自动与工信部库比对**App 名称与主体**，
必须逐字一致——所以应用名不能改动，保持 `AI WorkDeck`。

### 3.3 审核联系信息与演示账号

`fastlane/metadata/review_information/` 下有三个 `.example`，
复制成同名 `.txt` 填写（实文件已 gitignore，公开仓不收个人信息与凭据）。

必须填：登录只有验证码一条路，而审核员既收不到中国短信，也打不开
我们的邮箱。内核仓已经加了固定验证码旁路（`config/ReviewAccountGate`，
aiworkdeck#680），服务器上按下面三步启用：

1. 选一个审核专用标识（邮箱或手机号）。**不要用真人账号的邮箱/手机号**——那 6 位码
   是写在 ASC 审核备注里给外部人看的，绑到真人账号上就等于把真账号的钥匙给出去。
   不需要事先注册：旁路命中时会给这个标识建一个专用空账号
   （`UserService#findOrCreateReviewAccount`，displayName `App Review`）。

   > 早先一版要求「事先注册好并验过邮箱」，那条路走不通：`verified_email` 全仓
   > 只有登录后绑定一处写入，等于必须绑到真人账号上。已改成建号（aiworkdeck#682）。

2. 在 `/opt/aiworkdeck/cloud/env` 追加两行，然后重启：

   ```
   AUTH_REVIEW_ACCOUNT_IDENTITY=appreview@example.com
   AUTH_REVIEW_ACCOUNT_CODE=246813
   ```

3. 把这个标识与固定码写进 `review_information/demo_user.txt`、
   `demo_password.txt`。

**审核员登录之后还会撞一堵墙**：项目列表来自桌面端推的目录镜像，新账号是空的，
项目选择页的空状态写着「在电脑上用同一手机号登录并保持运行」——审核员没有桌面端，
到不了取景页。真实新用户第一次打开撞的是同一堵墙。上线前必须解掉，两条路见
dev-board#345 的讨论（给审核账号种一个项目 / App 支持无项目先拍）。

审核结束后清空 `AUTH_REVIEW_ACCOUNT_IDENTITY` 即可关掉旁路。

### 3.3.1 顺带：邮箱登录开关

**已开（2026-09-01）**：北京 ECS `/opt/aiworkdeck/cloud/env` 里已加
`MAIL_PASSWORDLESS_LOGIN_ENABLED=true` 并重启，实测未注册地址回 `code 0`，
短信那条不受影响。原 env 备份在同目录 `env.bak-20260901-mailpwdless`。
下面留作重装机器时的参考。

邮箱登录是境外审核员与境外用户唯一能用的登录方式，服务端默认关着。同一个 env 文件里：

```
MAIL_PASSWORDLESS_LOGIN_ENABLED=true
```

`mail.passwordless-login-enabled` 只是**其中一个**条件，还要至少一条发信通道是
开的（`MAIL_DOMESTIC_ENABLED` 走阿里云、`MAIL_GLOBAL_ENABLED` 走 Resend）——
两者缺一，`passwordlessActive()` 都是 false，报的还是同一句「邮箱登录未启用」，
从报错分不出是哪一个。审核员的邮箱多半是境外域名，所以 `MAIL_GLOBAL_ENABLED`
这条尤其要确认。

改完重启并验证：

```bash
sudo systemctl restart aiworkdeck-cloud
journalctl -u aiworkdeck-cloud -n 50 --no-pager
# 拿一个**没注册过**的地址探开关：回 code 0 说明开关已开（未注册地址后端
# 静默不发信但照常回成功，这是防账号枚举，不是发信成功）
curl -s -X POST https://addin.aiworkdeck.com/api/auth/mail-login/send-code \
  -H 'Content-Type: application/json' -d '{"email":"nobody@example.com"}'
# 再拿一个**已注册并验过邮箱**的地址试，确认真能收到信
```

### 3.4 截图

ASC → 版本 → 媒体，或用 deliver 传 `fastlane/screenshots/`。
尺寸要 6.9"（1320×2868，iPhone 17 Pro Max / 16 Pro Max），至少一张。

**必须用真机拍。** 模拟器里取景框是纯黑（没有摄像头）、影像库是空缩略图，
拿这种图上架既难看也不实。真机上把演示项目拍几张，再截这几屏：

- 取景首页（照片模式，有实时取景与底部 SHA-256 / GPS / 时间戳标识）
- 影像库（有内容的九宫格，能看见待传/传输中/已抵达三种状态点）
- 上传队列
- 设置页

`AppModel` 里有 `-AWDScreenshotMode` 启动参数（**只编进 Debug**），跳过登录
直接摆出 `DemoData` 的项目与统计，省得为截图去准备账号；影像本身仍需真拍。

## 4. 微信小程序提审（以下为历史 0.29.0 操作记录）

以下记录不代表当前线上版本或登录方式。每次发版先核对公众平台版本管理和当前应用的实际登录入口；
尽调协作还需配置并真机验证 `case.aiworkdeck.com` 的业务域名，不能用开发工具的 `urlCheck: false` 代替。

小程序的提审与发布只能维护者在公众平台手点，`scripts/mp-upload.js` 只负责
把包传到「版本管理」。0.29.0 已上传并已设为体验版（2026-08-31）。

1. 公众平台 → 管理 → 版本管理 → 开发版本 0.29.0 →「提交审核」。
2. 填**功能页面**（最多 5 个）。当前值得报的：`pages/start/start`（扫码引流
   落地页）、拍摄页、影像库、上传队列、设置。
3. 类目要与已选服务类目一致；说明里写清「现场拍摄与归档，面向企业尽调/审计场景」。
4. **测试账号**：小程序登录走 `getPhoneNumber` 一键授权，审核员用自己的微信号
   即可完成，不需要额外账号——在补充说明里写明这一点。
5. 隐私保护指引与服务器域名在 2026-08-31 已配好（dev-board#305），提审前扫一眼没被改回去。

发布之后还有一步：dev-board#305 的 `WX_START_MINIAPP` 开关要等**正式发布版
存在**才能置 1——URL Link 对只有体验版的小程序返回 85079，体验版也不行。

## 5. 过审之后

版本设成了「手动发布」（`releaseType: MANUAL`——ASC 的默认值是
`AFTER_APPROVAL`，即过审自动上架，`setversion` 会把它改掉），
过审后要人去点发布。这样能把 iOS 与小程序凑到同一天放出去。
