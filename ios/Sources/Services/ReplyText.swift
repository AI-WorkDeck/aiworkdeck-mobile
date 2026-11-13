// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Display-side backstop: strip emoji from assistant replies (same rule as desktop aiworkdeck#1539 stripEmoji.js).
/// Swift has no Extended_Pictographic property; `isEmoji` outside ASCII is the same set for this purpose
/// (the remainder, skin-tone modifiers and regional indicators, are Emoji_Presentation anyway).
enum ReplyText {
    private static func presentation(_ s: Unicode.Scalar) -> Bool { s.properties.isEmojiPresentation }
    private static func pictographic(_ s: Unicode.Scalar) -> Bool { s.value > 0x7F && s.properties.isEmoji }
    private static func isStart(_ cps: [Unicode.Scalar], _ i: Int) -> Bool {
        let c = cps[i]
        if presentation(c) { return true }
        if pictographic(c) && i + 1 < cps.count && cps[i + 1].value == 0xFE0F { return true }
        return [0x26A0, 0x2714, 0x2716, 0x2611].contains(c.value)
    }

    static func stripEmoji(_ text: String) -> String {
        let cps = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        func at(_ i: Int) -> UInt32? { i < cps.count ? cps[i].value : nil }
        var i = 0
        while i < cps.count {
            let c = cps[i]
            if c.value == 0xFE0F && at(i + 1) == 0x20E3 { i += 2; continue }
            if c.value == 0x20E3 { i += 1; continue }
            if !isStart(cps, i) { out.append(c); i += 1; continue }
            i += 1
            if let v = at(i), (0x1F3FB...0x1F3FF).contains(v) { i += 1 }
            if at(i) == 0xFE0F { i += 1 }
            while at(i) == 0x200D, i + 1 < cps.count, presentation(cps[i + 1]) || pictographic(cps[i + 1]) {
                i += 2
                if at(i) == 0xFE0F { i += 1 }
            }
            while at(i) == 0x20 || at(i) == 0x09 { i += 1 }
        }
        return String(out)
    }
}
