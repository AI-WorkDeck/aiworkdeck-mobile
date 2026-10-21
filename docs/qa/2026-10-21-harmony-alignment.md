# 鸿蒙对齐核查（dev-board #1405）

2026-10-21，初始基线 103ed03，整合主线至 de08f9a。范围和平台差异见同目录 platform-alignment 报告。

## 实现

无项目直接采集，资料库长按归类；项目页增加原生文件目录和预览，设置增加账户云备份的明确同意、拒绝与撤回。付费桌面拉取持久化完整请求，未知结果重试复用原请求，不因目录改名更换文件扩展名或 MIME；ACK 成功后按页面关闭清理。预览前检查平台能力、大小和账户，流式下载校验响应与字节数、禁重定向、限制总缓存，拒绝迟到的跨账户结果。

AVRecorder 真正暂停/停止/错误事件触发保存，普通提示未打断时继续。持久草稿启动时核对是否含有效音频，以未归类恢复；保存失败保留原件，不报成功。开启自动旋转并按相机接口计算照片、视频和预览旋转；页面隐藏与异步启动互相约束。

## 实测

```text
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
BUILD SUCCESSFUL in 14 s 71 ms
41 tasks in total: 20 executed, 21 up-to-date
```

日志 `/tmp/mobile-alignment-harmony-merged.log`。debug HAP 未签名，安装在本机 Pura 90 Pro 模拟器，未作为用户发布包。

整合 Node 209/209 通过，含鸿蒙文件与录音 SDK 替身回归。文件覆盖：空目录、格式/大小/查看器预检、完整付费身份重试、流式结束、内容类型与字节校验、ACK、清理、云端免费路由、账号切换、终态重试、改名后保持原文件类型。录音替身验证中断保存、有效/无效音频、保存失败留底与回调归属；不替代真实系统中断。

模拟器原生 PreviewKit 探测 15 个契约扩展名均返回 true，exe 返回 false（日志 `/tmp/harmony-preview-probe.log`）。这证明空文件扩展名检查可在收费前执行，不证明所有真实文件都能解码。临时探测代码已移除。

主任务正常启动核对横屏登录页；通过既有 debug 合成数据模式走项目选择 → Capture now → 未归类采集 → 设置入口。UI dump 能看到“Cloud file backup”行，无真实会话随后回登录页，没有开启生产备份。截图：

- `/tmp/mobile-alignment-harmony-qa/login.jpeg`：真实未登录横屏页。
- `/tmp/mobile-alignment-harmony-qa/projects.jpeg`：合成项目页和文件入口。
- `/tmp/mobile-alignment-harmony-qa/capture.jpeg`：未归类采集，快门可达。
- `/tmp/mobile-alignment-harmony-qa/settings.json`：实际设置 UI 树，含备份入口。

无法在无会话状态完成真实项目文件与授权流程；未生成伪造的成功截图。设置截图动作较晚，应用已经回到登录页，因此 settings.jpeg 不作为设置验证证据。

## 等真机复测

首页不选项目拍照/录音，资料库归类；录音期间来电/音频抢占后试听，杀进程后核对恢复。横竖屏切换后核对照片和视频方向、预览比例、页面返回和二次启动。项目页逐层进目录并预览图片、Office、PDF、音视频；取消报价不扣费，断网重试不重复收费；实际账户开启/拒绝/撤回云备份。

真实硬件录音/镜头、中断事件、锁屏、实际文件解码、生产结算与备份均未真机验证。五分钟无人声提醒尚未跨端实现。本次只有代码和本机 debug 构建，没有发布或部署。
