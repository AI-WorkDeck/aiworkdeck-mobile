# Apple Watch 录音

AI WorkDeck iPhone 应用附带的 watchOS 10+ 单 target 应用。手表只负责录音、计时、保存与同步；项目选择和播放在手机端完成。未在手表存储登录凭据。

## 安装

手表应用随同一个 iPhone App 的 1.6.0 版本提交 App Store，不需要另建商店应用记录。需要 iOS 17+、watchOS 10+，且手表与 iPhone 已配对。更新 iPhone App 后，在系统「Watch」App →「我的手表」→「可用 App」安装 AI WorkDeck；开启自动安装应用时系统也会自动安装。首次使用先在手机登录并选项目，再打开手表 App。

## 使用路径

1. 在配对 iPhone 登录 AI WorkDeck，在现有项目入口选择归档项目。手表收到项目后显示项目名称。
2. 手表点「开始录音」，结束时点「停止并同步」。离开手机仍可录音，文件保留在手表，连接恢复后由 WatchConnectivity 安排传输。
3. iPhone 收到文件后先复制到持久收件箱，再以同一 UUID 写入现有录音资料库和上传队列。手机确认可靠落盘后才回传确认，手表收到确认才清理音频。
4. 手机中的录音可播放、归类。未选择项目或登录范围发生变化的离线录音进入未归类；用户可主动重新归类。选择其他项目不会自动改变录音开始时的项目。已有「首次上传后不允许改归属」规则继续适用。
5. 桌面或云项目收到音频后，沿现有电脑端音频文件「转写」入口确认费用并处理。上传不自动启动付费转写，手机端本次未新增转写操作。

系统调度文件交接，不保证停止后立刻到达。手表显示的「已存入手机」只代表手机可靠接收；上传与电脑落盘状态仍在手机队列查看。强制退出手机应用、系统暂停后台工作或离线时，可能需要重新打开手机应用才能继续处理。

## 中断与可靠性

录音开始前请求 `setPrefersNoInterruptionsFromSystemAlerts(true)`（watchOS 7.3+ / iOS 14.5+）。这是尽量避免来电提示和系统提醒打断的偏好，并非录音最高优先级；配置失败仍允许开始录音。接听电话、Siri或其他不可混音会话仍可能中断。iPhone 需采用横幅来电显示，全屏来电不受该偏好保护；Apple未对Watch承诺相同的来电显示规则。手机播放录音时恢复普通提示行为。

保留 `.record` 以避免意外播放声音混入取证；不为抢占优先级改成 `mixWithOthers`，它不能夺回电话/Siri的麦克风。背景音频模式解决落腕/切应用时持续执行，不提供系统中断豁免。真机来电/提醒/Siri矩阵仍待实测。

- 手表使用音频后台模式，来电/音频会话被系统中断时保存可用部分，明确提示并等待用户重新开始，不自动开麦。
- 录音开始前落盘 UUID、时间与项目快照。重启检查遗留音频的有效音轨和时长；恢复成功与无法恢复分别提示。进程被强杀可能破坏未封装完成的 AAC 文件，不能保证恢复；原草稿保留，绝不把空文件当成功。
- 文件传输成功回调不触发删除，只有 iPhone 应用级持久接收确认才触发。收件墓碑防止已删除录音因旧传输重试重新出现。
- 同一 UUID 重复交接不重建记录，不覆盖原上传状态或项目。Watch 账号范围随记录持久保存；领取上传与构造请求均校验。登录取得用户 ID 后使用区域+用户范围；存量登录无法确认用户 ID 时保守绑定本次会话。主动重新归类会绑定当前登录范围。
- 新增 UI 文案复用 `contract/strings.json`，字体、颜色和间距复用现有令牌。

## 验证与构建

```sh
npm ci
node contract/tools/check.mjs
npm test
xcodegen generate --spec ios/project.yml --project ios
xcodebuild build -project ios/Workdeck.xcodeproj -scheme WorkdeckWatch \
  -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project ios/Workdeck.xcodeproj -scheme Workdeck \
  -only-testing:WorkdeckTests -destination 'platform=iOS Simulator,id=<UDID>' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

多平台工程不要全局传 `-sdk iphoneos`/`-sdk iphonesimulator`：会把 watchOS 依赖也强制按 iOS 编译；由 destination 选择各目标对应的 SDK。

`WatchRecordingTests` 覆盖共享夹具、接收回调返回前复制、进程恢复、重复接收、账号变化、主动改项目后的账号隔离、失败导入与接收墓碑。

正式签名复用现有团队与 Distribution 证书；Watch 有独立 Bundle ID/profile。CI 使用 `WATCH_PROFILE_B64` 原位密钥项。构建上传仍只由既有明确发版触发机制启用：提交消息包含 `[appstore]`。用户已于 2026-10-13 授权发布 1.6.0（dev-board#1241）。

商店 Watch 截图独立于 iPhone 截图：提交消息含 `[watch-screenshots]` 时，由无签名密钥的 CI 新建 Watch 模拟器、运行真实 App 并生成中英文截图。检查图片后，通过 `scripts/asc-listing.py watch-screenshots <artifact目录>` 上传到 `APP_WATCH_SERIES_10` 截图组；不能放入现有 iPhone 截图目录。

## 真机验收（待执行）

Apple 要求在真实配对设备测试 WatchConnectivity 文件传输，模拟器和逻辑测试不能替代：

- 安装包含 Watch 应用的新 iPhone 包，在手表打开应用，检查小尺寸屏幕与中英文。
- 登录/选择项目→手表显示项目→录制→停止→手机播放→上传队列→项目中找到音频→现有电脑转写入口。
- 手表与手机断连后录制数段，再连接并等待系统交接，检查不丢失、不重复。
- 手机切项目时手表正在录制；收到后确认原项目，并在首次上传前主动改项目。
- 切账号后收到旧录音：应保留本地并等待明确归类，不能自动上传给新账号。
- 手表落腕、切到其他应用、真实来电/音频抢占、低空间与强制终止后的恢复提示。

参考：[Apple transferFile 文档](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:))、[Apple 文件接收回调](https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate/session(_:didreceive:))。

音频优先级参考：[Apple 系统提醒偏好](https://developer.apple.com/documentation/avfaudio/avaudiosession/setprefersnointerruptionsfromsystemalerts(_:))、[record 类别限制](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record)。
