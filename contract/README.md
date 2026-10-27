# contract/ — 四端共享契约

真源。四端不共享 UI 代码，共享这里的数据与夹具。设计：`docs/specs/2026-09-02-contract-design.md`。

| 文件 | 管什么 |
|---|---|
| `transfer-state.json` | 五态、别名、三桶、迁移表、重试、删除警告等级 |
| `strings.json` | 文案 key → {zh-Hans, en} |
| `tokens.json` | 设计令牌（基准 pt；wxss ×2 rpx；字号 px） |
| `capabilities.json` | 四端能力声明与降级提示键 |
| `api/mobile-v1.yaml` + `PINNED.json` | 服务端 OpenAPI 的钉版副本 |
| `fixtures/` | 黄金向量，四端各自适配跑 |

## 改法

1. 改 JSON（改状态机时同步改 `fixtures/`）
2. `node contract/tools/gen.mjs`
3. 改各端行为代码
4. `node contract/tools/check.mjs && npm test`（iOS 另跑 WorkdeckTests）

## 生成物

`miniprogram/styles/tokens.wxss`、`miniprogram/utils/contract/`、`ios/Sources/Contract/`、
`android/contract/`、`harmony/contract/`。文件头带 GENERATED，不要手改。

## Personal workspace (2026-10-27)

`personalConsentVersion` is shared by calendar synchronization and cloud-summary assistant consent. The four clients use the pinned mobile assistant/calendar API and the `personal.*` string family in all 20 locales. APNs `loc-key: personal.reminders` resolves through generated iOS `Localizable.strings`; do not hand-edit those files. APNs is opt-in at build/signing time and defaults off. Calendar reminders are local on iOS, WorkManager-based on Android and system-reminder-based on Harmony; WeChat has no configured background reminder template. See `docs/specs/2026-10-27-personal-workspace.md` for restoration, entitlement and notification boundaries.
