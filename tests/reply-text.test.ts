// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { stripEmoji } from '../miniprogram/utils/reply-text.ts'
// @ts-ignore pure ArkTS module.
import { stripEmoji as stripEmojiHarmony } from '../harmony/entry/src/main/ets/model/ReplyText.ets'

const keep = '© 2026 甲方 ↔ 乙方 ▶ 见第 3 条 ™ ® ✓ ★ § ¶ →'
const cases: [string, string][] = [
  ['### ✅ 第一条 — 引用正确', '### 第一条 — 引用正确'],
  ['| 一 | ❌ 错误 |', '| 一 | 错误 |'],
  ['**⚠️ One problem:** x', '**One problem:** x'],
  ['已完成🎉。', '已完成。'],
  ['👨‍⚖️ 法官', '法官'],
  ['👍🏻 好', '好'],
  ['1️⃣ 第一步', '1 第一步'],
  [keep, keep],
]
test('assistant reply emoji is stripped on mini program and Harmony, plain symbols kept', () => {
  for (const [input, expected] of cases) {
    assert.equal(stripEmoji(input), expected)
    assert.equal(stripEmojiHarmony(input), expected)
  }
})
