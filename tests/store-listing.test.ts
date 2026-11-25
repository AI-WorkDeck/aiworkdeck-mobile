// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const root = join(import.meta.dirname, '..')
const read = (p: string) => readFileSync(join(root, p), 'utf8').trim()

// Store "what's new" must tell users what changed in the app, within the Play limit, and never
// be left as an internal note (POLISH M7: it once said only "copyright updated to ...").
for (const locale of ['en-US', 'zh-Hans', 'zh-Hant']) {
  test(`Android ${locale} release notes describe the app and fit the store limit`, () => {
    const notes = read(`android/store/listing/${locale}/release_notes.txt`)
    assert.ok(notes.length > 40, 'release notes are too short to say what changed')
    assert.ok(notes.length <= 500, `release notes have ${notes.length} characters; Play allows 500`)
    assert.doesNotMatch(notes, /copyright|版权|GONG FU|公富/i, 'release notes must not be a legal or entity note')
  })
}
