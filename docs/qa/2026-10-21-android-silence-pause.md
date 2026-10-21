# Android：无人声提醒与暂停验证（2026-10-21）

关联台账：dev-board #1408（无人声）、#1409（暂停）。基线 57d8014；仅调试构建，未发版、未部署。

## 实现

- 纯录音由单一 `AudioRecord` 提供 48 kHz、单声道 PCM，同一批样本进入 AAC-LC 64 kbps 编码器和设备内 WebRTC/libfvad mode 2；M4A 文件保持压缩格式，PCM 不落盘、不上传，也不另开麦克风。原先 44.1 kHz 调整到原生 VAD 支持的 48 kHz，未降低码率。
- 仅累计已成功分类的连续 20 ms 无语音帧。语音、暂停、继续录音确认、恢复与明显采集停顿（>250 ms）均重置。未收到帧不推断为无语音。分析器初始化/执行失败时显示契约提示，AAC 录制继续。
- 音频暂停停止 AudioRecord，不送编码器、不增加样本时长；恢复后跨代旧帧丢弃，编码时间戳仅依据实际写入样本。失败维持暂停状态，可重试或停止保存。已有草稿恢复路径保留。
- 录像采用 CameraX `Recording.pause/resume`，以原生 Pause/Resume 事件确认状态，以 `recordingStats.recordedDurationNanos` 计时。
- 暂停条持续提示，继续与停止保存按钮并列；前台服务通知同样提供暂停/继续/停止入口。五分钟提醒另发无声高优先级通知并振动，既不自动暂停也不自动停止；继续、暂停、停止及新语音撤销提醒。通知权限/渠道关闭时前台显示后台提醒不可用。
- libfvad 固定版本和许可由主任务统一维护；APK 附带 LICENSE、PATENTS、AUTHORS、UPSTREAM。JNI 构建四 ABI，16 KiB page alignment。

## 自动验证（实际输出）

环境：JDK 21、NDK 28.2.13676358、CMake 3.22.1；隔离 AVD `codex_alignment_oct21`，`emulator-5580`，arm64。

```
JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home \
ANDROID_HOME=/opt/homebrew/share/android-commandlinetools \
./android/gradlew -p android :app:testIntlDebugUnitTest :app:testCnDebugUnitTest \
  :app:assembleIntlDebug :app:assembleCnDebug :app:assembleIntlDebugAndroidTest --console=plain
BUILD SUCCESSFUL in 8s
133 actionable tasks: 31 executed, 102 up-to-date
```

两渠道各 117 项、0 失败，日志 `/Users/zewei/.codex/qa-artifacts/mobile-silence-pause-20261021/android/android-silence-build.log`。新增五项单测覆盖正式 300 秒阈值、语音重置、缺帧/暂停/确认重置、无分类不计时、暂停仍保留录制及样本时间。

```
adb -s emulator-5580 shell am instrument -w \
  com.aiworkdeck.mobile.test/androidx.test.runner.AndroidJUnitRunner
com.aiworkdeck.mobile.services.AudioPipelineDeviceTest:...
Time: 1.197
OK (3 tests)
```

最后对话框取消行为修订后再次构建通过：`BUILD SUCCESSFUL in 3s`，两渠道各 117 项仍通过，日志 `/Users/zewei/.codex/qa-artifacts/mobile-silence-pause-20261021/android/android-silence-final-build.log`。

原生测试实际加载 JNI，15,000 个 20 ms 零帧达到 300 秒、继续后不立刻重弹、非法长度拒绝；上游 `audio_tiny48.wav` 确实检出语音；真实 MediaCodec 输出 AAC/M4A、48 kHz、单声道，编码 1 秒且暂停墙钟不进入文件时长。日志 `/Users/zewei/.codex/qa-artifacts/mobile-silence-pause-20261021/android/android-silence-device-tests.log`。

## 模拟器用户路径

首页未经登录时仍展示正常登录页；测试采集使用现有 debug 截图登录跳过，仅提供合成账号和未归类状态，录音/相机均为真实原生路径，没有模拟暂停或缩短正式提醒阈值。

