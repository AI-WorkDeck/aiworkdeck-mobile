import SwiftUI
import UIKit

/// 字体与动效不是纯数据（含字重、弹簧参数），手写在这里；尺寸与时长引用生成的 T.Ty / T.Motion。
extension T {
    /// 尺寸保持 T.Ty 的默认值，但随 Dynamic Type 缩放（relativeTo:），辅助功能大字号不再被截断。
    enum F {
        /// 只给关键数字
        static func hero() -> Font { scaled(T.Ty.hero, .largeTitle, .light).monospaced() }
        static func display() -> Font { scaled(T.Ty.display, .title, .semibold) }
        static func title() -> Font { scaled(T.Ty.title, .title2, .semibold) }
        static func heading() -> Font { scaled(T.Ty.heading, .headline, .semibold) }
        static func body() -> Font { scaled(T.Ty.body, .body) }
        static func small() -> Font { scaled(T.Ty.small, .footnote) }
        static func micro() -> Font { scaled(T.Ty.micro, .caption2) }
        /// 全大写字距拉开的小标签。字距是这套排版的签名。
        static func nano() -> Font { scaled(T.Ty.nano, .caption2, .medium) }
        /// 哈希、时间、坐标、计数一律等宽 —— 取证信息要能逐字符核对
        static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            scaled(size, style(for: size), weight).monospaced()
        }

        /// SwiftUI 没有 `.system(size:relativeTo:)`；只有 `.custom(_:size:relativeTo:)` 能既保留自定尺寸又跟随 Dynamic Type。
        /// 系统字体的族名在运行时取，并核对确实解析回系统字体；万一解析不到（CoreText 会悄悄换成别的字体），
        /// 退回固定尺寸的系统字体，宁可不缩放也不换字体。
        private static let systemFamily: String? = {
            let family = UIFont.systemFont(ofSize: T.Ty.body).familyName
            return UIFont(name: family, size: T.Ty.body)?.familyName == family ? family : nil
        }()

        private static func scaled(_ size: CGFloat, _ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
            guard let systemFamily else { return .system(size: size, weight: weight) }
            return .custom(systemFamily, size: size, relativeTo: style).weight(weight)
        }

        /// 默认尺寸最接近的系统文字样式，决定缩放曲线。
        private static func style(for size: CGFloat) -> Font.TextStyle {
            switch size {
            case ..<12: .caption2
            case ..<14: .footnote
            case ..<16.5: .body
            case ..<20: .headline
            case ..<26: .title2
            case ..<32: .title
            default: .largeTitle
            }
        }
    }

    /// 动效只用来表达「照片正在离开手机 / 在路上 / 已抵达」。不做装饰性动画。
    enum A {
        static let fast = Animation.easeOut(duration: T.Motion.fast)
        static let base = Animation.spring(response: 0.32, dampingFraction: 0.82)
        static let rise = Animation.spring(response: 0.42, dampingFraction: 0.86)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
