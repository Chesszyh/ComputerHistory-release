import SwiftUI

/// 菜单栏界面的统一设计规范常量。
///
/// 遵循 macOS Human Interface Guidelines（HIG）及 8pt 网格系统，
/// 集中管理间距、排版、圆角、尺寸与语义色。
enum DesignTokens {

    // MARK: - 尺寸规范
    enum Dimensions {
        /// 菜单栏弹窗标准宽度（392pt 符合 8pt 网格，较原 380pt 增加 12pt 呼吸感）
        static let panelWidth: CGFloat = 392
        /// 菜单栏弹窗标准高度
        static let panelHeight: CGFloat = 640
        /// 时间列宽度
        static let timeColumnWidth: CGFloat = 38
        /// 应用小图标尺寸
        static let appIconBadgeSize: CGFloat = 15
        /// 当前活动主图标尺寸
        static let liveAppIconSize: CGFloat = 30
    }

    // MARK: - 间距规范（8pt 网格比例）
    enum Spacing {
        /// 2pt
        static let xxs: CGFloat = 2
        /// 4pt
        static let xs: CGFloat = 4
        /// 6pt
        static let sm6: CGFloat = 6
        /// 8pt
        static let sm: CGFloat = 8
        /// 10pt
        static let md10: CGFloat = 10
        /// 12pt
        static let md: CGFloat = 12
        /// 14pt
        static let lg14: CGFloat = 14
        /// 16pt
        static let lg: CGFloat = 16
        /// 20pt
        static let xl20: CGFloat = 20
        /// 24pt
        static let xl: CGFloat = 24
    }

    // MARK: - 字体排版
    enum Typography {
        static let caption2 = Font.system(size: 9, weight: .regular)
        static let caption2Medium = Font.system(size: 9, weight: .medium)
        static let caption2Bold = Font.system(size: 9, weight: .bold)

        static let caption = Font.system(size: 10, weight: .regular)
        static let captionMedium = Font.system(size: 10, weight: .medium)
        static let captionSemibold = Font.system(size: 10, weight: .semibold)

        static let footnote = Font.system(size: 11, weight: .regular)
        static let footnoteMedium = Font.system(size: 11, weight: .medium)
        static let footnoteSemibold = Font.system(size: 11, weight: .semibold)

        static let body = Font.system(size: 12, weight: .regular)
        static let bodyMedium = Font.system(size: 12, weight: .medium)
        static let bodySemibold = Font.system(size: 12, weight: .semibold)

        static let headline = Font.system(size: 13, weight: .semibold)
        static let title = Font.system(size: 14, weight: .bold)

        static let monoCaption = Font.system(size: 10, weight: .medium, design: .monospaced)
        static let monoSub = Font.system(size: 9, weight: .regular, design: .monospaced)
        static let monoBody = Font.system(size: 11, weight: .regular, design: .monospaced)
    }

    // MARK: - 圆角（Apple 连续曲率 Continuous）
    enum Radius {
        /// 3.5pt：微型标签、图标
        static let iconBadge: CGFloat = 3.5
        /// 4pt：小型标签
        static let xs: CGFloat = 4
        /// 6pt：次级容器、按钮
        static let sm: CGFloat = 6
        /// 8pt：卡片通用圆角
        static let md: CGFloat = 8
        /// 10pt：聚焦卡片、外层框
        static let lg: CGFloat = 10
    }

    // MARK: - 语义色
    enum Colors {
        /// 卡片默认背景（微透明深浅自适应）
        static let cardBackground = Color.primary.opacity(0.035)
        /// 卡片细边框
        static let cardBorder = Color.primary.opacity(0.06)
        /// 卡片悬停背景
        static let cardHoverBackground = Color.primary.opacity(0.065)
        static let cardHoverBorder = Color.primary.opacity(0.09)
        /// 卡片展开态背景
        static let cardExpandedBackground = Color.primary.opacity(0.045)
        /// 离开电脑条目背景
        static let awayBackground = Color.primary.opacity(0.018)
        static let awayBorder = Color.primary.opacity(0.04)
        /// 复制成功背景与边框
        static let copyBackground = Color.green.opacity(0.12)
        static let copyBorder = Color.green.opacity(0.25)
        /// 日期分组胶囊底色
        static let sectionHeaderFill = Color.primary.opacity(0.04)
        /// 侧栏次要文字
        static let subtleText = Color.secondary
        /// 极次要文字 / 占位符
        static let mutedText = Color.secondary.opacity(0.7)
    }
}
