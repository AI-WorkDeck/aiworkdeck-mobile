<!-- SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors -->
<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->

# aiworkdeck-mobile：Agent 入口

开始项目工作前请阅读根目录 `CLAUDE.md`。

多语种令牌化必检（dev-board#1477）：四端（iOS / 微信小程序 / Android / HarmonyOS）全部用户可见文案一律通过 `contract/` 词典令牌化（改词典 → `node contract/tools/gen.mjs` → 调 `tr`/`t`），严禁硬编码文案。每次提交或合并 PR 前必须运行 `node contract/tools/check.mjs` 并核对 diff，若发现未令牌化文案或漏译词条，先补齐再提交/合并。
