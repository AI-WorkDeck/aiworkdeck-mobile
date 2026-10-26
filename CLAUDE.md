# aiworkdeck-mobile

四个原生端（iOS Swift / 微信小程序 / 安卓 Kotlin / 鸿蒙 ArkTS）共享一份契约。
设计见 `docs/specs/2026-09-02-contract-design.md`，操作步骤见 `contract/README.md`。

## 契约规矩（每次改动前先读）

1. 状态名、桶名、界面文案、设计令牌、能力开关、API 形状的**唯一来源**是 `contract/`。
   不要在 Swift / TS / Kotlin / ArkTS 里直接改这些值。
2. 改动顺序：先改 `contract/*.json` 与 `contract/fixtures/`，跑 `node contract/tools/gen.mjs`，
   再改各端行为代码；生成物（文件头带 GENERATED）进仓提交，不要手改生成物。
3. **Day-One 多语种令牌化硬规则与合并前必检（dev-board#1477）**：
   - 四个原生端（iOS Swift / 微信小程序 WXML+TS / 安卓 Kotlin / 鸿蒙 ArkTS）的全部用户可见文案（含相机、队列、图集、项目、设置、登录、录音权限、网络报错、文件前缀、诊断提示）**一律走契约词典键**（iOS `tr`、小程序 `t` 且在 `onLoad`/`onShow` 动态刷新、安卓/鸿蒙 `tr`/`trIn`），严禁在源码中硬编码中文或英文 UI 字面量。
   - 新增或修改文案必须先写入 `contract/strings/<locale>.json`（或 `contract/strings.json`），运行 `node contract/tools/gen.mjs` 生成四端代码后再引用。
   - **RTL 与区域/国家默认语言映射**：`ar`（阿拉伯语）为 `dir: "rtl"`，四端根容器与页面均按 `isRtl` / `isRTL` 切换方向，等宽哈希/坐标/手机号等保持 `ltr`；国家代码映射使用 `matchCountryToLocale`。
   - **每次提交或合并 PR 前必须运行 `node contract/tools/check.mjs` 并检查 diff**：`check.mjs` 会扫描四端源码中的裸中文、校验多语言词条与 `{placeholder}` 占位符对齐；若发现未令牌化文案或漏译词条，**必须先补齐令牌与多语种词条、跑过 `check.mjs` 后再提交/合并**。
4. 提交前 `node contract/tools/check.mjs` 必须绿（pre-commit 与 CI 都会再跑）。
5. API 变更先改服务端仓 `backend/src/main/resources/openapi/mobile-v1.yaml` 并过
   `MobileApiContractTest`，再在本仓 `node contract/tools/pull-api.mjs` 刷新副本。
6. 新端（安卓、鸿蒙）从生成物起步；先写一个夹具适配测试，再写第一屏。

涉及文案 / 令牌 / 状态 / 能力 / 接口的任务，先用 `contract-change` skill。

## 本地验证

- 小程序：`npm ci && npm run typecheck && npm test`
- iOS：`cd ios && xcodegen generate && xcodebuild test -scheme Workdeck -only-testing:WorkdeckTests -destination "platform=iOS Simulator,name=<可用 iPhone>"`
- 契约：`node contract/tools/check.mjs`

统一项目目录与新旧身份兼容见 `docs/specs/2026-10-11-unified-project-catalog.md`（dev-board #1190）。项目名不作身份，已尝试传输的 deviceId/key 不随云目录更新改写。
