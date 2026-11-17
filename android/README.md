# aiworkdeck-android

Kotlin + Compose 客户端，双 flavor（`intl` / `cn`），与 `contract/` 生成的 Kotlin 契约共用同一份接口定义（`android/contract/src/main/kotlin/`，由 `contract/tools/*` 生成，不要手改）。

## 构建

```bash
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
cd android
./gradlew :app:assembleIntlDebug :app:assembleCnDebug --console=plain
```

产物：
- `app/build/outputs/apk/intl/debug/app-intl-debug.apk`
- `app/build/outputs/apk/cn/debug/app-cn-debug.apk`

单测（intl flavor）：`./gradlew :app:testIntlDebugUnitTest`

## local.properties（gitignored）

```
sdk.dir=/opt/homebrew/share/android-commandlinetools
```

release 签名（可选，未配置时 release 变体不会有签名，debug 构建不受影响）：

```
signing.cn.storeFile=/path/to/cn.jks
signing.cn.storePassword=...
signing.cn.keyAlias=aiworkdeck-cn
signing.cn.keyPassword=...

signing.intl.storeFile=/path/to/intl.jks
signing.intl.storePassword=...
signing.intl.keyAlias=aiworkdeck-intl
signing.intl.keyPassword=...
```

也可用环境变量 `SIGNING_CN_STOREFILE` / `SIGNING_CN_STOREPASSWORD` / `SIGNING_CN_KEYALIAS` / `SIGNING_CN_KEYPASSWORD`（`SIGNING_INTL_*` 同）代替。

## 版本号

唯一来源是 `android/version.properties`（`versionName` / `versionCode`），两个 flavor 共用同一份，
`app/build.gradle.kts` 从里面读，不要改 build.gradle.kts 里的字面量。CI 需要临时指定时可用
`-PversionCode=` / `-PversionName=` 覆盖（不落盘、不影响仓库里的文件）。

发版前手动把 `version.properties` 里的号提一格再跑 `scripts/android-release.sh`（该脚本不会自己
帮你改版本号）。国内发行（现仅维护应用宝）要求新包的 `versionCode` 严格大于上一次通过审
核的包，单调递增，不能跳号也不能不变；`versionName` 无此限制，跟产品版本走即可。

## 应用名 / 图标

- 商店与桌面显示名唯一来源是 `app/build.gradle.kts` 里 `release` buildType 的
  `resValue("string", "app_label", "AI WorkDeck")`——发版本必须是这个（`beian-android.txt` 备案
  绑定的就是这个名字）；`debug` buildType 是 `"AI WorkDeck Dev"`，用来在桌面上跟正式版区分。
- 图标源是 iOS 图标 `ios/Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png`，
  `scripts/android-icon.sh` 用 ImageMagick 从它生成安卓自适应图标（`mipmap-*/ic_launcher_foreground.png`
  / `ic_launcher_monochrome.png` + `mipmap-anydpi-v26/ic_launcher*.xml` + 白色背景色）和商店大图
  `android/store/icon-512.png`。iOS 图标换了之后重跑一次这个脚本、把生成物一起提交。

## 出签名包

```bash
scripts/android-release.sh
```

做的事：
1. 从 `~/.aiworkdeck/android/keystore-passwords.txt` 读密码，写入/更新
   `android/local.properties` 里的六行 `signing.*`（幂等，不回显口令、不动已有的 `sdk.dir`）。
2. 按 `version.properties` 打印本次 versionName/versionCode。
3. `./gradlew :app:bundleIntlRelease :app:assembleCnRelease`。
4. 用 `apksigner verify --print-certs`（cn APK）和 `keytool -printcert -jarfile`（intl AAB）
   取出签名的 SHA-1 / MD5，和 `~/.aiworkdeck/android/beian-android.txt`（cn）、
   `aiworkdeck-intl.cer`（intl）里备案登记的指纹逐一比对——**任何一项不一致就非零退出**，因为
   备案一旦通过，包名与签名指纹就被锁定（性质与 iOS Distribution 证书绑定备案完全相同）；
   换了 keystore 却继续发包，用户端安装会被判定为「与已备案版本不一致」。
