// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

/// 跟随系统深浅色的令牌对（T.L 浅 / T.D 深）。给跟随系统外观的界面用（个人、工作区、律所审阅）；
/// 首页与图库恒为深色，直接用 T.D。只组合现有令牌，不新造颜色。
extension T {
    enum LD {
        /// 平铺页面底：浅色 bg（色源 light/surface，即页面底）/ 深色 bg
        static let page = pair(T.L.bg, T.D.bg)
        /// 分组页面底（卡片下面那层）：浅色 sunken（色源 light/bg）/ 深色 bg
        static let groupedPage = pair(T.L.sunken, T.D.bg)
        /// 卡片与列表行：浅色 bg（色源 light/surface）/ 深色 surface
        static let surface = pair(T.L.bg, T.D.surface)
        /// 卡片上的输入框底。深色没有 sunken 令牌，用 10% 白的 rule 做填充。
        static let field = pair(T.L.sunken, T.D.rule)
        /// 选中行。深色没有 accentWash 令牌，同样用 rule 填充。
        static let selection = pair(T.L.accentWash, T.D.rule)
        static let fg = pair(T.L.fg, T.D.fg)
        static let fgMuted = pair(T.L.fgMuted, T.D.fgMuted)
        /// 深色没有 fgFaint 令牌，退到 fgMuted（宁可清楚一点，不新造灰）。
        static let fgFaint = pair(T.L.fgFaint, T.D.fgMuted)
        static let rule = pair(T.L.rule, T.D.rule)
        static let accent = pair(T.L.accent, T.S.arrivedOnDark)

        static func pair(_ light: Color, _ dark: Color) -> Color {
            Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        }
    }
}

extension View {
    /// 列表 / 表单铺在纸面上，不用 iOS 分组灰。行底另用 `.listRowBackground(T.LD.surface)`。
    func paperList() -> some View {
        scrollContentBackground(.hidden).background(T.LD.groupedPage)
    }
}
