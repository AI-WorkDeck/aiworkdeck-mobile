# harmony/ — HarmonyOS NEXT 客户端（ArkTS）

设计：`docs/specs/2026-09-03-harmony-client-design.md`（沿用安卓 `2026-09-02-android-client-design.md`）。
dev-board [#391](https://github.com/zeweihan/dev-board/issues/391)、[#407](https://github.com/zeweihan/dev-board/issues/407)。

包名 `com.aiworkdeck.mobile.huawei`，单 product `default`，服务端 `https://addin.aiworkdeck.com`。

## 工程结构

| 模块 | 是什么 |
|---|---|
| `contract/` | HAR。四端共享契约的 ArkTS 生成物（`contract/tools/gen.mjs` 产出，**不要手改**），`Index.ets` 汇出 |
| `entry/` | HAP。`src/main/ets/` 按 `model / services / design / pages` 分层 |

`entry` 通过 `oh-package.json5` 的 `"contract": "file:../contract"` 依赖 HAR，代码里 `import { T, ContractStates, ContractStrings, ContractCapabilities } from 'contract'`。

领域层（`entry/src/main/ets/model/`、`design/L10n.ets`）是**不引 `@ohos.*` / `@kit.*` 的纯 ArkTS**，
仓库根的 `npm test` 通过 `scripts/node-ts-resolve.mjs` 直接跑它们（`.ets` 用 `typescript.transpileModule`
转译，裸说明符 `contract` 映射到 `harmony/contract/Index.ets`）。CI 只跑这一层，hvigor 构建靠本机。

`entry/src/main/ets/` 下各层内容：

| 层 | 文件 | 一句话 |
|---|---|---|
| `model/` | `Capture.ets` | `MediaKind`、`CaptureManifest`、`RelayProject`、`StoredRow`、`CaptureItem` 等领域类型 |
| | `TransferState.ets` | 传输状态机（`TransferStateOps` 静态方法，ArkTS 不允许给 enum 挂方法） |
| | `TransferTally.ets` | 三桶计数（上传中/已暂存/失败/已落盘） |
| | `LibraryGrouping.ets` | 图集按项目/按日分组、三级删除警告 |
| | `UploadNaming.ets` | 落盘文件名规则（`现场影像-yyyyMMdd-HHmmss-xxxx.jpg` 等） |
| | `IsoTime.ets` | ISO 时间格式化/解析 |
| | `RecordingClock.ets` | 录音计时（与 iOS `RecordingClock` 同名同语义） |
| | `AppModelLogic.ets` | `otherPendingCount`、`isDesktopOnline` 等派生逻辑 |
| | `Backoff.ets` | 上传失败退避序列（60s×2^n≤15min） |
| | `Envelope.ets` | 服务端响应信封解析 |
| | `QueueExpiry.ets` | 中转区到期文案的天数计算 |
| | `Watermark.ets` | 拍照/录像水印排版（纯逻辑，不引 ArkUI） |
| | `Format.ets` | `formatBytes` 等格式化小工具 |
| | `Loc.ets` | 定位快照类型 |
| `services/` | `Backend.ets` | `@ohos.net.http` 请求 + 会话头 + 信封解析 |
| | `SessionStore.ets` | Asset Store Kit 存会话 |
| | `EvidenceStore.ets` | 落盘 manifest（`filesDir/FieldEvidence/{media,manifest}`），Promise 链锁串行 |
| | `UploadQueue.ets` | 单飞上传队列、退避重试、`checkDelivered` |
| | `Uploader.ets` | `request.agent` 后台上传任务 |
| | `CameraService.ets` | Camera Kit 拍照/录像 |
| | `RecorderService.ets` | 录音 + 长时任务 + 中断兜底（见「录音后台续录」） |
| | `RecordingState.ets` | 录音状态的 subscribe/unsubscribe 载体 |
| | `LocationStamper.ets` | 单次定位 |
| | `AlbumSaver.ets` | 存相册（系统确认弹窗） |
| | `Prefs.ets` | `@ohos.data.preferences`：存相册开关、选中项目、`deviceId`、图集视图偏好 |
| | `DeviceFacts.ets` | 设备型号/系统版本/应用版本 |
| | `Permissions.ets` | 权限申请与拒绝路径 |
| | `ApiTypes.ets` | 接口请求/响应类型 |
| | `ServiceLocator.ets` | 服务装配与只读取值器（见「ArkTS 踩坑清单」） |
| `design/` | `Tokens.ets` | `T` → `ResourceColor` / `vp` / `fp` |
| | `L10n.ets` | `tr(key, vars)` 词典查询 |
| | `Components.ets` | `StatusDot`、`GlassBar`、`Pill`、`PrimaryButton` |
| `pages/` | `Root.ets` | `Navigation` 栈根 |
| | `Login.ets` / `ProjectPicker.ets` | 登录、选项目（含「切换项目」的双路由名写法） |
| | `Home.ets` | 取景器（拍照/录像/录音三态） |
| | `Library.ets` / `Viewer.ets` / `ViewerRequest.ets` | 图集网格/列表、全屏查看器、查看器入参 |
| | `Queue.ets` | 上传队列四段列表 |
| | `Settings.ets` | 设置页 |
| | `Feedback.ets` | 意见反馈 |

`tests/harmony/`（仓库根）是领域层的夹具与单测：`contract-fixtures.test.ts`（五夹具驱动状态机/计数/分组/恢复）、
`recording-clock.test.ts`、`upload-naming.test.ts`、`iso-time.test.ts`、`library-grouping.test.ts`、
`backoff.test.ts`、`envelope.test.ts`、`format.test.ts`、`queue-expiry.test.ts`、`watermark.test.ts`、`l10n.test.ts`。

## 构建（不开 IDE）

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node
cd harmony
/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin/ohpm install --all      # 首次
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap \
  --mode module -p product=default -p buildMode=debug --no-daemon
```

产物（未配签名时）：`entry/build/default/outputs/default/entry-default-unsigned.hap`。
`hvigorw` 带 ArkTS 语法检查，编不过就是没遵守 ArkTS 约束（spec §3）。

**`hvigorw` 只对被页面（`Navigation` 路由树）实际引用到的 `.ets` 做 ArkTS 类型检查**：实测在一个
未被引用的 `model/*.ets` 末尾塞一行 `const PROBE: number = "not a number"`，`CompileArkTS` 照样
`BUILD SUCCESSFUL`、0 ERROR。领域层文件一旦被某个页面 import（哪怕只是过渡期的探针页），才会
恢复类型检查；Node 侧 `npm test` 只转译不查类型，两者互补但都不能单独当「这份 `.ets` 没问题」的证据。

本机环境（2026-09-03 实测）：DevEco Studio 26.0.0，HarmonyOS SDK API 26（`platformVersion 26.0.0`，
`version 26.0.0.105`），hvigor / hvigor-ohos-plugin 6.26.4。

## 版本字符串（都是踩出来的，别凭印象改）

| 位置 | 值 | 依据 |
|---|---|---|
| `build-profile.json5` `compatibleSdkVersion` | `"5.0.0(12)"` | hvigor 明说：**API 10–25 必须写 `'5.0.0(12)'` 这种带括号的形式**。写 `"12"` 会报 `00306042 Specification Limit Violation` |
| `build-profile.json5` `targetSdkVersion` | `"26.0.0"` | 同一条错误信息的下半句：**API 26 及以后必须写 `'26.0.0'`，不带括号**。写 `"26.0.0(26)"` 会报 `00308018 api version parameter is illegal` |
| `hvigor/hvigor-config.json5` 与 `oh-package.json5` 的 `modelVersion` | `"6.0.6"` | hvigor 只校验**这两处一致**（不一致报 `00303027`，让你走 Migrate Assistant），不校验具体值。若日后 DevEco 打开工程提示迁移，以 IDE 写入的值为准，两处一起改 |
| `build-profile.json5` `useNormalizedOHMUrl` | `true` | stage 模型 + API ≥ 12 的模板默认值，本机构建通过 |
| `contract/Index.ets` | `export * from './src/main/ets/…'` | ArkTS 接受 `export *`，不必逐个具名导出 |

`contract` 这个 HAR 模块在根 `build-profile.json5` 的 `modules` 里**不写 `targets.applyToProducts`**——
HAR 不独立安装，写了 hvigor 会警告 `HAR modules cannot be installed independently`。

## ArkTS 与契约生成物

ArkTS 严格模式的两条在生成器里踩过：

1. `as const` 不认（arkts-no-as-const）→ 生成物改成显式 `interface` + 类型化 `export const`。
2. 对象字面量必须对应显式类型（arkts-no-untyped-obj-literals）→
   - 接口字段里的**嵌套 `Record<string, string>` 字面量不认**，得提成同文件里的具名常量再引用；
   - `Record` 字面量的**键必须是字符串字面量**（`"moving": "uploading"`），写成标识符键就当成无类型对象字面量。

这两条都做在 `contract/tools/lib.mjs` 的 ArkTS 渲染段里。改契约的流程照旧：
改 `contract/*.json` → `node contract/tools/gen.mjs` → 改各端代码 → `node contract/tools/check.mjs`。
`check.mjs` 会扫 `harmony/entry/src/main/**/*.ets` 的内联中文文案（一律走 `tr(key)`），
也会扫 `harmony/build-profile.json5` 里的签名口令。

### ArkTS 踩坑清单（各任务汇报里实测，不是推测）

| 规则 | 症状 | 绕法 |
|---|---|---|
| 静态字段不许写definite assignment `!` | `ServiceLocator` 用 `static x!: T` 报 `10505001 A definite assignment assertion '!' is not permitted in this context` | 改成「私有可空字段 + `static get x(): T`」，未装配就取用当场抛；调用方写法 `ServiceLocator.queue` 不变 |
| 自定义组件的方法/属性名不能与 `CustomComponent` 通用属性方法重名 | `StatusDot` 的 `size`、`PrimaryButton` 的 `enabled`、`Library` 里的 `position()` 都直接编不过：`Property 'size' ... is not assignable to the same property in base type 'CustomComponent'` | 改名：`size`→`dotSize`，`enabled`→`isEnabled`，`position()`→`pageLabel()` |
| 自定义组件后不能直接接通用属性方法 | `GlassBar(...).onAreaChange(...)` 报 `10505001 Declaration or statement expected` | 外面套一层 `Column` 再挂 `.onAreaChange` |
| 实参位置上自定义 Error 子类不当 `Error`（arkts-no-structural-typing） | `rejectFn(new ApiError(...))` 报 `10605030`；同一个 `ApiError` 放在**返回值**位置反而可以 | 加一个具名函数 `timeoutError(): Error`，内部 `return` 出去，调用方传函数结果而不是直接 `new` |
| `NavPathInfo.param` 是 `unknown`，`navDestination` builder 形参也是 `unknown` | 想用 `pushPath({ name, param })` 传对象给目标页时，`unknown` 在 ArkTS 里绕不干净，类型收窄不掉 | 不传 `param`：改成两个路由名指向同一个组件（如 `ProjectPicker` / `ProjectPickerSwitch`），差异靠 builder 里的字面量传 `boolean` |
| V1（`@State`/`@Prop`）与 V2（`@ObservedV2`/`@Trace`）状态管理混用 | `@ObservedV2`/`@Trace` 编得过（API 26 d.ts 里存在），但 `@Trace` 只在 `@ComponentV2` 里被观察——V2 父组件传给 V1 子组件的 `@Prop` 是一次性的，**编过了但界面不刷新**，没有模拟器时发现不了 | 全程只用 V1：模型类不带状态装饰器的普通单例 + `subscribe(cb)/unsubscribe(token)`，组件在回调里把值抄进自己的 `@State`，`aboutToDisappear` 里退订 |
| `Record` 字面量键必须是字符串字面量 | 见上「ArkTS 与契约生成物」第 2 条 | `{ "moving": "uploading" }` 而非 `{ moving: ... }` |
| `bundleManager.getBundleInfoForSync` 不存在 | 任务书笔误，真实 API 是 `getBundleInfoForSelfSync` | 改用真实名 + `bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT` |
| `promptAction.showToast` / `AlertDialog.show` 已废弃（API 26） | 构建告警 | 改走 `this.getUIContext().getPromptAction().showToast()` / `this.getUIContext().showAlertDialog()` |

## 签名（用户动作，不进仓）

`build-profile.json5` 的 `signingConfigs` **保持 `[]`**（spec H11）。

- 调试签名（一次）：DevEco 打开 `harmony/` → 登录华为开发者账号 →
  File › Project Structure › Signing Configs › Automatically generate signature。
  生成的材料在 `~/.ohos/config/`，DevEco 会往 `build-profile.json5` 写一段 `signingConfigs`——
  **这段不要提交**，`contract/tools/check.mjs` 扫到 `storePassword` / `keyPassword` 就红。
- 发布签名：`~/.aiworkdeck/harmony/` 下的 `.p12` + AGC 发布证书 + 发布 Profile（`.p7b` 待建），
  配到 `signingConfigs.release` 后 `hvigorw assembleApp -p buildMode=release` 出 `.app` 交 AGC。
  出包脚本另卡。

## 模拟器

2026-09-05 实测：Pura 90 Pro 镜像（HarmonyOS 7.0.0(26.0.0)）装好后，**未签名 HAP 可以直接 `hdc install`**——
模拟器走查不需要调试签名，`signingConfigs` 保持 `[]` 即可。`hdc shell` 是 uid 2000，写不进应用沙盒，
所以「灌一条本地项目」走 debug 启动参数（下面 `--ps awdSeed 1`，只在 `BuildProfile.DEBUG` 为真时生效，
对位 iOS `-AWDScreenshotMode` 与安卓 run-as 灌 prefs）。

```bash
E=/Applications/DevEco-Studio.app/Contents/tools/emulator/Emulator
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc

# 启动模拟器（镜像未下载时会报 imageRoot 不存在——去 DevEco Device Manager 下载）
$E -start "Pura 90 Pro"
$HDC list targets                      # 127.0.0.1:5555

# 装包、启动（-r 覆盖安装）；不带 --ps 就是正常启动
$HDC install -r harmony/entry/build/default/outputs/default/entry-default-unsigned.hap
$HDC shell aa start -a EntryAbility -b com.aiworkdeck.mobile.huawei --ps awdSeed 1

# 界面自动化（模拟器自带输入法会弹自己的隐私声明，用 uitest 直接送文本可绕开）
$HDC shell uitest uiInput click <x> <y>
$HDC shell uitest uiInput text <文本>
$HDC shell uitest uiInput keyEvent Home
$HDC shell uitest dumpLayout          # 控件坐标

# 截图
$HDC shell snapshot_display -f /data/local/tmp/x.jpeg && $HDC file recv /data/local/tmp/x.jpeg .

# 走查时看日志（tag 是类名）
$HDC shell hilog -x | grep -E 'RecorderService|UploadQueue|Uploader|EvidenceStore|CameraService|AppModel'
```

登录用审核账号（见项目记忆 `mobile-local-verify-recipe`，不入仓）；审核账号没有桌面端，所以要 `--ps awdSeed 1`
才进得了取景器。中转区接受假项目 `dev-emulator:1` 的上传件，7 天后自然清理。
模拟器没有相机（预览黑、拍照回调不回）和 GPS（一直「定位中」），来电中断也造不出来，这三样只能真机验。

## 走查清单

模拟器（或真机）上手动过一遍，覆盖主链路（登录用审核账号，见项目记忆 `mobile-local-verify-recipe`，不入仓）：

1. 登录（手机号 + 验证码）→ 选项目
2. 取景器拍照 ×3（可混拍照/录像/录音）
3. 上传队列：四段计数（上传中/已暂存/失败/已落盘）、顶栏「全部重试」
4. 图集：网格/列表切换、按项目分组分日、三级删除警告
5. 查看器：全屏、左右滑动、状态点 + 日期 · 类型；「记录详情」里看完整 SHA-256（可复制）；录音可拖进度、±15 秒
6. 设置：存相册开关、中转区归档路径、当前账号、用量、注销
7. **录音开录 → 按 Home 键切后台 → 30 秒后回来，计时连续、系统通知栏见长时任务通知 → 停止 → 上传队列见该件**（鸿蒙特有，验证长时任务 + 中断兜底链）

## 已知限制

从各任务汇报的「未验证项」「疑虑」汇总，实测/实证为准：

- **实况窗（Live View Kit）留卡**：`event` 只能取固定场景（最接近录音的是 `TIMER`），且每个场景要在
  AGC 申请权限，未获批调用报 `1003500005`。首版录音常驻展示用长时任务的系统通知（H7）。
- **存相册默认关**：无 `ohos.permission.WRITE_IMAGEVIDEO`（受限权限，须 AGC 申请 ACL）时只能走
  `photoAccessHelper.showAssetsCreationDialog`，每件拍照/录像完成都要弹一次系统确认。
- **AVRecorder 没有 `audioInterrupt` 事件**（那是 `AVPlayer` 的）：中断靠「状态变化 + 错误码 +
  回前台补一次 `resume()`」三重兜底，来电中断这条链没有权威事件，只能真机验证。
- **录像方向写死 `'90'`**：能问出真实旋转角的 `VideoOutput.getVideoRotation` 要等 VideoOutput 建出来，
  首版按常识猜的，没有真机样片对照。
- **去系统设置用的是文档口径的 `want`，不是 d.ts 口径**：华为改了 settings 的 `abilityName` 就会失效
  （已 try/catch，最坏情况点了没反应）；若日后 `compatibleSdkVersion` 抬到 26，可换成
  `settings.openAppDetailSettingsPage` 更稳。
- **上传 `request.agent` 后台任务的响应体取法待设备验证**：`Progress.extras` 的 `body`/`response`
  键名是按 d.ts 注释猜的，没见过真实回包；取不到时按「2xx 即成功」兜底。
- **英文 UI 未开**（H12 明确不做）。
- **无 DevEco 本地测试**（hypium）；领域层测试全部在仓库根 `tests/harmony/`，靠 Node 转译跑。
- **队列页无单件重试**：只有顶栏「全部重试」，`UploadQueue` 也只暴露 `retryFailed()`，要做单件重试得先动服务层，超出首版范围。
- **`library.otherPending` 口径**：按「当前拍摄项目」算「别处」，图集切到别的项目看时这行字口径与页面内容不一致（与安卓同源、同样的口径，非本端引入）。
- **hvigor 构建不进 CI**：GitHub runner 装不了 DevEco，构建靠本机；见下「CI」一节。

## CI

`.github/workflows/contract.yml`（`check.mjs` + `npm test` + `typecheck`）覆盖领域层与契约生成物，
`push`/`pull_request` 触及 `contract/**`、`tests/harmony/**` 等路径时跑。**没有单独的 `harmony.yml`**：
hvigor 构建（含 ArkTS 语法检查）不进 CI，runner 无 DevEco，构建与走查靠本机。

## 发版

发版流程见发版指路总表 §7.4.1：
`/Users/zewei/Documents/2024-2044/5-Tech/EXTERNAL_SERVICES.md`
（`~/.aiworkdeck/harmony/` 材料位置、发布 Profile 待建、`assembleApp -p buildMode=release` 出 `.app` 交
AGC）。出包脚本另卡。
