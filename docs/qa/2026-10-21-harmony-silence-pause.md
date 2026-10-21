# 鸿蒙：五分钟无人声提醒、录音与录像暂停

关联台账：dev-board #1410、#1411。基线 `57d8014`，独立工作树 `harmony-silence-pause`（detached HEAD）。本次未提交、推送、发版或部署，由主任务整合交付。

## 实现与边界

- 纯录音使用一个 `AudioCapturer`，同一份 48 kHz、S16、单声道 PCM 分别送本地 WebRTC/libfvad（mode 2）和系统 AAC 编码器/M4A 封装器。AAC 仍配置 64 kbps；采样率由原 44.1 kHz 改为 48 kHz，主任务已确认，以直接使用分类器支持的采样率，避免另写重采样或开第二麦克风抢占。录像仍用原 AVRecorder 路径，没有改变视频采集档位。
- libfvad 固定来源和版权由仓根 `third_party/libfvad` 管理；HAP rawfile 附带 LICENSE、PATENTS、AUTHORS 和 UPSTREAM。没有语音上传，没有用音量阈值冒充人声。
- 提醒阈值读取 `ContractCapabilities.voiceReminderSeconds`。只累计实际完成分类的 10 ms 无语音 PCM；人声、超过 250 ms 的回调间隙、暂停、恢复、用户选择继续都会清零。无帧超过一秒显示检测暂不可用，不把无帧算作静音。分类失败只影响提醒，编码继续；编码/存储失败保留草稿和可播放前缀。
- 达到阈值只弹出“继续录音／停止并保存”，不会自动停录。发布系统通知，点击回应用；通知拒绝/失败不阻止录音，并在界面解释后台提醒不可用。迟到通知不会在已经暂停、停止或清除提醒后重新留下。
- 录音暂停真正停止 AudioCapturer，恢复只由用户触发；同一编码器与输出文件保持，PTS 由收到的 PCM 样本数连续生成。录像暂停/恢复调用同一 AVRecorder 的原生 pause/resume。两种时钟都排除暂停时间，持续显示“已暂停·当前未录制”和继续提示，暂停时状态点改为灰色，停止保存仍可操作。横屏时暂停/继续进入快门左侧，避免新增竖排按钮挤出停止键。
- 暂停/恢复正在等待硬件时点停止，服务会排队保存，不丢弃停止请求。系统音频焦点中断仍保存已有内容，不自动继续。NAPI 输出按“有效音频 payload → EOS 确认”处理，含 payload 的 EOS buffer 不丢尾帧。仅在 EOS 的 PTS 和完整 payload 都与已成功写入的上一包相同时去重；同内容但新 PTS 的合法音频照常写入。其他非递增时间戳明确报编码失败并保留已写文件，不强改时间戳。

## 验证

使用本机 DevEco Studio SDK 26 的 C/ArkTS API，兼容目标仍为 API 12。构建命令：

```sh
cd harmony
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

最后输出原文：`BUILD SUCCESSFUL in 2 s 373 ms`，`41 tasks in total: 22 executed, 19 up-to-date`。包括 arm64-v8a 与 x86_64 NAPI/libfvad 编译；未签名 debug HAP，未发布。

针对性测试命令：

```sh
node --import ./scripts/node-ts-resolve.mjs --test \
  tests/harmony/voice-frames-native.test.ts tests/harmony/camera-pause.test.ts \
  tests/harmony/pcm-recorder.test.ts tests/harmony/recording-interruption.test.ts \
  tests/harmony/recording-clock.test.ts
```

最后输出原文：`# tests 24`、`# pass 24`、`# fail 0`、`# skipped 0`。

其中 `voice-frames-native.test.ts` 在临时目录使用本机 `cc -std=c11` 和 `c++ -std=c++17` 编译生产 `VoiceFrames.h`、`EncodedPacket.h` 与固定 libfvad C 实现。真实执行 300 秒零 PCM 分类、上游真实语音 PCM、半帧拼接、缺帧/暂停清零，以及最后 payload 与 EOS 同 buffer 的写入顺序、平台重复 EOS 包去重、合法同内容新时间戳尾帧保留、异常时间戳显式失败、封装器改写 buffer 前留存比较数据；不依赖模拟分类器、ffmpeg 或降低正式阈值。该测试属于 `npm test` 默认集合，可在 macOS/Linux CI 执行。

其余测试覆盖同一麦克风、暂停后旧回调隔离、恢复失败保持暂停、检测失败与编码失败区别、草稿恢复、停止排队、视频同一原生录制器与暂停计时、视频恢复失败后停止保存。

## 实际模拟器路径与产物

Pura 90 Pro、HarmonyOS 7.0/API 26 模拟器。使用本机既有 debug 截图模式的演示项目进入首页（非真实用户登录、非线上项目验收），但录音麦克风、AAC 编码、M4A 文件、暂停/恢复、提醒计时与弹框全部使用业务真实链路。模拟器输入为零 PCM，首个文件解码的 Peak/RMS 均为 `-inf`；该测试不能替代真机环境中的人声准确率验收。

