# aiworkdeck-mobile

四个原生端（iOS Swift / 微信小程序 / 安卓 Kotlin / 鸿蒙 ArkTS）共享一份契约。
设计见 `docs/specs/2026-09-02-contract-design.md`，操作步骤见 `contract/README.md`。

## 契约规矩（每次改动前先读）

1. 状态名、桶名、界面文案、设计令牌、能力开关、API 形状的**唯一来源**是 `contract/`。
   不要在 Swift / TS / Kotlin / ArkTS 里直接改这些值。
2. 改动顺序：先改 `contract/*.json` 与 `contract/fixtures/`，跑 `node contract/tools/gen.mjs`，
   再改各端行为代码；生成物（文件头带 GENERATED）进仓提交，不要手改生成物。
3. 取证主流程（相机、队列、图集、归档确认）界面文案中，**词典里已有的一律走键**
   （iOS `tr`、小程序 `t`，wxml 经 data 绑定）；**新增文案先进 `strings.json` 再用**。
   剩余未入词典的历史内联文案另卡迁移。`check.mjs` 扫的就是第一条：手抄词典里已有的值即红。
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
