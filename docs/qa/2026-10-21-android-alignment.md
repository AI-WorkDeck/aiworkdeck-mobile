# 安卓对齐核查（dev-board #1404）

2026-10-21，初始基线 103ed03，整合主线至 de08f9a。契约和范围见同目录 platform-alignment 报告。

## 实现与复核

登录后直接采集，无项目照片、视频和音频保存为未归类；资料库长按归类后才传输。项目页新增目录和文件入口，支持分层、空文件夹、搜索、平台查看器预检、报价确认与备份读取。备份授权由独立账户快照提交，可拒绝或撤回；默认不自动开启。

桌面拉取在请求前持久化完整项目、文件和请求身份；创建响应丢失、ACK 失败重试复用原身份与缓存。校验文件格式、200 MB 单文件/总缓存限额、响应类型与实际字节数，禁止下载重定向；切换账号和关闭页面失效。重启录音草稿先恢复为未归类，防止沿用旧账户项目。

录音中断停止、检查音频元数据并保存有效片段；不能确认可播放的草稿保留并提示。CameraX 随旋转更新目标方向，异常重新进前台可恢复。登录与采集横屏路径保持可操作。

## 实测结果

```text
JAVA_HOME=.../jdk-21.jdk/Contents/Home
./gradlew :app:testIntlDebugUnitTest :app:testCnDebugUnitTest :app:assembleIntlDebug :app:assembleCnDebug
BUILD SUCCESSFUL in 18s
92 actionable tasks: 20 executed, 72 up-to-date
Intl: tests=112 failures=0 errors=0 skipped=0
Cn: tests=112 failures=0 errors=0 skipped=0
```

完整日志 `/tmp/mobile-alignment-android-merged.log`。首次整合测试捕捉旧项目 deviceId=cloud 分流错误，修正后两渠道通过。主要新增回归覆盖目录、旧项目、重试请求身份、ACK、终态清理、切账号、云备份和内容校验；本次不把这些替身测试写成生产扣费验证。

隔离模拟器 emulator-5580；未输入真实账户。截图由安卓子任务生成，主任务抽查实际图像：

- `/tmp/android-alignment-qa/login-portrait.png`
- `/tmp/android-alignment-qa/login-landscape-keyboard.png`
- `/tmp/android-alignment-qa/capture-after-project-portrait.png`
- `/tmp/android-alignment-qa/capture-landscape.png`
- `/tmp/android-alignment-qa/projects-landscape.png`
- `/tmp/android-alignment-qa/settings-landscape.png`
- `/tmp/android-alignment-qa/backup-landscape-no-session.png`

截图使用既有 debug 演示模式进入采集与设置；无真实会话的备份页显示明确失败提示，没有提交授权。早期截图中的默认按钮色已经在最终代码中改用现有配色令牌。仅代表入口与布局，不能证明生产文件成功打开或付费结算正确。

## 等真机复测

新账号不选项目拍照、录音，资料库长按归类；确认归类前没有上传。录音中触发电话/音频占用，试听已保存片段，确认不会自行重开。杀进程重启后核对草稿恢复提示；切换账号后恢复内容保持未归类。项目文件选择图片/PDF/Office，核对有无查看器、报价取消/确认、断网重试和重复点击。开启、拒绝、撤回备份分别检查服务器状态；核对无订阅时的提示。

真实镜头方向、麦克风/来电/锁屏、第三方查看器、生产扣费与云备份均未在真机验证。没有打发布标签、上传正式包或部署。五分钟无人声提醒尚未跨端实现。