1. 首页选择录音 → 开始 → 00:16 暂停 → 约 22 秒后仍为 00:16 → 继续 → 停止。导出的 `recording.m4a` 完整解码成功：AAC、48000 Hz、单声道、22.932979 秒，未计入暂停墙钟。
2. 18:55:27 开始完整正式长测，五分钟后出现提醒。05:34 截图时弹框仍在，计时继续，证明没有自动停止。点击“继续录音”，06:01 和 07:04 两次 UI 记录均继续录制且未立即重弹；19:02:33 手动停止并保存。该长测文件曾落盘为 166551 字节；随后重新启动演示种子会清除新增演示数据，因此未保留该长文件，不将它列作独立解码证据。
3. 包含 48 kHz AAC-LC 显式配置、回调代际隔离与灰色暂停标志的版本再次实录、暂停、恢复、保存。`recording-final.m4a` 为 AAC、48000 Hz、单声道、49.471229 秒，`ffmpeg -v error -i ... -f null -` 返回 0，错误日志为空。
4. 初次 EOS 尾帧修复样本 `recording-eos.m4a` 完整解码虽返回 0，但归档复核发现日志有非递增 DTS 警告。ffprobe 显示末两包 PTS/DTS 都为 407530、不同文件位置，没有 skip_samples；不能把它称为无错误通过。保留原文件及日志作为修复前证据。
5. 临时原生回调抓取确认平台行为：普通输出 index 339 的 PTS=7253220、size=11、flags=0，随后 EOS index 340 的 PTS、完整 payload 都相同，只有 flags=1。因此仅去掉这种完全重复 EOS，不丢合法尾帧。抓取代码已从最终业务源码移除。
6. 最终去重构建在同一模拟器实录：19:28:39 开始，00:07 暂停，19:29:03 在暂停状态停止保存。`recording-eos-fixed.m4a` 为 AAC-LC、48kHz、单声道、7.722542 秒，排除了暂停墙钟；362 个原始音频包 PTS/DTS 全部严格递增。`ffmpeg -v error -i recording-eos-fixed.m4a -f null -` 完整解码返回 0、stderr 为空。截图与 UI 原始记录保留暂停标志和 00:07 计时。

归档目录（主任务可直接检查）：

`/Users/zewei/.codex/qa-artifacts/mobile-silence-pause-20261021/harmony/`

- `paused-final.jpeg`、`paused-landscape-fixed.jpeg`：最终竖/横屏灰色暂停标志，继续与停止均在屏内。
- `five-minute.jpeg`：真实正式五分钟触发弹框，背景计时 05:34。
- `continued.jpeg`、`ui-observations.json`：点击继续后至 07:04 不重弹且录音继续。
- `recording.m4a`、`recording-final.m4a`、`recording-eos.m4a`、`harmony-silence-final-media.json`、`harmony-silence-decode.log`：此前实际录音与解码证据（`recording-eos.m4a` 是修复前问题样本）。
- `harmony-silence-tests-final.log`、`harmony-silence-build-final.log`、`harmony-silence-contract.log`：测试、构建、契约输出。
- `harmony-silence-runtime.log`：录音开始/保存时间及下面的视频编码限制。
- `harmony-eos-output-trace.txt`、`harmony-silence-eos-packets-frames.json`、`harmony-silence-eos-pcm-decode.json`：原问题的原生输出、原始包/帧与解码证据。
- `recording-eos-fixed.m4a`、`harmony-eos-fixed-packets.json`、`harmony-eos-fixed-decode.json`、`harmony-eos-fixed-decode.log`：最终修复样本、362 包时间戳检查、完整无警告解码（日志为空）。
- `harmony-eos-fixed-tests.log`、`harmony-eos-fixed-build.log`、`eos-fixed-paused.jpeg`、`eos-fixed-paused.json`：最终测试、构建、实际暂停界面。

补充横屏实测：暂停17秒处旋转至横屏，暂停状态、继续、停止和底栏全部可见；点击左侧“继续录音”成功恢复，再点击停止成功保存。`paused-landscape-fixed.jpeg` 与 `harmony-landscape-resumed.json` 保存最终结果。

## 未验证项与真机复测

- 视频暂停/恢复已有服务级真实业务代码测试，但不能称视频实录通过。沿用既有 `--ps awdStage live` 参数关闭静态截图背景后，真实相机 photo session 成功；该模拟器的 AVRecorder.prepare 对原视频配置报 `[Prepare] Video encode config failed`，未生成可供暂停的录像。本次没有为绕过模拟器改低视频画质。需要鸿蒙真机录制 → 暂停 → 等十秒 → 继续 → 停止，确认单文件时间线不包含暂停段，画面/声音接续正常。
- 五分钟环境噪声、人声、多人远场、人声混音乐的准确率，以及锁屏/后台通知、电话中断/蓝牙设备切换需要真机复测。已验证零 PCM 分类和上游语音 PCM，不将这两类证据扩大为所有真实场景准确率通过。
- 系统通知 API 的实现与拒绝降级已接入；这次五分钟走的是前台确认路径，没有单独完成锁屏通知的完整真机验收。
- 本次端内所有实录均为演示项目、禁用上传的 debug 路径；没有真实账号登录、云上传或服务器修改。
