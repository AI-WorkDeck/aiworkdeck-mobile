// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import Workdeck

final class ReplyTextTests: XCTestCase {
    func testStripsEmojiAndKeepsPlainSymbols() {
        let keep = "© 2026 甲方 ↔ 乙方 ▶ 见第 3 条 ™ ® ✓ ★ § ¶ →"
        let cases: [(String, String)] = [
            ("### ✅ 第一条 — 引用正确", "### 第一条 — 引用正确"),
            ("| 一 | ❌ 错误 |", "| 一 | 错误 |"),
            ("**⚠️ One problem:** x", "**One problem:** x"),
            ("已完成🎉。", "已完成。"),
            ("👨‍⚖️ 法官", "法官"),
            ("👍🏻 好", "好"),
            ("1️⃣ 第一步", "1 第一步"),
            (keep, keep),
        ]
        for (input, expected) in cases { XCTAssertEqual(ReplyText.stripEmoji(input), expected, input) }
    }
}
