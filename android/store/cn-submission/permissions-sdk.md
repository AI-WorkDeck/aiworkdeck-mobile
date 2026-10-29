# 权限、第三方组件与数据流核对表

核对源码：稳定基线 `ef0cb213` 加 #1615 的 `436358f`，对应 1.3.1 / code 6 签名候选包，2026-10-29。用于国内后台权限说明和移动端隐私政策核对；不是商店隐私检测已通过的证明。最终 APK 合并清单、依赖树、实际流量及平台扫描仍按各店要求复核。

## 权限用途

| Android 权限 | 可用于后台的用途说明 | 基线行为与需核对事项 |
| --- | --- | --- |
| CAMERA | 用于用户主动拍摄项目现场照片和视频 | CameraX；应在拍摄功能使用时申请 |
| RECORD_AUDIO | 用于用户主动录音及录制视频声音 | 后台录音有持续通知；来电 / 麦克风被占用时停止并保存 |
| ACCESS_FINE_LOCATION / ACCESS_COARSE_LOCATION | 经允许后记录现场影像的采集地点和定位精度，便于资料核对 | 系统 LocationManager；无后台定位权限；GPS 记录到本地 manifest，基线 `Backend.upload` 未发送 GPS 字段，不能写成“位置随上传提交服务器” |
| POST_NOTIFICATIONS | 展示录音状态、暂停 / 停止操作，以及传输任务状态 | Android 13+ 运行时权限；拒绝后的实际通知及后台服务行为应实测 |
| FOREGROUND_SERVICE / FOREGROUND_SERVICE_MICROPHONE | 支持用户主动开始的持续录音，切后台后仍能录制 | 不是开机自启或隐蔽录音 |
| FOREGROUND_SERVICE_DATA_SYNC | 支持正在进行的文件传输及传输状态提示 | 与上传队列工作对应，需核对最终 merged manifest |
| INTERNET | 登录账号、获取项目、上传采集资料、获取或预览项目文件 | 业务网络请求；没有 Android 运行时授权框 |

原基线进入首页时批量申请敏感权限；#1615 已改为首次取景仅相机、录音才申请麦克风、视频依次申请相机与麦克风、GPS 入口单独申请精确 / 粗略位置、主动录音 / 项目采集另行申请通知。源码已独立复核；拒绝麦克风后仍可保存无声视频的模拟器 MP4 已核验仅含视频流。通知拒绝不阻断采集。此验证不等于各店自动隐私检测通过。

上传通知显示“正在上传”的静态任务状态；逐件上传进度在应用内的上传队列显示。

没有在主 Manifest 声明通讯录、短信读取、电话记录、后台定位、广泛存储 / 相册读取权限。Android 10+ 可按设置通过 MediaStore 另存本应用创建的照片、视频，不能宣传“绝不进入系统相册”。FileProvider 仅在用户打开文件时向选中的兼容查看器授予临时读取权限。

## 应用内组件（不能写成“没有任何第三方 SDK”）

| 组件 / 当前声明版本 | 用途 | 数据处理边界 |
| --- | --- | --- |
| AndroidX CameraX 1.6.2 | 拍照、视频 | 本地摄像头及媒体采集；应用上传另由业务逻辑触发 |
| AndroidX Media3 1.11.0 | 音视频播放 | 本地或业务指定媒体；不是广告跟踪 |
| AndroidX WorkManager 2.11.2 | 后台上传任务 | 执行本应用的传输任务 |
| AndroidX Security Crypto 1.1.0 | 本地账号凭据存储 | 设备本地加密存储 |
| OkHttp 5.5.0 | HTTPS 网络 | 向所选区域业务接口传输请求；不能解释成“仅本地处理” |
| Coil 3.6.1 | 图片加载与缓存 | 本地图片及业务指定资源；需要结合实际调用核验是否远程加载 |
| kotlinx.serialization 1.11.0 / coroutines 1.11.0 | 数据编码、异步任务 | 通用代码依赖，本身不代表独立收集者 |
| AndroidX Browser 1.10.0 / Compose / Core 等 | 界面及系统浏览器衔接 | 用户打开注册、政策等网页时由浏览器加载相应站点 |
| libfvad / WebRTC VAD（仓库源码） | 本地检测录音是否有人声，提供提醒 | 本地 PCM 处理，不是云端转写或语音识别服务 |

依据 `android/app/build.gradle.kts`、`android/gradle/libs.versions.toml`及 `third_party/libfvad`。最终申报以实际锁定依赖和扫描结果为准，不把上表当作所有间接依赖的清单。基线未声明广告、统计、地图、第三方推送、微信或支付宝 SDK；这不代表服务端不存在云服务处理者。

## 必须与服务端政策一起核对的数据

| 场景 | 已读源代码事实 | 发布前需核实 |
| --- | --- | --- |
| 登录 | 普通账号密码请求；审核模式独立验证；保存登录会话 | 账号资料范围、日志与保存期限、运营主体、客服 |
| 现场上传 | 影像及归档相关信息经区域业务服务器处理 | 中转 / 归档 / 云备份各自期限，第三方处理者及存储地域 |
| 位置 | LocationStamper 写本地记录；上传请求未包含专门 GPS 字段 | 最终包及媒体自身元数据是否携带位置，避免仅据请求字段断言绝不上传 |
| 云备份 | `BackupConsentScreen` 有独立选择与保存状态 | 备份权益、撤回后的处理、存储位置与期限 |
| 项目文件 | 列表、文件请求与预览计费请求；请求可含文件名 | 权限核验、桌面端中转 / 云端来源、费用确认、缓存与清理 |
| 注销 | 调用云端账号删除接口并退出；本地图集未自动删除 | 云端实际删除范围、法定留存例外及完成时限；本地影像管理说明 |

中国大陆业务 API 基线为 `https://addin.aiworkdeck.com`；用户可切换账号区域，国际区域为 `https://addin.workdeck.ai`。国内申报需确认切换提示、区域账号规则和政策披露，不能笼统宣称所有情形均在境内处理。

源代码主要入口：`android/app/src/main/AndroidManifest.xml`，`android/app/src/main/kotlin/com/aiworkdeck/mobile/services/{Backend,LocationStamper,RecordingService}.kt`，以及 `features/{auth,home,settings,workspace}`。第三方组件披露的格式参考 [华为官方说明](https://developer.huawei.com/consumer/cn/doc/hmscore-guides/app-release-0000001050123495)。
