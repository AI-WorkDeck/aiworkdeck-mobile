---
name: contract-change
description: 改动界面文案、设计令牌、传输状态、能力开关或 /api/mobile 接口形状时必须使用。契约是四端唯一来源，本 skill 给出先改 contract/ 再生成再改各端的固定步骤。
---

# 改契约

触发词：文案、措辞、改成、令牌、颜色、字号、间距、状态、桶、上传中/已暂存/已落盘、能力、后台上传、接口字段。

## 步骤

1. 定位要改的东西属于哪个文件：
   - 文案 → `contract/strings/<locale>.json`（全部已支持语言）；`contract/strings.json` 是聚合生成物，直接修改会被 `gen` 覆盖
   - 颜色 / 间距 / 字号 → `contract/tokens.json`
   - 状态名 / 桶 / 迁移 / 重试 → `contract/transfer-state.json`，同时改 `contract/fixtures/` 里相关期望
   - 能力 → `contract/capabilities.json`
   - 接口 → 服务端仓 `openapi/mobile-v1.yaml`（先过服务端 `MobileApiContractTest`），再 `node contract/tools/pull-api.mjs`
2. `node contract/tools/gen.mjs`
3. 只在行为层改各端代码（迁移逻辑、界面绑定），不改生成物、不内联文案。
4. `node contract/tools/check.mjs && npm test`；改了 iOS 再跑 WorkdeckTests。
5. 提交信息写明改了契约哪一项。

## 不要

- 直接改 `ios/Sources/Contract/*`、`miniprogram/utils/contract/*`、`miniprogram/styles/tokens.wxss`
- 在 Swift / TS 里写中文字面量表达状态或桶
- 改状态落盘字符串而不加别名