5. 产物连同 `SHA256SUMS` 拷到 `~/.aiworkdeck/android/releases/<versionName>-<versionCode>/`
   （不进仓库）。
6. 打印产物大小与指纹（指纹本身是公开信息，可以打印；口令绝不打印）。

v1 里 `isMinifyEnabled = false`（R8 关闭）是维护者的明确决定，不要顺手打开——真要开启混淆/
压缩是另一张卡的事，牵涉 keep 规则梳理和逐条验证，不能在这个任务里顺带做。

## 模拟器

```bash
avdmanager create avd -n awd -k "system-images;android-36;default;arm64-v8a" --device pixel_7 --force
emulator -avd awd -no-snapshot -no-boot-anim &
```

`android-36;default`（AOSP，无 GMS）而不是 API 37 的 `google_apis` 镜像——无 GMS 的镜像才能如实走查
「不依赖 Google Play services」这条硬约束（见 §「无 GMS 验证」）。1080×2400，与真机常见尺寸一致。

装包、授权（一次性问齐相机/麦克风/定位/通知，模拟器上没有交互式弹窗代劳，得靠 `pm grant`）：

```bash
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
cd android && ./gradlew :app:installCnDebug
adb shell pm grant com.aiworkdeck.mobile.cn android.permission.CAMERA
adb shell pm grant com.aiworkdeck.mobile.cn android.permission.RECORD_AUDIO
adb shell pm grant com.aiworkdeck.mobile.cn android.permission.ACCESS_FINE_LOCATION
adb shell pm grant com.aiworkdeck.mobile.cn android.permission.POST_NOTIFICATIONS
adb shell am start -n com.aiworkdeck.mobile.cn/com.aiworkdeck.mobile.MainActivity
```

录音走前台服务 `RecordingService`（`foregroundServiceType="microphone"`，权限
`FOREGROUND_SERVICE_MICROPHONE`），切后台、锁屏继续录，通知栏常驻计时与「停止录音」；
走查时 `adb shell dumpsys activity services com.aiworkdeck.mobile.cn` 能看到它 `isForeground=true`。

登录走审核/演示账号（见项目记忆 `mobile-local-verify-recipe`，不入仓）。**不带桌面端、只想直奔取景器**（不想每次都走登录+选项目）时，
可以绕过登录后的选项目页，直接给 `Prefs.selectedProject` 灌一条本地项目：

```bash
PKG=com.aiworkdeck.mobile.cn
adb shell run-as $PKG sh -c 'cat > shared_prefs/prefs.xml' <<'EOF'
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <string name="selectedProject">{&quot;deviceId&quot;:&quot;dev-emulator&quot;,&quot;deviceName&quot;:&quot;MacBook Pro&quot;,&quot;key&quot;:&quot;1&quot;,&quot;name&quot;:&quot;走查项目&quot;}</string>
</map>
EOF
```

（这只跳过「选项目」，登录会话仍是真实的——`bootstrap()` 先查 `hasSession()` 再查
`selectedProject`，两者都要有才进主界面；直接改 `shared_prefs/prefs.xml` 是因为 `run-as` 能读写
应用私有目录但没有走 UI 的办法代填表单。） 中转区会接受这个并不存在的桌面端项目的上传件，
7 天后自然清理。

## 走查清单

模拟器（或真机）上手动过一遍，覆盖主链路：

1. 登录（手机号 + 验证码）→ 选项目
2. 取景器拍照 ×3（可混拍照/录像/录音）
3. 上传队列：四段计数（上传中/已暂存/失败/已落盘）、失败行有「重试」
4. 图集：网格/列表切换、按项目分组分日
5. 查看器：全屏、左右滑动、状态点 + sha 前 12 位
6. 设置：存相册开关、中转区归档路径、当前账号、用量
7. 注销登录 → 回登录页

