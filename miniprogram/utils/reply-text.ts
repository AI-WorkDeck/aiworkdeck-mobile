// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
// Display-side backstop: strip emoji from assistant replies (same rule as desktop aiworkdeck#1539 stripEmoji.js).
const EMOJI_SEQ = /(?:\p{Emoji_Presentation}|\p{Extended_Pictographic}️|[⚠✔✖☑])[\u{1F3FB}-\u{1F3FF}]?️?(?:‍(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})️?)*[ \t]*/gu
const KEYCAP = /️?⃣/g
export function stripEmoji(text: string): string { return text.replace(EMOJI_SEQ, '').replace(KEYCAP, '') }
