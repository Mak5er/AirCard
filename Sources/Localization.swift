// MARK: - AirCard Localization Configuration (多语言配置文件)
// This file centralizes all localization definitions, language settings, and translation tables.
// To add a new language (e.g. Japanese, Russian, German), add an enum case and a dictionary below.

import Foundation
import SwiftUI

// MARK: - Supported Languages

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case en = "en"
    case zhHans = "zh-Hans"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system:
            return LocalizationManager.shared.isChinese ? "跟随系统 (中文)" : "System (Auto)"
        case .en:
            return "English"
        case .zhHans:
            return "简体中文"
        }
    }
}

// MARK: - Localization Configuration & Manager

public final class LocalizationManager: ObservableObject {
    public static let shared = LocalizationManager()

    private let storageKey = "aircard.language_preference"

    @Published public private(set) var currentLanguage: AppLanguage = .system
    @Published public private(set) var isChinese: Bool = false

    private init() {
        let stored = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.system.rawValue
        let lang = AppLanguage(rawValue: stored) ?? .system
        self.currentLanguage = lang
        self.isChinese = resolveIsChinese(for: lang)
    }

    public func setLanguage(_ lang: AppLanguage) {
        UserDefaults.standard.set(lang.rawValue, forKey: storageKey)
        currentLanguage = lang
        isChinese = resolveIsChinese(for: lang)
        objectWillChange.send()
    }

    private func resolveIsChinese(for lang: AppLanguage) -> Bool {
        switch lang {
        case .en:
            return false
        case .zhHans:
            return true
        case .system:
            let preferred = Locale.preferredLanguages.first ?? ""
            return preferred.hasPrefix("zh")
        }
    }