- 录音到 00:14 暂停，等待数十秒后界面仍为 00:14，草稿大小保持 117409 字节；继续显示 00:15，再停止保存。产物 21.144 秒、178144 字节、AAC 48000 Hz/mono，ffmpeg 完整解码成功。
- 录像到 00:16 暂停，等待约一分钟仍 00:16；继续、再次暂停、旋转至横屏、停止保存。产物 33.657289 秒，H.264 视频及音轨。实际解码已验证；原容器 957 个视频 packet 的 DTS 严格递增。ffmpeg 默认 CFR 空输出曾报告两处重采样重复 DTS，使用 `-fps_mode passthrough` 完整解码无错误，未据此冒充真实设备质量验证。
- 竖/横屏可见暂停、继续与停止保存入口。最终界面把继续与停止并排，进一步保留横屏取景空间。

证据目录：`/Users/zewei/.codex/qa-artifacts/mobile-silence-pause-20261021/android/`，含 `login.png`、`audio-recording.png`、`audio-paused.png`、`audio-resumed.png`、`audio-saved.png`、`video-recording.png`、`video-paused.png`、`video-resumed.png`、`video-paused-landscape.png`，并保存对应 UI XML 和两段实录媒体。

## 实录、受控提醒联测与真机边界

真实 AudioRecord 连续录制超过 10 分钟（最后观测 10:20），经过前台/后台切换后正常停止保存。为了排除宿主输入，执行了模拟器官方 `avd hostmicoff`；但 AudioFlinger HAL 仍持续报告 -3.0 dB 的合成输入，实际没有获得稳定静音源，也未弹提醒。不能将此轮标为“真实静音五分钟提醒通过”，同样不能把非静音输入未提醒判为功能失败。HAL 证据见归档 `audioflinger-later.txt`。

补充受控联测只写在 androidTest 中，没有生产测试入口，也未修改正式 300 秒阈值：测试实际 JNI 分类 15,000 个 20 ms 零 PCM 帧，送入正在运行的录音引擎现有 `onSilence` 回调，验证真实 RecordingService 发布 id=3 的 `recording-reminders` 通知和 HomeScreen 提醒弹窗；再点击“继续录音”，确认仍在录音、提醒状态清零、通知撤销。它覆盖分类结果进入提醒展示与用户操作的链路，明确不等于实际麦克风静音采集全链路。

```
adb -s emulator-5580 shell am instrument --no-hidden-api-checks -w \
  com.aiworkdeck.mobile.test/androidx.test.runner.AndroidJUnitRunner
com.aiworkdeck.mobile.services.AudioPipelineDeviceTest:....
Time: 5.149
OK (4 tests)
```

`--no-hidden-api-checks` 仅允许 instrumentation 取实际应用服务实例，不进入产品配置；测试不改音频源、不绕过分类器。归档 `android-silence-device-tests-final.log` 与 `controlled-silence-dialog.png` 保存结果。截图中计时仅约 1 秒，是受控 PCM 音频时间加速送入，不宣称经历五分钟真实墙钟。

另实际撤销通知权限、在系统询问中选择不允许，然后开启录音：界面正常计时，并清楚显示“Background alerts are unavailable. Return to the app to view reminders. Recording continues.”；见 `notifications-denied-recording.png`。已停止该段并恢复本任务模拟器通知权限。

不同设备的远场/轻声、背景音乐与电视、蓝牙耳机、来电、长期锁屏与厂商省电行为需真机复测。VAD 是概率性语音检测，不承诺把所有噪声与人声完全分离。AudioRecord 不向每次 read 暴露连续序号，短于缺帧守卫的硬件 overrun 未单独观测；不以音量阈值代替语音分类。新增功能无服务端接口变更，不适用线上假参数探测。

复测：打开首页→录音→暂停，确认计时停止且持续显示暂停→继续→停止保存回放；再录一段安静音频至少五分钟，确认提醒可选择继续/停止保存，后台通知同样可操作；录像重复暂停/继续并回放核对停顿未进入时长。

官方依据：[AudioRecord](https://developer.android.com/reference/android/media/AudioRecord)、[MediaCodec](https://developer.android.com/reference/android/media/MediaCodec)、[CameraX 视频](https://developer.android.com/media/camera/camerax/video-capture)、[libfvad](https://github.com/dpirch/libfvad)。

## 第二视角复核

本代理只读复核鸿蒙 `recording.cpp`，指出 EOS 与有效 payload 同一缓冲时旧 `else if` 分支会跳过尾部音频；已向主任务报告，由鸿蒙代理改为先写 payload、再独立处理 EOS 并补回归。此项是代码复核结论，不冒充独立鸿蒙真机复现。
