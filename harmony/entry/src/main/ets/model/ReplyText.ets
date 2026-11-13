// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
// Display-side backstop: strip emoji from assistant replies (same rule as desktop aiworkdeck#1539 stripEmoji.js).
const EMOJI_SEQ: RegExp = new RegExp('(?:\\p{Emoji_Presentation}|\\p{Extended_Pictographic}\\uFE0F|[\\u26A0\\u2714\\u2716\\u2611])[\\u{1F3FB}-\\u{1F3FF}]?\\uFE0F?(?:\\u200D(?:\\p{Emoji_Presentation}|\\p{Extended_Pictographic})\\uFE0F?)*[ \\t]*', 'gu')
const KEYCAP: RegExp = new RegExp('\\uFE0F?\\u20E3', 'g')
export function stripEmoji(text: string): string { return text.replace(EMOJI_SEQ, '').replace(KEYCAP, '') }