    /// Translates a string into the active language.
    /// Falls back to dynamic prefix matching, format string matching, or key itself.
    public func tr(_ key: String) -> String {
        guard isChinese else { return key }

        // 1. Exact match in translation table
        if let translated = zhTranslations[key] {
            return translated
        }

        // 2. Prefix & dynamic patterns
        if key.hasPrefix("Selected ") {
            let target = String(key.dropFirst("Selected ".count))
            return "已选择 " + tr(target)
        }
        if key.hasPrefix("Connected to ") {
            let target = String(key.dropFirst("Connected to ".count))
            return "已连接到 " + target
        }
        if key.hasPrefix("Detected active card: ") {
            let target = String(key.dropFirst("Detected active card: ".count))
            return "检测到激活的卡片：" + target
        }
        if key.hasPrefix("Added card: ") {
            let target = String(key.dropFirst("Added card: ".count))
            return "已添加卡片：" + target
        }
        if key.hasPrefix("Removed card: ") {
            let target = String(key.dropFirst("Removed card: ".count))
            return "已移除卡片：" + target
        }
        if key.hasPrefix("Theme exported successfully to ") {
            let target = String(key.dropFirst("Theme exported successfully to ".count))
            return "主题已成功导出至 " + target
        }
        if key.hasPrefix("Exported .passthm to ") {
            let target = String(key.dropFirst("Exported .passthm to ".count))
            return "已导出 .passthm 至 " + target
        }
        if key.hasPrefix("Preparing skin for ") {
            let target = String(key.dropFirst("Preparing skin for ".count))
            return "正在准备卡面：" + target
        }
        if key.hasPrefix("Updated key ") {
            let target = String(key.dropFirst("Updated key ".count))
            return "已更新按键 " + target
        }
        if key.hasPrefix("Cleared key ") {
            let target = String(key.dropFirst("Cleared key ".count))
            return "已清除按键 " + target
        }
        if key.hasPrefix("Choose Icon for Key ") {
            let target = String(key.dropFirst("Choose Icon for Key ".count))
            return "选择按键 " + target + " 的图标"
        }
        if key.hasPrefix("Change Key ") {
            let target = String(key.dropFirst("Change Key ".count))
            return "更换按键 " + target
        }
        if key.hasPrefix("Clear Key ") {
            let target = String(key.dropFirst("Clear Key ".count))
            return "清除按键 " + target
        }
        if key.hasPrefix("Deselect Key ") {
            let target = String(key.dropFirst("Deselect Key ".count))
            return "取消选择按键 " + target
        }
        if key.hasPrefix("Drag Key ") && key.contains(" on dialer preview to reposition") {
            let digit = key.replacingOccurrences(of: "Drag Key ", with: "").replacingOccurrences(of: " on dialer preview to reposition", with: "")
            return "在拨号盘预览上拖拽按键 " + digit + " 进行重置位置"
        }
        if key.hasPrefix("Fast mode selected: only targets ") {
            return key.replacingOccurrences(of: "Fast mode selected: only targets ", with: "已选择快速模式：仅针对 ")
                      .replacingOccurrences(of: " with ", with: " 并使用 ")
        }
        if key.hasPrefix("Detected ") && key.contains(" distinct card(s) this scan. Open any missing card in Wallet to check it.") {
            let num = key.replacingOccurrences(of: "Detected ", with: "").replacingOccurrences(of: " distinct card(s) this scan. Open any missing card in Wallet to check it.", with: "")
            return "本次扫描检测到 \(num) 张不同的卡片。在“钱包”中打开任何未显示的卡片以进行检查。"
        }
        if key.hasPrefix("Verified ") && key.contains(" card(s) from this iPhone's current Wallet activity.") {
            let num = key.replacingOccurrences(of: "Verified ", with: "").replacingOccurrences(of: " card(s) from this iPhone's current Wallet activity.", with: "")
            return "已从本次 iPhone 钱包活动中验证 \(num) 张卡片。"
        }
        if key.hasPrefix("Matched ") && key.contains(" payment card(s) to this iPhone. Open membership cards individually if any are missing.") {
            let num = key.replacingOccurrences(of: "Matched ", with: "").replacingOccurrences(of: " payment card(s) to this iPhone. Open membership cards individually if any are missing.", with: "")
            return "已为该 iPhone 匹配 \(num) 张支付卡。若有会员卡缺失，请在“钱包”中单独点开。"
        }
        if key.hasPrefix("Added ") && key.contains(" card ID(s) ready for skinning and flashing.") {
            let num = key.replacingOccurrences(of: "Added ", with: "").replacingOccurrences(of: " card ID(s) ready for skinning and flashing.", with: "")
            return "已添加 \(num) 个卡片 ID，已准备好设置卡面并刷入。"
        }
        if key.hasPrefix("Scanner stopped unexpectedly (exit ") && key.contains("). Reconnect and unlock the iPhone, then scan again. Check Log for details.") {
            let code = key.replacingOccurrences(of: "Scanner stopped unexpectedly (exit ", with: "").replacingOccurrences(of: "). Reconnect and unlock the iPhone, then scan again. Check Log for details.", with: "")
            return "扫描器意外停止 (退出代码 \(code))。请重新连接并解锁 iPhone 后重试。详情请查看日志。"
        }
        if key.hasPrefix("Scan stopped. ") && key.contains(" card(s) detected.") {
            let num = key.replacingOccurrences(of: "Scan stopped. ", with: "").replacingOccurrences(of: " card(s) detected.", with: "")
            return "扫描已停止。检测到 \(num) 张卡片。"
        }
        if key.hasSuffix(" card(s) verified.") {
            let num = String(key.dropLast(" card(s) verified.".count))
            return "\(num) 张卡片已验证。"
        }

        // Return original if no translation exists
        return key
    }

    /// Formats a string using localized template and arguments
    public func trFormat(_ formatKey: String, _ args: [CVarArg]) -> String {
        guard isChinese else {
            return String(format: formatKey, locale: Locale(identifier: "en"), arguments: args)
        }
        let template = zhTranslations[formatKey] ?? formatKey
        return String(format: template, locale: Locale(identifier: "zh-Hans"), arguments: args)
    }