装过 debug 包（`installCnDebug` 等）再装签名 release 包会因为签名不一致被系统拒装
（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`），两者 `applicationId` 相同、签名不同——这是预期行为，
先 `adb uninstall <applicationId>` 再装即可，不是 bug。

## 已知限制

- **英文 UI 未开放**：`L10n.locale` 默认 `zh-Hans`，切到 `en` 会先查词典再回退中文；等
  `contract/strings.json` 的英文列覆盖齐了再开（`android/app/src/main/kotlin/com/aiworkdeck/mobile/design/L10n.kt`）。
- **`GlassBar`（影像浏览顶栏/底座）只做半透明，不做模糊**：Compose 要模糊「这一层下面已经画好的
  内容」得先截屏再滤镜，成本与复杂度都不小；契约 `glassBlur` 安卓填 `false`（iOS 是原生
  `true`，小程序是 `"runtime"` 运行时探测）。见 `android/app/src/main/kotlin/com/aiworkdeck/mobile/design/Components.kt`。
- **中转区到期提醒的说法与 iOS/小程序不一致**：安卓是「中转区 {days} 天后清理」（剩余天数），
  iOS/小程序是「云端保存至 M月D日」（日期）。两句不冲突（`contract check` 能过），只是没统一，
  见 `.superpowers/sdd/2026-09-02-android-client/task-10-report.md`。
- **图集列表视图的单行不带失败原因/sha**：只有 72dp 缩略图 + 状态点 + 状态文字 + 时间 + 类别；
  失败原因原文与 sha 前 12 位要点进全屏查看器才看得到（上传队列页的行本身是带的）。
- **API 31+ 应用在后台时系统不允许前台服务通知，上传照跑但无通知**：`UploadWorker.doWork()`
  的 `setForeground()` 被 Android 12+ 的「后台不许启动前台服务」限制拒绝
  （`ForegroundServiceStartNotAllowedException`），这一步已经包在 `runCatching` 里降级——
  拿不到通知就不举，队列照常跑完；通知栏里因此看不到「正在上传现场影像」那一条。

## CI

`.github/workflows/android.yml`（workflow 名 `android`）：`push`/`pull_request` 触及
`android/**`、`contract/**` 时跑单测 + 双 flavor debug 组装 + 「大陆变体不得含 GMS」校验。

## 发版

发版流程与三端（iOS / 小程序 / Android）打包规范见发版指路总表 §7：
`/Users/zewei/Documents/2024-2044/5-Tech/EXTERNAL_SERVICES.md`

## 商店材料

自 2026-11-17 起，Android 只维护 Google Play（国际版）与应用宝（大陆版）；鸿蒙原生端
按 [harmony/README.md](../harmony/README.md) 单独维护，完整渠道范围见 [正式上架流程](../docs/RELEASE.md)。
`android/store/` 中其他国内商店的既有材料仅作历史留存，不再纳入日常更新。
文案改动顺序照抄 iOS：先改 `fastlane/metadata/**`，
再回来同步 `android/store/listing/`（映射表见 `android/store/listing/README.md`）。

- `listing/zh-Hans/` `listing/en-US/`：应用名称、简介、详情、更新说明。
- `permissions.md`：权限用途表（对齐 `AndroidManifest.xml` 与 iOS purpose string 措辞）+
  可直接粘贴的国内商店「权限用途说明」与 Play「Permissions declaration」填写要点。
- `data-safety.md`：Google Play「Data safety」表单逐节填写草稿。
- `checklist-google-play.md` / `checklist-cn-stores.md`：Google Play 与国内商店上架清单；
  国内清单只执行应用宝适用项，其余渠道条目保留为历史参考。不确定的条目标「待核」。
- `screenshots/phone-1080x1920/` `screenshots/phone-1080x2400/`：七张截图两套尺寸；
  `feature-graphic-1024x500-{en,zh}.png`：Play 商店图（1024×500）。

手动触发的签名发版走 `.github/workflows/android-release.yml`（`workflow_dispatch`，
可选输入 `versionCode` / `versionName` 覆盖默认版本号）：从仓库 secrets 里的
`ANDROID_{CN,INTL}_KEYSTORE_B64` 等还原出两套签名密钥库，跑
`:app:bundleIntlRelease :app:assembleCnRelease`，产物用 `apksigner` / `keytool` 校验签名证书后
作为 workflow artifact（`intl-release-aab` / `cn-release-apk`，保留 30 天）上传，不推送到任何商店——
上传商店后台仍是人工步骤。
