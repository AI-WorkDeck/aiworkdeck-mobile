# 小程序：五分钟无人声提醒与暂停（#1412、#1413）

范围：以主线 iOS 的录音提醒与暂停语义对齐小程序。录音保留 16 kHz / 单声道 / 48 kbps MP3 与十分钟分段，不改上传字节、项目身份或留底顺序。

## 实现

- 使用本机 minimp3（CC0）解码帧，再以 WebRTC/libfvad 模式 2 分类 10 ms PCM。连续 300 秒已分类无人声才提醒，时间来自共同契约。没有使用音量阈值，没有语音服务调用或额外音频上传。
- 已检测人声、缺帧、暂停/恢复、用户选择继续会重置累计；未确认提醒保存在录音会话，页面重建后能够读取，过期提醒会撤销。弹窗答复校验会话 ID，旧弹窗不能停止新录音。
- 原生 RecorderManager.pause/resume：仅确认用户请求的回调进入暂停，系统 onPause 仍按中断保存。暂停期间不累计录音时间，界面持续展示已暂停、记得继续，继续与停止按钮均保留。
- CameraContext 没有暂停接口。录像暂停会先保存当前片段；成功留底后才显示继续，继续开启下一片段。界面明示片段边界。继续失败保留暂停可重试；迟到的旧录像回调不能污染后续录音界面。
- 帧不可用或解码失败明确提示 `rec.silence.unavailable`，录音与保存继续可用；没有拿未收到的数据当作无人声。
- 包内 WASM 固定 256 KiB 内存、39,036 字节，无 host imports；源码、许可、专利声明及 LLVM16 可重建脚本在 `miniprogram/vendor/speech/`。固定 libfvad 来自仓根 `third_party/libfvad`。WASM SHA-256：`f7d0be192ae300f6a3ab665e8a00c7fee54f2e493260016b5219efe468265393`。

## 实测

- `npm ci`、`npm run typecheck`、`npm test`：221 项通过；契约检查通过。包括真实打包 WASM 解码 310 秒合成静音 MP3、合成人声、噪声、缺帧重置、卸载后的待确认提醒、旧弹窗隔离、暂停/继续计时、系统中断、录像留底后暂停与继续失败重试。
- `project.config.json` 强制包含 WASM 和四份许可文件。使用 miniprogram-ci 2.1.31 的实际包过滤器，把所有文件标记为 unused 后，仍准确保留这五个文件。路径必须相对项目根带 `miniprogram/`；未签名、未上传体验版。
- 微信开发工具 Stable 2.01.2510290 已重新登录并可启动项目。实际产品登录页已截图。开发工具登录不等于 AI WorkDeck 业务账号登录；本轮没有使用个人账号、审核账号或复制凭据。
- 本机隔离副本仅跳过未登录页面的跳转，使本机采集 UI 可验证，不创建假 session、不连接后端。CUA 实点录音入口/快门/暂停/继续/停止；SDK 原生事件确认暂停与恢复，最终 MP3 `saved:true`、未归类。暂停时间立即显示并冻结；最终复验 `00:01` 等待后仍为 `00:01`。真实图集入口显示未归类录音。
- 开发工具对 MP3 帧未及时推送：WASM 已初始化，前五秒 native 帧计数为零，进入可用性降级；暂停/停止时才有迟到帧。本轮没有把开发工具的录音控制成功称为真实麦克风连续五分钟提醒验收。

## 证据与边界

证据目录：`/Users/zewei/.codex/qa-artifacts/mobile-silence-pause-20261021/miniprogram/`。关键文件为 `mini-silence-tests.log`、`mini-silence-contract.log`、`package-filter.json`、`wasm-rebuild-sha256.txt`、`native-pause-final.json`、`native-save-final.json`、`login-entry.png`、`paused-native.png`、`resumed-native.png`、`unassigned-gallery.png`。截图中的“本机隔离演示 · 未登录”明确标识本机 harness；临时入口与诊断不在交付源码。

尚需手机微信真机验证：真实麦克风连续五分钟、人声恢复、系统来电/后台、真实相机暂停后两段文件的音画、真实账号项目归类与付费文件预览。上轮归类与预览的服务逻辑仍有回归覆盖；本轮只补齐采集→录音控制→本机未归类图集的真实 SDK/UI 路径，没有冒充登录后的完整服务器闭环。

WebRTC VAD 是统计分类器，实测大幅白噪声可能被保守判为语音而延后提醒；不能声称完美识别人声。合成夹具均为本机生成材料，无用户录音。

官方 API 依据：本机 miniprogram-api-typings 4.0.4 的 RecorderManager 与 CameraContext 声明及其中的微信官方文档链接；`WXWebAssembly.instantiate('vendor/speech/speech.wasm')` 在开发工具实际加载成功。源码版本和许可详情见 vendor README。