    // MARK: - Simplified Chinese Translation Dictionary (简体中文多语言配置)
    private let zhTranslations: [String: String] = [
        "&": "与",
        "Copied to clipboard!": "已复制到剪贴板！",
        "Click to copy": "点击复制",
        "Copy Address": "复制地址",
        "Clear Selected": "清除已选按键",
        "Apply Sliced Keys to Individual": "将切片应用到独立按键",
        "Slice and apply wallpaper to all 10 keys": "切割壁纸并应用到全部 10 个按键",
        "Load Theme into Creator...": "加载主题至制作器...",
        "Reset Creator": "重置制作器",
        "Select an icon or image for key %@...": "为按键 %@ 选择图标或图片...",
        "Theme exported successfully to %@": "主题已成功导出至 %@",
        "Exported .passthm to %@": "已导出 .passthm 至 %@",
        "Failed to export theme: %@": "导出主题失败：%@",
        "Apple Wallet": "Apple 钱包",
        "AirCard needs Xcode Command Line Tools to communicate with devices.\n\nPlease open Terminal and run:\nxcode-select --install\n\nor open Xcode to accept the license agreement, then restart AirCard.": "AirCard 需要 Xcode 命令行工具来与设备通信。\n\n请打开“终端”并运行：\nxcode-select --install\n\n或打开 Xcode 同意许可协议，然后重新启动 AirCard。",
        "Scanner connected. Open Wallet and tap a card; membership cards may need opening in the Wallet app.": "扫描器已连接。请打开“钱包”并轻触卡片；会员卡可能需要在“钱包”App 中单独点开。",
        "Passcode (.passthm)": "锁屏密码主题 (.passthm)",
        "Apple Wallet & Passcode Themes": "Apple 钱包卡面与锁屏密码主题",
        "Apply .passthm": "应用 .passthm",
        "Theme Creator": "主题制作器",
        "Poster Slice (Puzzle)": "海报切割 (拼图)",
        "Individual Keys": "独立按键",
        "Ready": "就绪",
        "Connected": "已连接",
        "Not Connected": "未连接",
        "No iPhone (USB)": "未连接 iPhone (USB)",
        "Connected Devices (%d)": "已连接设备 (%d)",
        "Refresh Devices": "刷新设备列表",
        "Select Device": "选择设备",
        "Click to select active device": "点击以选择当前操作的设备",
        "Refresh device connection": "刷新设备连接",
        "Switch Language": "切换语言",
        "Apple Device": "Apple 设备",
        "Locked/Unpaired": "已锁定/未配对",
        "Scan Cards": "扫描卡片",
        "Select All": "全选",
        "Deselect All": "取消全选",
        "Clear Skins": "清除卡面",
        "Clear Skin": "清除卡面",
        "Remove Card": "移除卡片",
        "Remove": "移除卡片",
        "Add Card": "添加卡片",
        "Flash Skins": "写入卡面",
        "Stop Scanner": "停止扫描",
        "Scanning for cards...": "正在扫描卡片...",
        "Scan live card taps from Apple Wallet": "轻点 iPhone 钱包中的卡片以进行扫描",
        "Select all detected cards": "选择所有已检测到的卡片",
        "Deselect all cards": "取消选择所有卡片",
        "Clear custom skins from selected cards": "清除已选卡片的自定义卡面",
        "Remove selected cards from list": "从列表中移除已选卡片",
        "Enter card hashes manually": "手动输入卡片 Hash",
        "Apply custom skins to selected cards": "将自定义卡面写入已选卡片",
        "Ready to flash %d card(s)": "已就绪 %d 张卡面待写入",
        "%d card(s) modified": "%d 张卡片已修改",
        "Select cards and assign custom skins to flash.": "请选择卡片并为其分配自定义卡面以进行写入。",
        "Drop replacement artwork here": "拖放新卡面图片至此处",
        "Click to choose custom artwork": "点击选取自定义卡面",
        "Change Skin...": "更换卡面...",
        "Assign Image to All Selected...": "为所有选中项分配图片...",
        "Choose an image to assign to all selected cards...": "选择要分配给所有选中卡片的卡面图片...",
        "Card #%d": "卡片 #%d",
        "Verified Cards (%d)": "已验证卡片 (%d)",
        "Pending Cards (%d)": "待验证卡片 (%d)",
        "From Mac Wallet cache · Not verified in this scan": "来自 Mac 钱包缓存 · 本次扫描未核验",
        "Tap this card in Wallet to verify": "在“钱包”中轻触此卡片以验证",
        "Verified on this iPhone": "已在此 iPhone 上验证",
        "Cache from %@": "缓存时间 %@",
        "No Cards Found": "未找到卡片",
        "No Cards Detected": "未检测到卡片",
        "Connect your iPhone and click 'Scan Cards' to begin.": "连接您的 iPhone 并点击“扫描卡片”开始。",
        "Open Apple Wallet on your iPhone and tap a card to discover it.": "在 iPhone 上打开“钱包”并轻点卡片以检测它。",
        "Open Wallet and scan cards to verify this iPhone's saved entries.": "打开“钱包”并轻点卡片以验证此 iPhone 上保存的卡片。",
        "Scanning iPhone Wallet…": "正在扫描 iPhone 钱包…",
        "%d card(s) verified · %d hidden": "%d 张卡片已验证 · %d 张隐藏",
        "%d card(s) verified": "%d 张卡片已验证",
        "No cards detected. Tap 'Scan Cards' to begin.": "未检测到卡片。点击“扫描卡片”开始。",
        "Reading…": "正在读取…",
        "Read Cache": "读取缓存",
        "Read this Mac's Wallet cache": "读取此 Mac 的钱包缓存",
        "Reconnect": "重新连接",
        "Cache date: %@": "缓存日期: %@",
        "Pending Payment Cards (%d):": "待验证支付卡 (%d):",
        "Pending Passes / Memberships (%d):": "待验证凭证 / 会员卡 (%d):",
        "All cached cards on this Mac have been verified.": "此 Mac 上的所有缓存卡片均已验证。",
        "Check missing cards (%d)": "查看未检测到的卡片 (%d)",
        "Check missing cards": "查看未检测到的卡片",
        "Not verified": "未验证",
        "Theme Package (.passthm)": "主题包 (.passthm)",
        "Interactive Mockup Preview": "交互式锁屏模型预览",
        "Drop .passthm file here or click Browse": "拖放 .passthm 文件至此处或点击浏览",
        "Select .passthm file...": "选择 .passthm 主题文件...",
        "Browse...": "浏览...",
        "Apply Passcode Theme": "应用锁屏密码主题",
        "Loaded theme: '%@' (%d assets)": "已加载主题：'%@' (%d 个素材)",
        "No theme package selected. Choose a .passthm file to preview and apply.": "未选择主题包。请选择 .passthm 文件以进行预览和应用。",
        "Poster Image": "海报图片",
        "Drop poster/wallpaper here": "将海报或壁纸拖放至此处",
        "Choose Poster...": "选择海报...",
        "Clear Poster": "清除海报",
        "Framing & Crop": "取景与裁剪",
        "Horizontal Position": "水平位置",
        "Vertical Position": "垂直位置",
        "Zoom Scale": "缩放比例",
        "Slice & Apply to Keys": "切割并应用到按键",
        "Reset Crop": "重置裁剪",
        "Target Settings": "目标系统设置",
        "TelephonyUI Version": "TelephonyUI 版本",
        "Keypad Language": "键盘语言",
        "Font Weight": "字重",
        "Export Theme (.passthm)": "导出主题 (.passthm)",
        "Save As...": "另存为...",
        "Reset All Keys": "重置所有按键",
        "Clear Selected Key": "清除选中按键",
        "Load Existing Theme...": "加载现有主题...",
        "Interactive Live Mockup Preview": "iPhone 锁屏交互式实时预览",
        "Tap 0-9 to test keypad feedback · Drag poster to adjust framing": "轻点 0-9 测试按键反馈 · 拖拽海报可微调取景位置",
        "Poster image loaded · ready for framing and slicing": "海报图片已加载 · 可进行取景与切割",
        "Reset Position & Zoom": "重置位置与缩放",
        "All Languages (Universal)": "全部语言 (通用)",
        "Ukrainian (uk)": "乌克兰语 (uk)",
        "Russian (ru)": "俄语 (ru)",
        "English (en)": "英语 (en)",
        "Other / Fallback": "其他 / 兜底",
        "Spanish (es)": "西班牙语 (es)",
        "German (de)": "德语 (de)",
        "French (fr)": "法语 (fr)",
        "Polish (pl)": "波兰语 (pl)",
        "Italian (it)": "意大利语 (it)",
        "Portuguese (pt)": "葡萄牙语 (pt)",
        "Turkish (tr)": "土耳其语 (tr)",
        "Japanese (ja)": "日语 (ja)",
        "Korean (ko)": "韩语 (ko)",
        "Chinese (zh)": "中文 (zh)",
        "Arabic (ar)": "阿拉伯语 (ar)",
        "Hebrew (he)": "希伯来语 (he)",
        "Universal (Regular + Bold)": "全部包含 (常规 + 粗体)",
        "Bold Text Only (Fast)": "仅粗体文本 (快速)",
        "Regular Font Only (Fast)": "仅常规字体 (快速)",
        "Success!": "成功！",
        "Error": "错误",
        "Notice": "提示",
        "OK": "好",
        "Done": "完成",
        "Cancel": "取消",
        "Save": "保存",
        "Export": "导出",
        "Copied!": "已复制！",
        "Copy": "复制",
        "Passcode theme applied successfully!\n\nLock your iPhone (or restart) to see the new keypad in action.": "锁屏密码主题已成功应用！\n\n请锁定 iPhone（或重启设备）以查看全新的密码键盘效果。",
        "Skins flashed successfully to all selected cards!\n\nForce-close the Wallet app on your iPhone from the app switcher (or restart your device) to view the new card artwork.\n\nNote: Apple Card renders dynamically from vector assets based on spending categories, not a static cached face.": "卡面已成功应用至所有选中的卡片！\n\n请在 iPhone 上的多任务切换器中彻底关闭“钱包”App（或重启设备）以查看新卡面设计。\n\n提示：Apple Card 采用动态矢量渲染，其卡面颜色反映消费类别，而非静态缓存卡面。",
        "AirCard Credits & Support": "AirCard 致谢与支持",
        "Credits": "致谢",
        "Donate ❤️": "支持作者 ❤️",
        "Support AirCard": "支持 AirCard 项目",
        "Enter AirCard": "进入 AirCard",
        "Don't show this popup on launch": "启动时不再显示此弹窗",
        "You can reopen donation options anytime in Credits & Donate ❤️": "你可以随时在“致谢与支持”中重新打开捐赠页面 ❤️",
        "Apple Wallet Skins & Passcode Themes (iOS 18.0 – 27.2 b2)": "Apple 钱包卡面与锁屏密码主题定制 (iOS 18.0 – 27.2 b2)",
        "airlift (AirTraffic sync escape)": "airlift (AirTraffic 同步逃逸)",
        "Activity Log": "活动日志",
        "Clear": "清空",
        "Close": "关闭",
        "Show Activity Log": "显示活动日志",
        "Hide Activity Log": "隐藏活动日志",
        "Add Card Hashes": "添加卡片 Hash",
        "Enter one or more card hashes (separated by commas or spaces):": "输入一个或多个卡片 Hash（以逗号或空格分隔）：",
        "Add": "添加",
        "Could not request device log streaming.": "无法请求设备日志流。",
        "The device refused to start log streaming.": "设备拒绝启动日志流。",
        "Connected to the unified device log stream.": "已连接到统一设备日志流。",
        "iPhone not found. Reconnect it via USB.": "未找到 iPhone。请通过 USB 重新连接。",
        "Could not connect to the iPhone.": "无法连接到 iPhone。",
        "Unlock the iPhone and trust this Mac, then retry.": "请解锁 iPhone 并信任此 Mac，然后重试。",
        "Could not open the device log service. Unlock the iPhone and retry.": "无法打开设备日志服务。请解锁 iPhone 后重试。",
        "More than one cached device matches these cards. Payment names and missing-card counts are withheld.": "有多个缓存设备与这些卡片匹配。已暂停显示支付卡片名称和未检测卡片计数。",
        "More than one cached device has this model. Activate one payment card to identify the correct Wallet cache.": "存在多台相同型号的缓存设备。请激活一张支付卡以识别正确的钱包缓存。",
        "Scan a payment card on the connected iPhone to match its cache. A missing match can also mean the Mac cache is unavailable or out of date.": "请在已连接的 iPhone 上扫描一张支付卡以匹配其缓存。若未匹配，也可能意味着 Mac 缓存不可用或已过期。",
        "Payment cache could not be read. Scanning still works; reconnect the iPhone and use Read Cache to retry.": "无法读取支付缓存。扫描功能仍可使用；请重新连接 iPhone 并点击“读取缓存”重试。",
        "Membership cache could not be read. Open membership cards in the iPhone Wallet app and scan them directly.": "无法读取凭证与会员卡缓存。请在 iPhone“钱包”应用中打开卡片直接扫描。",
        "Some membership metadata could not be read. The cache list may be incomplete.": "部分凭证与会员卡元数据无法读取。缓存列表可能不完整。",
        ".passthm standard (Cowabunga / Nugget)": ".passthm 标准格式 (Cowabunga / Nugget)",
        "@mak5er • Lead Developer": "@mak5er • 主开发者",
        "A payment card was activated, but its ID is not available in this Mac's Wallet cache. Use Read Cache and try again.": "检测到支付卡已激活，但其 ID 不在此 Mac 的钱包缓存中。请点击“读取缓存”后重试。",
        "Adopted poster slices to individual keys": "已将海报切片应用到独立按键",
        "AirCard could not read the image you picked for one of the cards. That card was left unchanged.": "AirCard 无法读取为某张卡片所选的图片，该卡片保持未修改状态。",
        "AirCard could not run its device tools. Check the Activity Console log for details.": "AirCard 无法运行设备组件。详情请查看活动控制台日志。",
        "Artwork Loaded": "素材已载入",
        "Artwork is clipped into individual circular button icons.": "素材被裁剪为独立的圆形按键图标。",
        "Assign Card Skin": "设置卡片卡面",
        "Assign one skin to all selected cards": "为所有选中的卡片分配相同卡面",
        "Auto-detect": "自动检测",
        "Bundled device_helper not found — cannot scan.": "未找到内置的 device_helper —— 无法扫描。",
        "Bundled device_helper not found — detection cannot run.": "未找到内置的 device_helper —— 无法执行设备检测。",
        "By": "开发者：",
        "Card scanning ended. Check the log and reconnect the iPhone to retry.": "卡片扫描已结束。详情请查看日志，并重新连接 iPhone 重试。",
        "Card scanning failed. Check the log and retry.": "卡片扫描失败。详情请查看日志并重试。",
        "Category": "分类",
        "Change Image...": "更换图片...",
        "Change Poster...": "更换海报...",
        "Change Skin": "更换卡面",
        "Change...": "更换...",
        "Checking connected devices...": "正在检测连接的设备...",
        "Checking iPhone…": "正在检测 iPhone…",
        "Choose .passthm File...": "选择 .passthm 文件...",
        "Choose File...": "选择文件...",
        "Choose Image...": "选择图片...",
        "Choose Poster Image": "选择海报图片",
        "Choose a .passthm passcode theme package...": "选择 .passthm 锁屏密码主题包...",
        "Choose a skin to assign to all selected cards...": "选择要分配给所有选中卡片的卡面图片...",
        "Circle Buttons": "圆形按键",
        "Clear All": "清空全部",
        "Clear All Keys": "清空所有按键",
        "Clear Theme": "清除主题",
        "Cleared all cards.": "已清空所有卡片。",
        "Cleared all custom keys": "已清除所有自定义按键",
        "Click **Scan Cards** in the toolbar above.": "点击上方工具栏中的 **扫描卡片**。",
        "Click any key on the dialer to select it, pan the image, adjust zoom, or drop files.": "点击拨号盘上的任意按键进行选中，可平移图片、调整缩放或直接拖入文件。",
        "Click to browse or drag image": "点击浏览或拖拽图片到此处",
        "Click to select an active device": "点击以选择当前操作的设备",
        "Command Line Tools required.": "需要安装 Command Line Tools。",
        "Complete! All cards updated.": "完成！所有卡片已更新。",
        "Connecting to the iPhone log stream…": "正在连接到 iPhone 系统日志流…",
        "Continue to AirCard": "进入 AirCard",
        "Copy full hash": "复制完整卡片 ID",
        "Core Exploit:": "核心漏洞机制：",
        "Could not read Wallet metadata. Scanning still works. Use Read Cache to retry.": "无法读取钱包元数据。卡片扫描功能仍可正常使用。可点击“读取缓存”重试。",
        "Could not start card scanning.": "无法启动卡片扫描。",
        "Created Theme": "自制主题",
        "Credits & Donate": "关于与致谢",
        "Custom Theme Loaded": "已加载自定义主题",
        "CustomTheme.passthm": "自制密码主题.passthm",
        "DONATE & SUPPORT": "捐赠与支持",
        "Detected cards will appear here as the iPhone reports them.": "检测到的卡片将在 iPhone 响应后立即显示在此处。",
        "Developer tools or license agreement required. See log.": "需要开发者工具或同意许可协议。详见日志。",
        "Developer:": "开发者：",
        "Device check failed. Reconnect and unlock the iPhone, then retry.": "设备检测失败。请重新连接并解锁 iPhone 后重试。",
        "Device detection could not run. See the log.": "设备检测无法运行。详情请查看日志。",
        "Device tools are missing from this build.": "当前构建缺少设备通信组件。",
        "Device tools are missing. Rebuild or reinstall AirCard, then reconnect.": "缺少设备通信组件。请重新构建或安装 AirCard，然后重新连接。",
        "Don't show this popup on startup": "启动时不再显示此弹窗",
        "Donate with PayPal": "通过 PayPal 捐赠",
        "Double-click Side button (Apple Pay), pass Face ID, then tap your card.": "请双击侧边键 (Apple Pay)，通过 Face ID 验证，然后轻触卡片。",
        "Double-click Side button, pass Face ID, then tap your card...": "请双击侧边键，通过 Face ID，然后轻触卡片...",
        "Drag anywhere on the dialer preview to reposition": "在拨号盘预览区域任意拖拽以调整位置",
        "Drag dialer to pan · Use slider to zoom": "拖拽拨号盘可平移 · 使用滑块缩放",
        "Drop .passthm file here": "将 .passthm 文件拖放至此处",
        "Drop image here": "将图片拖放至此处",
        "Drop poster or wallpaper here": "将海报或壁纸拖放至此处",
        "Edit in Creator": "在制作器中编辑",
        "Emergency": "紧急呼叫",
        "Enter Passcode": "输入密码",
        "Export .passthm...": "导出 .passthm...",
        "Failed to apply card skins.": "应用卡片卡面失败。",
        "Failed to inspect .passthm file": "解析 .passthm 文件失败",
        "Failed to package theme for flashing.": "打包待写入的主题失败。",
        "Fill from Poster": "从海报切片填充",
        "Flash & Language Target": "写入目标与语言设置",
        "Flash Passcode Theme": "写入锁屏密码主题",
        "Flash to iPhone": "写入至 iPhone",
        "Flashing Cards...": "正在写入卡面...",
        "Flashing Passcode...": "正在写入密码键盘...",
        "Font Weight / Style:": "字重 / 字体样式：",
        "Free & Open Source • Developed by @mak5er": "免费开源 • 由 @mak5er 开发",
        "Include in flash": "包含在写入任务中",
        "Interactive iPhone Lock Screen Preview": "iPhone 锁屏交互式实时预览",
        "Live Scanner Active": "实时扫描中",
        "Lock Screen Keypad Preview": "锁屏数字键盘预览",
        "Log": "日志",
        "Manually added · Ready to flash": "手动添加 · 可直接写入",
        "Matched to this iPhone in current scan": "在当前扫描中匹配到此 iPhone",
        "No .passthm loaded · Select a theme package to flash": "未加载 .passthm · 请选择要写入的主题包",
        "No Cards Detected Yet": "尚未检测到卡片",
        "No cards detected. Open Wallet and tap a card.": "未检测到卡片。请打开“钱包”并轻触卡片。",
        "No iPhone connected.": "未连接 iPhone。",
        "No iPhone connected. Connect, unlock and trust this Mac, then use Reconnect.": "未连接 iPhone。请连接、解锁并在 iPhone 上信任此 Mac，然后点击“重新连接”。",
        "No iPhone found. Please connect via USB.": "未找到 iPhone。请通过 USB 数据线连接。",
        "No matching name in the Mac cache. The card ID is preserved.": "Mac 缓存中未匹配到名称，卡片 ID 已保留。",
        "On your iPhone, **double-click the Side button** (Apple Pay), authenticate with **Face ID**, and **tap your card**.": "在 iPhone 上，**双击侧边电源键**（开启 Apple Pay），通过 **Face ID** 验证，并 **轻触你的卡片**。",
        "One or more cards could not be updated. Check the log and try again.": "一张或多张卡片无法更新。请查看日志并重试。",
        "Passcode Theme File": "锁屏密码主题文件",
        "Passcode Themes:": "密码主题格式：",
        "Passcode theme applied successfully!": "锁屏密码主题应用成功！",
        "Paste one or more card IDs. Saved IDs remain hidden until the connected iPhone exposes them in a scan.": "粘贴一个或多个卡片 ID。已保存的 ID 在连接的 iPhone 于扫描中上报前会保持隐藏。",
        "Payment card activated. Waiting for Wallet metadata to finish loading…": "支付卡已激活。正在等待钱包元数据加载完成…",
        "Please add at least one key icon or import a poster image first.": "请先添加至少一个按键图标或导入一张海报图片。",
        "Please assign a skin image to at least one selected card.": "请为至少一张已选中的卡片分配卡面图片。",
        "Please configure at least one key before exporting.": "导出前请至少配置一个按键。",
        "Please connect and trust your iPhone first.": "请先连接并在 iPhone 上信任此 Mac。",
        "Poster Artwork": "海报素材",
        "Poster image loaded · Ready to frame and slice": "海报图片已加载 · 可进行取景与切割",
        "Recipient: Maksym Reva": "收款人：Maksym Reva",
        "Refresh Device List": "刷新设备列表",
        "Remove from list": "从列表中移除",
        "Remove skin": "移除卡面",
        "Reset": "重置",
        "Reset Position": "重置位置",
        "Reset to iPhone's detected language and font style": "恢复为 iPhone 检测到的语言与字体样式",
        "Save Card IDs for Matching": "保存卡片 ID 用于匹配",
        "Save IDs": "保存 ID",
        "Save IDs for Matching": "手动添加卡片 ID",
        "Save Passcode Theme": "保存锁屏密码主题",
        "Saved on this iPhone": "已保存在此 iPhone",
        "Scanner could not start. Reconnect the iPhone and try again.": "扫描器无法启动。请重新连接 iPhone 后重试。",
        "Scanner is active. Open Wallet on your iPhone.": "扫描器已处于活动状态。请在 iPhone 上打开“钱包”。",
        "Scanning for Cards…": "正在扫描卡片…",
        "Seamless Poster": "无缝海报",
        "Seamless artwork spans across dialer keys without circular cuts (Adobe Dog style).": "整张海报跨拨号盘按键无缝拼接展现，无圆形裁剪切割。",
        "Select a wallpaper or photo to slice for the passcode keypad...": "选择要为密码键盘切割的壁纸或照片...",
        "Set Skin for All...": "为全部卡片设置卡面...",
        "Skin already on iPhone": "卡面已存在于 iPhone",
        "Skin application stopped after a card update failed.": "由于卡片更新失败，卡面应用流程已终止。",
        "Skin changed, will be flashed": "卡面已修改，将被写入",
        "Skin file unavailable. Choose the image again.": "卡面文件不可用，请重新选择图片。",
        "Skins successfully applied to all selected cards!": "已成功为所有选中的卡片应用卡面！",
        "Slicing Style": "切割样式",
        "Something went wrong": "发生错误",
        "Start Scanning": "开始扫描",
        "Started scanning device logs for cards...": "开始扫描设备日志以发现卡片...",
        "Starting passcode theme flash...": "正在启动锁屏密码主题写入...",
        "Stop Scanning": "停止扫描",
        "Support @mak5er (Donate ❤️)": "支持 @mak5er (前往赞助 ❤️)",
        "Supports .passthm, .passtheme, or .zip packages from Cowabunga or Nugget": "支持 Cowabunga 或 Nugget 导出的 .passthm、.passtheme 或 .zip 主题包",
        "System Language:": "系统语言：",
        "Target:": "目标版本：",
        "Thank you for supporting AirCard development! ❤️": "感谢你对 AirCard 开发的支持！❤️",
        "The log connection failed. Reconnect the iPhone and retry scanning.": "日志连接失败。请重新连接 iPhone 后重试扫描。",
        "Theme Creator reset": "主题制作器已重置",
        "Theme Creator · Import a poster or drop icons onto keys": "主题制作器 · 导入海报或拖放图标到按键上",
        "Unidentified card": "未识别卡片",
        "Universal (All 8, 9, 10)": "通用 (包含 8、9、10)",
        "Universal mode flashes ~600 files for all languages & Bold text. Selecting a specific language (e.g. Ukrainian) speeds up flashing dramatically.": "通用模式会为所有语言及粗体文本写入约 600 个文件。选择特定语言（如中文）可显著提升写入速度。",
        "Wallet Cards & Passcode Themes": "钱包卡面与锁屏密码主题",
        "Welcome to AirCard!": "欢迎使用 AirCard！",
        "Your card will be detected immediately!": "你的卡片将被立即识别并检测到！",
        "Zoom": "缩放",
        "Zoom & Framing": "取景与缩放",
    ]
}

// MARK: - Global Helper Extensions

@inline(__always)
public func l10n(_ key: String) -> String {
    return LocalizationManager.shared.tr(key)
}

@inline(__always)
public func l10n(_ formatKey: String, _ args: CVarArg...) -> String {
    return LocalizationManager.shared.trFormat(formatKey, args)
}

public extension String {
    var localized: String {
        return LocalizationManager.shared.tr(self)
    }
}
