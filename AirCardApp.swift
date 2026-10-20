import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit

// MARK: - Models

struct DeviceResponse: Codable {
    var connected: Bool
    var error: String?
    var devices: [DeviceInfo]?
    var selected_udid: String?
    var device: DeviceInfo?
}

struct DeviceInfo: Codable, Identifiable, Hashable {
    var id: String { udid ?? UUID().uuidString }
    var udid: String?
    var name: String?
    var version: String?
    var product: String?
    var language: String?
    var locale: String?
    var bold_text: Bool?
    var airlift_compatible: Bool?
    var connected: Bool
    var error: String?

    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        if let p = product, p.hasPrefix("iPhone") { return "iPhone" }
        return "Apple 设备"
    }

    var subtitle: String {
        var parts: [String] = []
        if let p = product, !p.isEmpty { parts.append(p) }
        if let v = version, !v.isEmpty { parts.append("iOS \(v)") }
        return parts.joined(separator: " · ")
    }

    var isPaired: Bool {
        product != nil && !(product?.isEmpty ?? true) && product != "Unknown"
    }

    var menuLabel: String {
        let title = displayName
        let sub = subtitle
        let shortUDID = udid.map { $0.count > 6 ? String($0.suffix(6)) : $0 } ?? ""
        if !isPaired {
            return shortUDID.isEmpty ? "\(title) (已锁定/未配对)" : "设备 [...\(shortUDID)] (已锁定/未配对)"
        }
        if sub.isEmpty {
            return shortUDID.isEmpty ? title : "\(title) [...\(shortUDID)]"
        }
        return shortUDID.isEmpty ? "\(title) (\(sub))" : "\(title) (\(sub)) [...\(shortUDID)]"
    }
}

struct CardItem: Identifiable, Hashable {
    let id: String
    var isSelected: Bool = true
    var customImageURL: URL? = nil {
        didSet { skinSignature = customImageURL.flatMap(CardItem.signature(of:)) }
    }
    var customImage: NSImage? = nil
    /// SHA-256 of the assigned skin file; used to skip cards whose skin is already on the device.
    private(set) var skinSignature: String? = nil
    var displayName: String? = nil
    var confirmed: Bool = false
    
    static func signature(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: CardItem, rhs: CardItem) -> Bool {
        lhs.id == rhs.id && lhs.isSelected == rhs.isSelected && lhs.customImageURL == rhs.customImageURL && lhs.displayName == rhs.displayName && lhs.confirmed == rhs.confirmed
    }
}

// A lazy row can outlive its entry in the array. Resolve each access by ID;
// retain the row snapshot for teardown reads and ignore writes after deletion.
func walletCardBinding(in cards: Binding<[CardItem]>, snapshot: CardItem) -> Binding<CardItem> {
    Binding(
        get: { cards.wrappedValue.first(where: { $0.id == snapshot.id }) ?? snapshot },
        set: { updated in
            guard let index = cards.wrappedValue.firstIndex(where: { $0.id == snapshot.id }) else { return }
            cards.wrappedValue[index] = updated
        }
    )
}

enum AppTab: String, CaseIterable, Identifiable {
    case walletCards = "Apple 钱包"
    case passcodeThemes = "锁屏密码主题 (.passthm)"
    var id: String { rawValue }
}

struct PasscodeThemeInfo: Identifiable {
    var id: String { filePath }
    let name: String
    let filePath: String
    let detectedVersion: String
    let fileCount: Int
    let keysPreview: [String: NSImage]
}

enum PasscodeTabMode: String, CaseIterable, Identifiable {
    case applyTheme = "应用 .passthm"
    case themeCreator = "主题制作器"
    var id: String { rawValue }
}

enum CreatorSubMode: String, CaseIterable, Identifiable {
    case posterSlice = "海报切割 (拼图)"
    case individualKeys = "独立按键"
    var id: String { rawValue }
}

enum PasscodeLanguageTarget: String, CaseIterable, Identifiable {
    case all = "全部语言 (通用)"
    case uk = "乌克兰语 (uk)"
    case ru = "俄语 (ru)"
    case en = "英语 (en)"
    case other = "其他 / 兜底"
    case es = "西班牙语 (es)"
    case de = "德语 (de)"
    case fr = "法语 (fr)"
    case pl = "波兰语 (pl)"
    case it = "意大利语 (it)"
    case pt = "葡萄牙语 (pt)"
    case tr = "土耳其语 (tr)"
    case ja = "日语 (ja)"
    case ko = "韩语 (ko)"
    case zh = "中文 (zh)"
    case ar = "阿拉伯语 (ar)"
    case he = "希伯来语 (he)"
    
    var id: String { rawValue }
    
    var code: String {
        switch self {
        case .all: return "all"
        case .uk: return "uk"
        case .ru: return "ru"
        case .en: return "en"
        case .other: return "other"
        case .es: return "es"
        case .de: return "de"
        case .fr: return "fr"
        case .pl: return "pl"
        case .it: return "it"
        case .pt: return "pt"
        case .tr: return "tr"
        case .ja: return "ja"
        case .ko: return "ko"
        case .zh: return "zh"
        case .ar: return "ar"
        case .he: return "he"
        }
    }
}

enum PasscodeBoldTarget: String, CaseIterable, Identifiable {
    case both = "通用 (常规 + 粗体)"
    case boldOnly = "仅粗体文本 (快速)"
    case regularOnly = "仅常规字体 (快速)"
    
    var id: String { rawValue }
    
    var code: String {
        switch self {
        case .both: return "both"
        case .boldOnly: return "bold"
        case .regularOnly: return "regular"
        }
    }
}

struct KeypadButtonGeometry: Identifiable {
    var id: String { digit }
    let digit: String
    let letters: String
    let row: Int
    let col: Int
}

struct KeypadLayout {
    static let buttonDiameter: CGFloat = 75.0
    static let gridWidth: CGFloat = 305.0 // 915.0 / 3
    static let gridHeight: CGFloat = 1148.0 / 3.0 // 382.6666666666667
    static let colWidth: CGFloat = 305.0 / 3.0 // 101.66666666666667
    static let rowHeight: CGFloat = 1148.0 / 12.0 // 287.0 / 3 = 95.66666666666667
    static let horizontalSpacing: CGFloat = 24.0
    static let verticalSpacing: CGFloat = 18.0
    
    static let allButtons: [KeypadButtonGeometry] = [
        KeypadButtonGeometry(digit: "1", letters: "", row: 0, col: 0),
        KeypadButtonGeometry(digit: "2", letters: "A B C", row: 0, col: 1),
        KeypadButtonGeometry(digit: "3", letters: "D E F", row: 0, col: 2),
        KeypadButtonGeometry(digit: "4", letters: "G H I", row: 1, col: 0),
        KeypadButtonGeometry(digit: "5", letters: "J K L", row: 1, col: 1),
        KeypadButtonGeometry(digit: "6", letters: "M N O", row: 1, col: 2),
        KeypadButtonGeometry(digit: "7", letters: "P Q R S", row: 2, col: 0),
        KeypadButtonGeometry(digit: "8", letters: "T U V", row: 2, col: 1),
        KeypadButtonGeometry(digit: "9", letters: "W X Y Z", row: 2, col: 2),
        KeypadButtonGeometry(digit: "0", letters: "+", row: 3, col: 1)
    ]
    
    static let keypadSubtexts: [String: String] = [
        "0": "+",
        "1": "",
        "2": "A B C",
        "3": "D E F",
        "4": "G H I",
        "5": "J K L",
        "6": "M N O",
        "7": "P Q R S",
        "8": "T U V",
        "9": "W X Y Z"
    ]
    
    static func cellFrame(for button: KeypadButtonGeometry) -> CGRect {
        let x = CGFloat(button.col) * colWidth
        let y = CGFloat(button.row) * rowHeight
        return CGRect(x: x, y: y, width: colWidth, height: rowHeight)
    }
}

// MARK: - Keypad Slicing Engine

class KeypadSlicer {
    static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cg
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(image.size.width)),
            pixelsHigh: max(1, Int(image.size.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        
        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
    
    static func slicePoster(
        image: NSImage,
        zoom: Double = 1.0,
        offset: CGPoint = .zero,
        maskToCircles: Bool = false
    ) -> [String: NSImage] {
        guard let cgImg = cgImage(from: image) else { return [:] }
        let imgW = CGFloat(cgImg.width)
        let imgH = CGFloat(cgImg.height)
        guard imgW > 0 && imgH > 0 else { return [:] }
        
        // Standard iOS TelephonyUI @3x grid dimensions
        let gridW: CGFloat = 915.0
        let gridH: CGFloat = 1148.0
        let colW: CGFloat = 305.0
        let rowH: CGFloat = 287.0
        
        let imgAspect = imgW / imgH
        let gridAspect = gridW / gridH
        
        let scaledW: CGFloat
        let scaledH: CGFloat
        if imgAspect > gridAspect {
            // Image is wider than grid -> fit height
            scaledH = gridH * CGFloat(max(0.1, zoom))
            scaledW = scaledH * imgAspect
        } else {
            // Image is taller than grid -> fit width
            scaledW = gridW * CGFloat(max(0.1, zoom))
            scaledH = scaledW / imgAspect
        }
        
        // Match user's pan offset in SwiftUI points (scaled to 3x)
        let imageX = (gridW - scaledW) / 2.0 + offset.x * 3.0
        let imageY = (gridH - scaledH) / 2.0 + offset.y * 3.0
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var results: [String: NSImage] = [:]
        
        for button in KeypadLayout.allButtons {
            let isZeroSeamless = (!maskToCircles && button.digit == "0")
            let tileW: CGFloat = isZeroSeamless ? gridW : colW
            let tileH: CGFloat = rowH
            
            let cellX: CGFloat = isZeroSeamless ? 0.0 : CGFloat(button.col) * colW
            let cellY: CGFloat = CGFloat(button.row) * rowH
            
            let relX = imageX - cellX
            let relY = imageY - cellY
            let destCGY = tileH - relY - scaledH
            
            guard let ctx = CGContext(
                data: nil,
                width: Int(tileW),
                height: Int(tileH),
                bitsPerComponent: 8,
                bytesPerRow: Int(tileW) * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            
            ctx.clear(CGRect(x: 0, y: 0, width: tileW, height: tileH))
            
            if maskToCircles {
                let circleDiameter: CGFloat = 225.0
                let circleX = (tileW - circleDiameter) / 2.0
                let circleY = (tileH - circleDiameter) / 2.0
                ctx.addEllipse(in: CGRect(x: circleX, y: circleY, width: circleDiameter, height: circleDiameter))
                ctx.clip()
            }
            
            ctx.draw(cgImg, in: CGRect(x: relX, y: destCGY, width: scaledW, height: scaledH))
            
            if let outCG = ctx.makeImage() {
                results[button.digit] = NSImage(cgImage: outCG, size: NSSize(width: tileW, height: tileH))
            }
        }
        return results
    }
    
    static func cropToCircle(
        image: NSImage,
        targetSize: CGSize = CGSize(width: 225, height: 225),
        circleDiameter: CGFloat = 222.0,
        zoom: Double = 1.0,
        offset: CGPoint = .zero
    ) -> NSImage? {
        guard let cgImg = cgImage(from: image) else { return nil }
        let imgW = CGFloat(cgImg.width)
        let imgH = CGFloat(cgImg.height)
        guard imgW > 0 && imgH > 0 else { return nil }
        
        // Scale image to fill the circle area with zoom
        let baseScale = max(circleDiameter / imgW, circleDiameter / imgH) * CGFloat(max(0.1, zoom))
        let scaledW = imgW * baseScale
        let scaledH = imgH * baseScale
        
        let circleX = (targetSize.width - circleDiameter) / 2.0
        let circleY = (targetSize.height - circleDiameter) / 2.0
        
        // User pan offset in SwiftUI points (multiplied by 3 for @3x canvas)
        let destX = circleX + (circleDiameter - scaledW) / 2.0 + offset.x * 3.0
        let destY = circleY + (circleDiameter - scaledH) / 2.0 + offset.y * 3.0
        let destCGY = targetSize.height - destY - scaledH
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(targetSize.width) * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        ctx.clear(CGRect(origin: .zero, size: targetSize))
        ctx.addEllipse(in: CGRect(x: circleX, y: circleY, width: circleDiameter, height: circleDiameter))
        ctx.clip()
        ctx.draw(cgImg, in: CGRect(x: destX, y: destCGY, width: scaledW, height: scaledH))
        
        guard let outCG = ctx.makeImage() else { return nil }
        return NSImage(cgImage: outCG, size: targetSize)
    }
}

// MARK: - Passcode Theme Exporter

class PasscodeThemeExporter {
    static func pngData(from image: NSImage) -> Data? {
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(image.size.width)),
            pixelsHigh: max(1, Int(image.size.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        
        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
    
    static let supportedLocales = [
        "en", "other", "ru", "uk", "es", "fr", "de", "it", "pt", "tr", "pl", "nl", "ja", "ko", "zh", "ar", "he"
    ]
    
    static func exportTheme(
        keys: [String: NSImage],
        targetURL: URL,
        language: PasscodeLanguageTarget = .all,
        boldMode: PasscodeBoldTarget = .both
    ) throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("passthm_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        let localesToExport: [String]
        if language == .all {
            localesToExport = supportedLocales
        } else {
            var setL = [language.code]
            if language.code != "other" { setL.append("other") }
            localesToExport = setL
        }
        
        let boldSuffixes: [String]
        switch boldMode {
        case .both: boldSuffixes = ["", "-bold"]
        case .boldOnly: boldSuffixes = ["-bold"]
        case .regularOnly: boldSuffixes = [""]
        }
        
        for ver in ["TelephonyUI-10", "TelephonyUI-9"] {
            let verDir = tempDir.appendingPathComponent(ver)
            try FileManager.default.createDirectory(at: verDir, withIntermediateDirectories: true)
            
            let markerFile = verDir.appendingPathComponent("_big")
            FileManager.default.createFile(atPath: markerFile.path, contents: Data())
            
            for (digit, image) in keys {
                guard let pngData = pngData(from: image) else { continue }
                let subtext = KeypadLayout.keypadSubtexts[digit] ?? ""
                
                for lang in localesToExport {
                    for boldSuffix in boldSuffixes {
                        // Blank variant: lang-digit---white[-bold].png
                        let blankFn = "\(lang)-\(digit)---white\(boldSuffix).png"
                        let blankURL = verDir.appendingPathComponent(blankFn)
                        try? pngData.write(to: blankURL)
                        
                        // Subtext variant: lang-digit-subtext--white[-bold].png
                        if !subtext.isEmpty {
                            let subFn = "\(lang)-\(digit)-\(subtext)--white\(boldSuffix).png"
                            let subURL = verDir.appendingPathComponent(subFn)
                            try? pngData.write(to: subURL)
                        }
                    }
                }
            }
        }
        
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-r", "-q", targetURL.path, "TelephonyUI-10", "TelephonyUI-9"]
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "PasscodeThemeExporter",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "创建 .passthm 压缩包失败 (退出码 \(process.terminationStatus))"]
            )
        }
    }
    
    static func stageTemporaryTheme(
        keys: [String: NSImage],
        language: PasscodeLanguageTarget = .all,
        boldMode: PasscodeBoldTarget = .both
    ) -> URL? {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("AirCard_Custom_\(UUID().uuidString).passthm")
        do {
            try exportTheme(keys: keys, targetURL: tempURL, language: language, boldMode: boldMode)
            return tempURL
        } catch {
            print("暂存临时主题失败: \(error)")
            return nil
        }
    }
}

// MARK: - View Model

@MainActor
class AppViewModel: ObservableObject {
    @Published var selectedTab: AppTab = .walletCards
    @Published var loadedPasscodeTheme: PasscodeThemeInfo? = nil
    @Published var isInspectingTheme = false
    @Published var targetTelephonyVersion: String = "TelephonyUI-10"
    @Published var passcodeLanguageTarget: PasscodeLanguageTarget = .all
    @Published var passcodeBoldTarget: PasscodeBoldTarget = .both
    
    // Theme Creator Properties
    @Published var passcodeTabMode: PasscodeTabMode = .applyTheme
    @Published var creatorSubMode: CreatorSubMode = .posterSlice
    @Published var creatorPosterImage: NSImage? = nil
    @Published var creatorPosterZoom: Double = 1.0
    @Published var creatorPosterOffset: CGPoint = .zero
    @Published var creatorMaskToCircles: Bool = false
    @Published var creatorCustomKeys: [String: NSImage] = [:]
    @Published var creatorSlicedKeys: [String: NSImage] = [:]
    @Published var creatorRawIndividualImages: [String: NSImage] = [:]
    @Published var creatorIndividualOffsets: [String: CGPoint] = [:]
    @Published var creatorIndividualZooms: [String: Double] = [:]
    @Published var selectedKeyDigit: String? = nil
    
    @Published var devices: [DeviceInfo] = []
    @Published var selectedDeviceUDID: String? = nil
    @Published var device: DeviceInfo?
    @Published var isCheckingDevice = false
    @Published var isScanningCards = false
    @Published var cards: [CardItem] = [] {
        didSet { if !isLoadingCards { saveCards() } }
    }
    @Published var walletCatalog = WalletCatalog.empty
    @Published var isReadingWalletCache = false
    @Published var scannerMessage = "打开“钱包”并轻点卡片以验证此 iPhone 上保存的卡片。"
    @Published var currentScanIDs: Set<String> = []
    private var currentPreloadedIDs: Set<String> = []
    private var activeCardDeviceID: String?
    private var isLoadingCards = false
    private var catalogRequestID = UUID()
    private var catalogRefreshTask: Task<Void, Never>?
    private var pendingActivationIDs: Set<String> = []

    var confirmedCardIDs: Set<String> { Set(cards.filter(\.confirmed).map(\.id)) }
    var currentVerifiedCardIDs: Set<String> { currentScanIDs.union(currentPreloadedIDs) }
    var currentVerifiedCards: [CardItem] { cards.filter { currentVerifiedCardIDs.contains($0.id) } }
    var pendingPaymentCards: [WalletCachedCard] { walletCatalog.pending(confirmedIDs: confirmedCardIDs, source: "payment") }
    var pendingMembershipCards: [WalletCachedCard] { walletCatalog.pending(confirmedIDs: confirmedCardIDs, source: "membership") }

    
    @Published var isFlashing = false
    @Published var progress: Double = 0.0
    @Published var statusText: String = "就绪"
    @Published var logs: [String] = []
    @Published var showSuccessAlert = false
    @Published var errorMessage: String?
    
    @Published var showAddCardSheet = false
    @Published var manualHashInput = ""
    @Published var showLogs = false
    
    private var scanProcess: Process?
    private let scriptDir: String
    private let cardDefaults: UserDefaults
    private let storageKey = "mak5er.aircard.savedCards"
    private let flashedSkinsKey = "mak5er.aircard.flashedSkins"
    /// "udid|cardHash" -> skin signature last flashed successfully.
    @Published var flashedSkins: [String: String] = [:]
    private let legacyStorageKey1 = "mak5er.savedCards"
    private let legacyStorageKey2 = "LumiCards.savedCards"
    
    init(cardDefaults: UserDefaults = .standard, connectOnLaunch: Bool = true) {
        self.cardDefaults = cardDefaults
        let cwd = FileManager.default.currentDirectoryPath
        if let resPath = Bundle.main.resourcePath, FileManager.default.fileExists(atPath: resPath + "/aircard_backend.py") {
            self.scriptDir = resPath
        } else if FileManager.default.fileExists(atPath: cwd + "/aircard_backend.py") {
            self.scriptDir = cwd
        } else {
            self.scriptDir = Bundle.main.bundleURL.deletingLastPathComponent().path
        }
        
        flashedSkins = UserDefaults.standard.dictionary(forKey: flashedSkinsKey) as? [String: String] ?? [:]
        loadSavedCards()
        if connectOnLaunch { checkDevice() }
    }
    
    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        logs.append("[\(timestamp)] \(message)")
    }
    
    nonisolated private static var pythonExecutableURL: URL {
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }
    
    nonisolated private static var deviceHelperExecutableURL: URL? {
        var candidates: [String] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("bin/device_helper").path)
        }
        candidates.append("/Applications/AirCard.app/Contents/Resources/bin/device_helper")
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
    
    nonisolated private static var processEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        var extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        if let res = Bundle.main.resourceURL {
            extraPaths.insert(res.appendingPathComponent("bin").path, at: 0)
        }
        extraPaths.insert("/Applications/AirCard.app/Contents/Resources/bin", at: 0)
        env["PATH"] = (extraPaths + [path]).joined(separator: ":")
        
        var libPaths = ["/Applications/AirCard.app/Contents/Resources/lib"]
        if let res = Bundle.main.resourceURL {
            libPaths.insert(res.appendingPathComponent("lib").path, at: 0)
        }
        let curDyld = env["DYLD_LIBRARY_PATH"] ?? ""
        env["DYLD_LIBRARY_PATH"] = (libPaths + (curDyld.isEmpty ? [] : [curDyld])).joined(separator: ":")

        // The backend scripts live inside the signed bundle. Left to itself
        // Python drops __pycache__ next to them on first run, which breaks the
        // app's own signature.
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        return env
    }
    
    nonisolated static func prepareCardImage(srcURL: URL, dstURL: URL) -> Bool {
        guard let image = NSImage(contentsOf: srcURL) else { return false }
        let targetSize = CGSize(width: 1536, height: 969)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return false }
        
        rep.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        
        let imgSize = image.size
        let scale = max(targetSize.width / imgSize.width, targetSize.height / imgSize.height)
        let scaledWidth = imgSize.width * scale
        let scaledHeight = imgSize.height * scale
        let x = (targetSize.width - scaledWidth) / 2.0
        let y = (targetSize.height - scaledHeight) / 2.0
        
        image.draw(in: CGRect(x: x, y: y, width: scaledWidth, height: scaledHeight),
                   from: CGRect(origin: .zero, size: imgSize),
                   operation: .copy,
                   fraction: 1.0)
        
        NSGraphicsContext.restoreGraphicsState()
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try pngData.write(to: dstURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
    
    // MARK: - Persistence
    
    private var walletStorageKey: String {
        "mak5er.aircard.wallet.v2." + (activeCardDeviceID ?? "unassigned")
    }

    func loadSavedCards() {
        isLoadingCards = true
        defer { isLoadingCards = false }
        var records: [WalletSavedCard]
        if let data = cardDefaults.data(forKey: walletStorageKey),
           let saved = try? JSONDecoder().decode([WalletSavedCard].self, from: data) {
            records = saved
        } else {
            // Old stores have no device provenance. Import once as unconfirmed,
            // including an explicitly empty store so deleted cards stay deleted.
            var loaded = cardDefaults.stringArray(forKey: storageKey)
                ?? cardDefaults.stringArray(forKey: legacyStorageKey1)
                ?? cardDefaults.stringArray(forKey: legacyStorageKey2)
            if loaded == nil {
                for path in ["~/.aircard_cards.json", "~/.lumicards_cards.json"] {
                    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
                    if let data = try? Data(contentsOf: url),
                       let ids = try? JSONDecoder().decode([String].self, from: data) {
                        loaded = ids
                        break
                    }
                }
            }
            records = (loaded ?? []).filter { !WalletScanParser.placeholders.contains($0) }.map { WalletSavedCard(id: $0) }
        }
        cards = WalletSavedCard.unique(records).map { record in
            let url = record.imagePath.map { URL(fileURLWithPath: $0) }
            return CardItem(id: record.id, isSelected: record.selected, customImageURL: url,
                            customImage: url.flatMap { NSImage(contentsOf: $0) }, confirmed: record.confirmed)
        }
        log("已加载 \(cards.count) 张已保存卡片；其中 \(confirmedCardIDs.count) 张此前已在此 iPhone 上验证。")
    }

    func saveCards() {
        let records = WalletSavedCard.unique(cards.map {
            WalletSavedCard(id: $0.id, confirmed: $0.confirmed, imagePath: $0.customImageURL?.path, selected: $0.isSelected)
        })
        if let data = try? JSONEncoder().encode(records) {
            cardDefaults.set(data, forKey: walletStorageKey)
        }
    }

    func activateCardDevice(_ udid: String?) {
        guard activeCardDeviceID != udid else { return }
        stopCardScanning()
        saveCards()
        activeCardDeviceID = udid
        catalogRequestID = UUID()
        walletCatalog = .empty
        currentScanIDs = []
        currentPreloadedIDs = []
        pendingActivationIDs = []
        loadSavedCards()
        saveCards()
    }

    func refreshWalletCatalog() {
        guard let device, device.connected, let udid = device.udid else {
            walletCatalog = .empty
            isReadingWalletCache = false
            return
        }
        let requestID = UUID()
        catalogRequestID = requestID
        isReadingWalletCache = true
        let request: [String: Any] = ["product": device.product ?? "", "confirmedIDs": Array(confirmedCardIDs)]
        guard let requestData = try? JSONSerialization.data(withJSONObject: request) else { return }
        let scriptDir = self.scriptDir
        Task.detached {
            var catalog: WalletCatalog
            do {
                let process = Process()
                process.executableURL = AppViewModel.pythonExecutableURL
                process.environment = AppViewModel.processEnvironment
                process.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
                process.arguments = ["wallet_catalog.py"]
                let input = Pipe()
                let output = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try process.run()
                input.fileHandleForWriting.write(requestData)
                try? input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
                catalog = try JSONDecoder().decode(WalletCatalog.self, from: data)
            } catch {
                catalog = .empty
                catalog.warnings = ["无法读取钱包元数据。卡片扫描功能仍可正常使用。可点击“读取缓存”重试。"]
            }
            let result = catalog
            await MainActor.run {
                guard self.catalogRequestID == requestID, self.activeCardDeviceID == udid else { return }
                self.walletCatalog = result
                self.isReadingWalletCache = false
                for index in self.cards.indices {
                    let name = result.name(for: self.cards[index].id)
                    if self.cards[index].displayName != name { self.cards[index].displayName = name }
                }
                if self.isScanningCards {
                    self.reconcilePendingPaymentActivations()
                    self.reconcileMatchedPaymentCards()
                }
            }
        }
    }

    func recordScannedCard(_ id: String) {
        let newlySeen = currentScanIDs.insert(id).inserted
        if let index = cards.firstIndex(where: { $0.id == id }) {
            if !cards[index].confirmed { cards[index].confirmed = true }
        } else {
            cards.append(CardItem(id: id, displayName: walletCatalog.name(for: id), confirmed: true))
            NSSound(named: "Glass")?.play()
        }
        scannerMessage = "本次扫描已检测到 \(currentScanIDs.count) 张卡片。打开“钱包”中未检测到的卡片可进行核验。"
        if newlySeen && (walletCatalog.paymentStatus != "matched" || walletCatalog.name(for: id) == nil) {
            catalogRefreshTask?.cancel()
            catalogRefreshTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                self.refreshWalletCatalog()
            }
        }
        if isScanningCards {
            reconcileMatchedPaymentCards()
        }
    }

    func recordPreloadedCard(_ id: String) {
        guard currentPreloadedIDs.insert(id).inserted else { return }
        if let index = cards.firstIndex(where: { $0.id == id }) {
            if !cards[index].confirmed { cards[index].confirmed = true }
        } else {
            cards.append(CardItem(id: id, displayName: walletCatalog.name(for: id), confirmed: true))
            NSSound(named: "Glass")?.play()
        }
        scannerMessage = "已从此 iPhone 当前的“钱包”活动中验证 \(currentVerifiedCardIDs.count) 张卡片。"
    }

    @discardableResult
    func recordActivatedPaymentCard(_ activationID: String, refreshIfNeeded: Bool = true) -> Bool {
        let normalizedID = activationID.uppercased()
        guard let card = walletCatalog.payment(forActivationID: normalizedID) else {
            pendingActivationIDs.insert(normalizedID)
            scannerMessage = isReadingWalletCache
                ? "支付卡已激活。正在等待钱包元数据加载完成…"
                : "检测到支付卡已激活，但其 ID 不在此 Mac 的钱包缓存中。请点击“读取缓存”后重试。"
            if refreshIfNeeded && device?.connected == true && !isReadingWalletCache {
                refreshWalletCatalog()
            }
            return false
        }
        pendingActivationIDs.remove(normalizedID)
        recordScannedCard(card.id)
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index].displayName = card.name
        }
        scannerMessage = "检测到激活的卡片：\(card.name)。请在就绪后打开下一张卡片。"
        return true
    }

    func reconcilePendingPaymentActivations() {
        for activationID in Array(pendingActivationIDs) {
            _ = recordActivatedPaymentCard(activationID, refreshIfNeeded: false)
        }
    }

    func reconcileMatchedPaymentCards() {
        guard isScanningCards, walletCatalog.paymentStatus == "matched" else { return }
        let cachedIDs = Set(walletCatalog.payments.map(\.id))
        guard !currentVerifiedCardIDs.isDisjoint(with: cachedIDs) else { return }
        let missing = walletCatalog.payments.filter { !currentVerifiedCardIDs.contains($0.id) }
        for card in missing {
            recordPreloadedCard(card.id)
        }
        if !missing.isEmpty {
            scannerMessage = "已为此 iPhone 匹配 \(walletCatalog.payments.count) 张支付卡。如有未显示的会员卡，请在“钱包”中单独打开。"
            log("已从设备匹配的钱包缓存中添加 \(missing.count) 张支付卡。")
        }
    }

    func addCardHash(_ raw: String) {
        let components = raw.components(separatedBy: CharacterSet(charactersIn: " \n\r\t,;"))
        var addedCount = 0
        for comp in components {
            let clean = comp.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if clean.count >= 16 && clean.count <= 64 && !cards.contains(where: { $0.id == clean }) {
                cards.append(CardItem(id: clean, isSelected: true, displayName: walletCatalog.name(for: clean), confirmed: true))
                currentPreloadedIDs.insert(clean)
                addedCount += 1
                log("已添加卡片：\(clean)")
            }
        }
        if addedCount > 0 {
            saveCards()
            scannerMessage = "已添加 \(addedCount) 个卡片 ID，可设置卡面并写入。"
        }
    }
    
    func deleteCard(id: String) {
        cards.removeAll { $0.id == id }
        saveCards()
        log("已移除卡片：\(id)")
    }
    
    func clearAllCards() {
        cards.removeAll()
        saveCards()
        log("已清空所有卡片。")
    }
    
    func setCardImage(for cardId: String, url: URL) {
        if let idx = cards.firstIndex(where: { $0.id == cardId }) {
            cards[idx].customImageURL = url
            cards[idx].customImage = NSImage(contentsOf: url)
            cards[idx].isSelected = true
            log("已为卡片分配自定义卡面：\(cardId.prefix(12))...")
        }
    }
    
    func clearCardImage(for cardId: String) {
        if let idx = cards.firstIndex(where: { $0.id == cardId }) {
            cards[idx].customImageURL = nil
            cards[idx].customImage = nil
            log("已清除自定义卡面：\(cardId.prefix(12))...")
        }
    }
    
    private func flashedKey(udid: String, cardId: String) -> String { "\(udid)|\(cardId)" }
    
    /// True when the card's current skin is already on the connected device.
    func isSkinFlashed(_ card: CardItem) -> Bool {
        guard let udid = device?.udid, let sig = card.skinSignature else { return false }
        return flashedSkins[flashedKey(udid: udid, cardId: card.id)] == sig
    }
    
    /// Selected cards with a skin that differs from what was last flashed.
    var cardsNeedingFlash: [CardItem] {
        cards.filter { $0.isSelected && $0.customImageURL != nil && !isSkinFlashed($0) }
    }
    
    private func markSkinFlashed(udid: String, card: CardItem) {
        guard let sig = card.skinSignature else { return }
        flashedSkins[flashedKey(udid: udid, cardId: card.id)] = sig
        UserDefaults.standard.set(flashedSkins, forKey: flashedSkinsKey)
    }
    
    // MARK: - Device Connection

    func selectDevice(_ dev: DeviceInfo) {
        guard dev.udid != self.device?.udid else { return }

        if isScanningCards {
            scanProcess?.terminate()
            scanProcess = nil
            isScanningCards = false
        }

        self.device = dev
        self.selectedDeviceUDID = dev.udid
        self.activateCardDevice(dev.connected ? dev.udid : nil)
        self.refreshWalletCatalog()
        if let u = dev.udid {
            UserDefaults.standard.set(u, forKey: "mak5er.aircard.selectedUDID")
        }

        self.statusText = "已选择 \(dev.displayName)"
        self.log("已切换当前设备至：\(dev.displayName) (\(dev.product ?? ""), iOS \(dev.version ?? ""))")
        self.applyDevicePreferences(from: dev)

        if let udid = dev.udid {
            checkDevice(preferredUDID: udid)
        }
    }

    func checkDevice(preferredUDID: String? = nil) {
        guard !isCheckingDevice, !isFlashing else { return }
        isCheckingDevice = true
        statusText = "正在检测连接的设备..."
        let scriptDir = self.scriptDir
        let targetUDID = preferredUDID ?? selectedDeviceUDID ?? UserDefaults.standard.string(forKey: "mak5er.aircard.selectedUDID")

        Task.detached {
            let process = Process()
            process.executableURL = AppViewModel.pythonExecutableURL
            process.environment = AppViewModel.processEnvironment
            process.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
            if let targetUDID = targetUDID, !targetUDID.isEmpty {
                process.arguments = ["aircard_backend.py", "--devices", targetUDID]
            } else {
                process.arguments = ["aircard_backend.py", "--devices"]
            }

            let pipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errPipe

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if let resp = try? JSONDecoder().decode(DeviceResponse.self, from: data) {
                    await MainActor.run {
                        self.isCheckingDevice = false
                        let allDevs = resp.devices ?? []
                        self.devices = allDevs

                        if let activeDev = resp.device, activeDev.connected {
                            self.activateCardDevice(activeDev.udid)
                            self.device = activeDev
                            self.refreshWalletCatalog()
                            self.selectedDeviceUDID = activeDev.udid
                            if let u = activeDev.udid {
                                UserDefaults.standard.set(u, forKey: "mak5er.aircard.selectedUDID")
                            }
                            self.statusText = "已连接到 \(activeDev.name ?? "iPhone")"
                            self.log("设备已连接：\(activeDev.name ?? "iPhone") (\(activeDev.product ?? ""), iOS \(activeDev.version ?? "")) [总计: \(allDevs.count)]")
                            self.applyDevicePreferences(from: activeDev)
                        } else if let first = allDevs.first(where: { $0.isPaired }) ?? allDevs.first {
                            self.activateCardDevice(first.udid)
                            self.device = first
                            self.refreshWalletCatalog()
                            self.selectedDeviceUDID = first.udid
                            if let u = first.udid {
                                UserDefaults.standard.set(u, forKey: "mak5er.aircard.selectedUDID")
                            }
                            self.statusText = "已连接到 \(first.displayName)"
                            self.log("已选择设备：\(first.displayName) [总计: \(allDevs.count)]")
                            self.applyDevicePreferences(from: first)
                        } else {
                            self.activateCardDevice(nil)
                            self.device = nil
                            self.refreshWalletCatalog()
                            if resp.error == "device_helper_missing" {
                                self.scannerMessage = "缺少设备通信组件。请重新构建或安装 AirCard，然后重新连接。"
                                self.statusText = "当前构建缺少设备通信组件。"
                                self.log("未找到内置的 device_helper —— 无法执行设备检测。")
                            } else {
                                self.statusText = "未找到 iPhone。请通过 USB 数据线连接。"
                                self.scannerMessage = "未连接 iPhone。请连接、解锁并在 iPhone 上信任此 Mac，然后点击“重新连接”。"
                            }
                        }
                    }
                } else if let dev = try? JSONDecoder().decode(DeviceInfo.self, from: data) {
                    await MainActor.run {
                        self.activateCardDevice(dev.connected ? dev.udid : nil)
                        self.device = dev
                        self.refreshWalletCatalog()
                        self.isCheckingDevice = false
                        if dev.connected {
                            self.devices = [dev]
                            self.device = dev
                            self.selectedDeviceUDID = dev.udid
                            self.statusText = "已连接到 \(dev.name ?? "iPhone")"
                            self.log("设备已连接：\(dev.name ?? "iPhone") (\(dev.product ?? ""), iOS \(dev.version ?? ""))")
                            self.applyDevicePreferences(from: dev)
                        } else {
                            self.devices = []
                            self.device = nil
                            if dev.error == "device_helper_missing" {
                                self.scannerMessage = "缺少设备通信组件。请重新构建或安装 AirCard，然后重新连接。"
                                self.statusText = "当前构建缺少设备通信组件。"
                                self.log("未找到内置的 device_helper —— 无法执行设备检测。")
                            } else {
                                self.statusText = "未找到 iPhone。请通过 USB 数据线连接。"
                                self.scannerMessage = "未连接 iPhone。请连接、解锁并在 iPhone 上信任此 Mac，然后点击“重新连接”。"
                            }
                        }
                    }
                } else {
                    // Nothing parseable came back, which means the backend did not
                    // run, not that the cable is loose.
                    let raw = String(data: data, encoding: .utf8) ?? ""
                    let errRaw = (String(data: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let errLower = errRaw.lowercased()
                    let isLicenseOrCLT = errLower.contains("license") ||
                                         errLower.contains("xcode-select") ||
                                         errLower.contains("commandlinetools") ||
                                         errLower.contains("xcrun")

                    await MainActor.run {
                        self.devices = []
                        self.device = nil
                        self.activateCardDevice(nil)
                        self.refreshWalletCatalog()
                        self.isCheckingDevice = false
                        if isLicenseOrCLT {
                            self.statusText = "需要安装 Command Line Tools。"
                            self.errorMessage = "AirCard 需要 Xcode Command Line Tools 以与设备通信。\n\n请打开终端运行：\nxcode-select --install\n\n或打开 Xcode 同意许可协议，然后重启 AirCard。"
                            self.scannerMessage = "需要开发者工具或同意许可协议。详见日志。"
                        } else {
                            self.statusText = "设备检测无法运行。详情请查看日志。"
                            self.errorMessage = errRaw.isEmpty
                                ? "AirCard 无法运行设备组件。详情请查看活动控制台日志。"
                                : "设备组件错误：\(errRaw.prefix(300))"
                            self.scannerMessage = "设备检测失败。请重新连接并解锁 iPhone 后重试。"
                        }
                        if !errRaw.isEmpty {
                            self.log("后端标准错误输出：\(errRaw)")
                        }
                        self.log("设备检测未返回可用信息：\(raw.isEmpty ? "(无标准输出)" : raw.prefix(400).description)")
                    }
                }
            } catch {
                await MainActor.run {
                    self.devices = []
                    self.device = nil
                    self.activateCardDevice(nil)
                    self.refreshWalletCatalog()
                    self.isCheckingDevice = false
                    self.scannerMessage = "设备检测失败。请重新连接并解锁 iPhone 后重试。"
                    self.statusText = "设备检测失败：\(error.localizedDescription)"
                    self.log("进程执行失败：\(error.localizedDescription)")
                }
            }
        }
    }
    
    func applyDevicePreferences(from dev: DeviceInfo) {
        // 1. Auto-detect TelephonyUI version based on iOS major version
        if let verStr = dev.version, let major = Int(verStr.components(separatedBy: ".").first ?? "") {
            if major >= 18 {
                self.targetTelephonyVersion = "TelephonyUI-10"
            } else if major >= 16 {
                self.targetTelephonyVersion = "TelephonyUI-9"
            } else {
                self.targetTelephonyVersion = "TelephonyUI-8"
            }

            let parts = verStr.split(separator: ".").compactMap { Int($0) }
            if (parts.count > 0 && parts[0] > 27) || (parts.count >= 2 && parts[0] == 27 && parts[1] >= 3) {
                self.log("⚠️ 注意：检测到 iOS \(verStr)。若此设备运行 iOS 27.2 beta 3 或更新版本，Apple 已修复 AirTraffic 同步漏洞，写入操作可能会失败。")
            }
        }
        
        // 2. Auto-detect language
        if let langCode = dev.language?.components(separatedBy: "-").first?.lowercased() {
            for target in PasscodeLanguageTarget.allCases {
                if target.code == langCode {
                    self.passcodeLanguageTarget = target
                    break
                }
            }
        }
        
        // 3. Auto-detect bold text
        if let isBold = dev.bold_text {
            self.passcodeBoldTarget = isBold ? .boldOnly : .regularOnly
        }
        
        self.log("  ⚡ 已自动配置锁屏密码目标：\(self.targetTelephonyVersion)，语言：\(self.passcodeLanguageTarget.rawValue)，字体：\(self.passcodeBoldTarget.rawValue)")
    }
    
    // MARK: - Live Card Scanner
    
    func toggleCardScanning() {
        if isScanningCards {
            stopCardScanning()
        } else {
            startCardScanning()
        }
    }
    
    func startCardScanning() {
        guard !isScanningCards, !isFlashing, !isCheckingDevice else { return }
        guard let deviceHelper = AppViewModel.deviceHelperExecutableURL else {
            errorMessage = "当前构建缺少设备通信组件。"
            scannerMessage = "缺少设备通信组件。请重新构建或安装 AirCard，然后重新连接。"
            log("未找到内置的 device_helper —— 无法扫描。")
            return
        }
        guard let udid = device?.udid else {
            errorMessage = "未连接 iPhone。"
            scannerMessage = "未连接 iPhone。请连接、解锁并在 iPhone 上信任此 Mac，然后点击“重新连接”。"
            return
        }
        isScanningCards = true
        currentScanIDs = []
        currentPreloadedIDs = []
        pendingActivationIDs = []
        scannerMessage = "正在连接到 iPhone 系统日志流…"
        statusText = "请双击侧边键，通过 Face ID，然后轻触卡片..."
        log("开始扫描设备日志以发现卡片...")
        
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = deviceHelper
        proc.environment = AppViewModel.processEnvironment
        proc.arguments = ["syslog", udid]
        proc.standardOutput = pipe
        proc.standardError = pipe
        
        self.scanProcess = proc
        // Launch before yielding so Stop cannot race with a pending launch.
        do {
            try proc.run()
        } catch {
            scanProcess = nil
            isScanningCards = false
            statusText = "无法启动卡片扫描。"
            scannerMessage = "扫描器无法启动。请重新连接 iPhone 后重试。"
            log("系统日志监控启动失败：\(error.localizedDescription)")
            return
        }
        
        Task.detached {
            do {
                let handle = pipe.fileHandleForReading
                var buffer = Data()
                
                // Drain the pipe through EOF, including the last buffered record
                // when the helper exits. isRunning can become false too early.
                while true {
                    let chunk = try handle.read(upToCount: 65536) ?? Data()
                    if chunk.isEmpty {
                        if buffer.isEmpty { break }
                        buffer.append(0x0A)
                    } else {
                        buffer.append(chunk)
                    }
                    
                    while let newlineRange = buffer.range(of: Data([0x0A])) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                        buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)
                        
                        guard let line = String(data: lineData, encoding: .utf8) else { continue }
                        if line.hasPrefix("AirCard scanner: ") {
                            await MainActor.run {
                                guard self.scanProcess === proc else { return }
                                self.log(line)
                                if line.contains("Connected to the unified") || line.contains("已连接到统一设备日志流") {
                                    self.scannerMessage = "扫描器已连接。请打开“钱包”并轻触卡片；会员卡可能需要在“钱包”应用中打开。"
                                } else {
                                    self.scannerMessage = String(line.dropFirst("AirCard scanner: ".count))
                                }
                            }
                            continue
                        }
                        let lower = line.lowercased()
                        
                        let isWalletSubsystem = lower.contains("passd") ||
                                                lower.contains("passbook") ||
                                                lower.contains("passkit") ||
                                                lower.contains("nfcd") ||
                                                lower.contains("stockholm") ||
                                                lower.contains("nanopassd") ||
                                                lower.contains("wallet") ||
                                                lower.contains("pdcardfilemanager") ||
                                                lower.contains("pdpasslibrary") ||
                                                lower.contains("verificationcheck") ||
                                                lower.contains("/cards/")
                        
                        guard isWalletSubsystem else { continue }
                        
                        let isWalletContext = lower.contains("card") ||
                                              lower.contains("pass") ||
                                              lower.contains("payment") ||
                                              lower.contains("pkpass") ||
                                              lower.contains("uniqueid") ||
                                              lower.contains("identifier") ||
                                              lower.contains("face") ||
                                              lower.contains("cache") ||
                                              lower.contains("stockholm") ||
                                              lower.contains("pdcardfilemanager") ||
                                              lower.contains("pdpasslibrary") ||
                                              lower.contains("verificationcheck") ||
                                              lower.contains("/cards/")
                        
                        guard isWalletContext else { continue }

                        for activationID in WalletScanParser.activationIDs(in: line) {
                            await MainActor.run {
                                guard self.scanProcess === proc else { return }
                                self.recordActivatedPaymentCard(activationID)
                            }
                        }
                        
                        var candidates = WalletScanParser.cardIDs(in: line)
                        if candidates.isEmpty {
                            candidates = WalletScanParser.fallbackCardIDs(in: line)
                        }
                        for candidate in candidates {
                            await MainActor.run {
                                guard self.scanProcess === proc else { return }
                                self.recordPreloadedCard(candidate)
                                self.reconcileMatchedPaymentCards()
                            }
                        }
                    }
                    if chunk.isEmpty { break }
                }
                proc.waitUntilExit()
                await MainActor.run {
                    guard self.scanProcess === proc else { return }
                    self.scanProcess = nil
                    self.isScanningCards = false
                    self.statusText = "卡片扫描已结束。详情请查看日志，并重新连接 iPhone 重试。"
                    self.scannerMessage = "扫描器意外停止 (退出码 \(proc.terminationStatus))。请重新连接并解锁 iPhone 后再次扫描。详情请查看日志。"
                    self.log("系统日志监控已退出 (状态码 \(proc.terminationStatus))。卡片总数：\(self.cards.count)。")
                    self.saveCards()
                }
            } catch {
                if proc.isRunning { proc.terminate() }
                proc.waitUntilExit()
                await MainActor.run {
                    guard self.scanProcess === proc else { return }
                    self.scanProcess = nil
                    self.log("系统日志监控停止：\(error.localizedDescription)")
                    self.isScanningCards = false
                    self.statusText = "卡片扫描失败。详情请查看日志并重试。"
                    self.scannerMessage = "日志连接失败。请重新连接 iPhone 后重试扫描。"
                }
            }
        }
    }
    
    func stopCardScanning() {
        catalogRefreshTask?.cancel()
        pendingActivationIDs = []
        if isScanningCards {
            if !currentVerifiedCardIDs.isEmpty {
                scannerMessage = "已验证 \(currentVerifiedCardIDs.count) 张卡片。"
            } else if !currentScanIDs.isEmpty {
                scannerMessage = "扫描已停止。检测到 \(currentScanIDs.count) 张卡片。"
            } else {
                scannerMessage = "未检测到卡片。请打开“钱包”并轻触卡片。"
            }
        }
        let process = scanProcess
        scanProcess = nil
        if let process, process.isRunning { process.terminate() }
        isScanningCards = false
        if statusText.contains("Double-click Side button") || statusText.contains("双击侧边键") {
            statusText = "就绪"
        }
        saveCards()
        log("扫描已停止。卡片总数：\(cards.count)。")
        if process != nil { refreshWalletCatalog() }
    }
    
    // MARK: - Skin Application
    
    func applySkin() {
        guard let udid = device?.udid else {
            errorMessage = "未连接 iPhone。"
            return
        }
        let allSkinned = cards.filter { $0.isSelected && $0.customImageURL != nil }
        guard !allSkinned.isEmpty else {
            errorMessage = "请为至少一张已选中的卡片分配卡面图片。"
            return
        }
        // Only flash changed skins; if nothing changed, re-flash everything selected.
        let changed = cardsNeedingFlash
        let selectedCardsWithSkin = changed.isEmpty ? allSkinned : changed
        
        isFlashing = true
        showLogs = true
        progress = 0.0
        if changed.isEmpty {
            log("卡面未发生变更；正在重新写入所有 \(allSkinned.count) 张选中的卡片...")
        } else {
            log("开始为 \(changed.count) 张变更的卡片写入卡面；跳过 \(allSkinned.count - changed.count) 张已写入的卡片。")
        }
        let scriptDir = self.scriptDir
        
        Task.detached {
            var flashFailed = false
            let totalCards = Double(selectedCardsWithSkin.count)
            for (idx, card) in selectedCardsWithSkin.enumerated() {
                guard let imgURL = card.customImageURL else { continue }
                
                // A fresh directory per run. The old fixed /tmp path was shared
                // between runs, so a card whose artwork failed to prepare would
                // be flashed with whatever the previous run had left behind.
                let prepDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("aircard-prep-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: prepDir, withIntermediateDirectories: true)
                let preparedURL = prepDir.appendingPathComponent("card.png")
                let preparedPath = preparedURL.path
                defer { try? FileManager.default.removeItem(at: prepDir) }

                await MainActor.run {
                    self.statusText = "[\(idx + 1)/\(selectedCardsWithSkin.count)] 正在为 \(card.id.prefix(10))... 准备卡面"
                    self.progress = (Double(idx) + 0.05) / totalCards
                    self.log("正在写入卡片 [\(idx + 1)/\(selectedCardsWithSkin.count)]：\(card.id)")
                }
                
                // 1. Prepare image natively in Swift (0 external dependencies!)
                let prepped = AppViewModel.prepareCardImage(srcURL: imgURL, dstURL: preparedURL)
                if !prepped {
                    let prepProcess = Process()
                    prepProcess.executableURL = AppViewModel.pythonExecutableURL
                    prepProcess.environment = AppViewModel.processEnvironment
                    prepProcess.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
                    prepProcess.arguments = ["aircard_backend.py", "--prepare-image", imgURL.path, preparedPath]
                    try? prepProcess.run()
                    prepProcess.waitUntilExit()
                }

                // Neither path reports back, so check the file itself. Flashing
                // without this writes stale or missing artwork and still calls it
                // a success.
                let preparedSize = (try? FileManager.default.attributesOfItem(atPath: preparedPath)[.size] as? Int) ?? nil
                guard (preparedSize ?? 0) > 0 else {
                    flashFailed = true
                    let name = imgURL.lastPathComponent
                    await MainActor.run {
                        self.log("无法从 \(name) 准备卡面素材；跳过此卡片。")
                        self.errorMessage = "AirCard 无法读取为某张卡片所选的图片，该卡片保持未修改状态。"
                    }
                    continue
                }
                
                // 2. Flash card
                let flashProcess = Process()
                flashProcess.executableURL = AppViewModel.pythonExecutableURL
                flashProcess.environment = AppViewModel.processEnvironment
                flashProcess.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
                flashProcess.arguments = ["aircard_backend.py", "--flash", udid, card.id, preparedPath]
                
                let pipe = Pipe()
                let errPipe = Pipe()
                flashProcess.standardOutput = pipe
                flashProcess.standardError = errPipe
                errPipe.fileHandleForReading.readabilityHandler = { h in
                    let data = h.availableData
                    if !data.isEmpty, let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        Task { @MainActor in
                            self.log("  [err] \(text)")
                        }
                    }
                }
                
                do {
                    try flashProcess.run()
                } catch {
                    let message = error.localizedDescription
                    flashFailed = true
                    await MainActor.run {
                        self.log("启动卡片写入器失败：\(message)")
                    }
                    break
                }
                
                let handle = pipe.fileHandleForReading
                var lineBuffer = ""
                
                let handleJSONLine: (String) async -> Void = { line in
                    guard !line.isEmpty,
                          let lineData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let msg = json["message"] as? String else { return }
                    
                    let step = (json["step"] as? NSNumber)?.doubleValue
                    let total = (json["total"] as? NSNumber)?.doubleValue
                    
                    await MainActor.run {
                        if let step = step, let total = total, total > 0 {
                            let subProgress = step / total
                            let currentProgress = (Double(idx) + subProgress) / totalCards
                            self.progress = min(currentProgress, 1.0)
                        }
                        self.statusText = "[\(idx + 1)/\(selectedCardsWithSkin.count)] \(msg)"
                        self.log("  \(msg)")
                    }
                }
                
                let processChunk: (Data) async -> Void = { data in
                    guard let text = String(data: data, encoding: .utf8) else { return }
                    lineBuffer.append(text)
                    let parts = lineBuffer.components(separatedBy: .newlines)
                    if parts.count > 1 {
                        for line in parts.dropLast() {
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                await handleJSONLine(trimmed)
                            }
                        }
                        lineBuffer = parts.last ?? ""
                    }
                }
                
                while flashProcess.isRunning {
                    let data = handle.availableData
                    if data.isEmpty { usleep(50000); continue }
                    await processChunk(data)
                }
                
                let remainingData = handle.readDataToEndOfFile()
                if !remainingData.isEmpty {
                    await processChunk(remainingData)
                }
                let finalLine = lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !finalLine.isEmpty {
                    await handleJSONLine(finalLine)
                }
                flashProcess.waitUntilExit()
                errPipe.fileHandleForReading.readabilityHandler = nil

                if flashProcess.terminationStatus != 0 {
                    flashFailed = true
                    await MainActor.run {
                        self.log("卡片更新失败：\(card.id.prefix(12))...")
                    }
                    break
                }
                
                await MainActor.run {
                    self.markSkinFlashed(udid: udid, card: card)
                    self.progress = Double(idx + 1) / totalCards
                }
            }
            
            let didFail = flashFailed
            await MainActor.run {
                self.isFlashing = false
                if didFail {
                    self.statusText = "应用卡片卡面失败。"
                    self.errorMessage = "一张或多张卡片无法更新。请查看日志并重试。"
                    self.log("由于卡片更新失败，卡面应用流程已终止。")
                } else {
                    self.statusText = "完成！所有卡片已更新。"
                    self.showSuccessAlert = true
                    self.log("已成功为所有选中的卡片应用卡面！")
                }
            }
        }
    }
    
    // MARK: - Passcode Theme (.passthm) Handlers
    
    func inspectPasscodeTheme(url: URL) {
        isInspectingTheme = true
        let scriptDir = self.scriptDir
        Task.detached {
            let proc = Process()
            proc.executableURL = AppViewModel.pythonExecutableURL
            proc.environment = AppViewModel.processEnvironment
            proc.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
            proc.arguments = ["aircard_backend.py", "--inspect-passthm", url.path]
            
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool, ok {
                let name = json["name"] as? String ?? url.deletingPathExtension().lastPathComponent
                let detectedVersion = json["detected_version"] as? String ?? "TelephonyUI-10"
                let fileCount = json["file_count"] as? Int ?? 0
                var previews: [String: NSImage] = [:]
                if let keysDict = json["keys_preview"] as? [String: String] {
                    for (digit, dataUri) in keysDict {
                        if let commaIdx = dataUri.firstIndex(of: ",") {
                            let b64 = String(dataUri[dataUri.index(after: commaIdx)...])
                            if let imgData = Data(base64Encoded: b64), let nsImg = NSImage(data: imgData) {
                                previews[digit] = nsImg
                            }
                        }
                    }
                }
                let themeInfo = PasscodeThemeInfo(
                    name: name,
                    filePath: url.path,
                    detectedVersion: detectedVersion,
                    fileCount: fileCount,
                    keysPreview: previews
                )
                await MainActor.run {
                    self.loadedPasscodeTheme = themeInfo
                    self.targetTelephonyVersion = detectedVersion
                    self.isInspectingTheme = false
                    self.statusText = "已加载锁屏密码主题 '\(name)' (\(fileCount) 个素材)"
                    self.log("已加载 .passthm：\(name) [\(detectedVersion)]，包含 \(fileCount) 个图像素材")
                }
            } else {
                await MainActor.run {
                    self.isInspectingTheme = false
                    self.errorMessage = "解析 .passthm 文件失败"
                }
            }
        }
    }
    
    func flashPasscodeTheme() {
        guard let theme = loadedPasscodeTheme else { return }
        guard let dev = device, dev.connected, let udid = dev.udid else {
            errorMessage = "请先连接并在 iPhone 上信任此 Mac。"
            return
        }
        
        isFlashing = true
        showLogs = true
        progress = 0.0
        statusText = "正在启动锁屏密码主题写入..."
        log("正在将锁屏密码主题 '\(theme.name)' 写入设备...")
        let scriptDir = self.scriptDir
        let targetVer = self.targetTelephonyVersion
        let targetLang = self.passcodeLanguageTarget.code
        let targetBold = self.passcodeBoldTarget.code
        
        Task.detached {
            let proc = Process()
            proc.executableURL = AppViewModel.pythonExecutableURL
            proc.environment = AppViewModel.processEnvironment
            proc.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
            proc.arguments = [
                "aircard_backend.py",
                "--flash-passthm",
                udid,
                theme.filePath,
                targetVer,
                targetLang,
                targetBold
            ]
            
            let pipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = errPipe
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                if !data.isEmpty, let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    Task { @MainActor in
                        self.log("  [err] \(text)")
                    }
                }
            }
            try? proc.run()
            
            let handle = pipe.fileHandleForReading
            var lineBuffer = ""
            
            let handleJSONLine: (String) async -> Void = { line in
                guard !line.isEmpty,
                      let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let msg = json["message"] as? String else { return }
                
                let step = (json["step"] as? NSNumber)?.doubleValue
                let total = (json["total"] as? NSNumber)?.doubleValue
                
                await MainActor.run {
                    if let step = step, let total = total, total > 0 {
                        self.progress = min(step / total, 1.0)
                    }
                    self.statusText = msg
                    self.log("  \(msg)")
                }
            }
            
            let processChunk: (Data) async -> Void = { data in
                guard let chunkStr = String(data: data, encoding: .utf8) else { return }
                lineBuffer += chunkStr
                let parts = lineBuffer.components(separatedBy: .newlines)
                if parts.count > 1 {
                    for line in parts.dropLast() {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            await handleJSONLine(trimmed)
                        }
                    }
                    lineBuffer = parts.last ?? ""
                }
            }
            
            while proc.isRunning {
                let data = handle.availableData
                if data.isEmpty { usleep(50000); continue }
                await processChunk(data)
            }
            
            let remaining = handle.readDataToEndOfFile()
            if !remaining.isEmpty {
                await processChunk(remaining)
            }
            let finalLine = lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalLine.isEmpty {
                await handleJSONLine(finalLine)
            }
            
            proc.waitUntilExit()
            errPipe.fileHandleForReading.readabilityHandler = nil
            let exitCode = proc.terminationStatus
            
            await MainActor.run {
                self.isFlashing = false
                if exitCode == 0 {
                    self.progress = 1.0
                    self.statusText = "锁屏密码主题应用成功！"
                    self.showSuccessAlert = true
                    self.log("锁屏密码主题 '\(theme.name)' 已成功写入！")
                } else {
                    let err = self.errorMessage ?? "写入失败 (退出码 \(exitCode))"
                    self.statusText = err
                    self.log("错误: \(err)")
                }
            }
        }
    }
    
    // MARK: - Theme Creator Methods
    
    var effectiveCreatorKeys: [String: NSImage] {
        if creatorSubMode == .posterSlice {
            return creatorSlicedKeys
        } else {
            return creatorCustomKeys
        }
    }
    
    func updatePosterSlicing() {
        guard let img = creatorPosterImage else {
            creatorSlicedKeys = [:]
            return
        }
        creatorSlicedKeys = KeypadSlicer.slicePoster(
            image: img,
            zoom: creatorPosterZoom,
            offset: creatorPosterOffset,
            maskToCircles: creatorMaskToCircles
        )
    }
    
    func setPosterImage(_ img: NSImage) {
        creatorPosterImage = img
        creatorPosterZoom = 1.0
        creatorPosterOffset = .zero
        updatePosterSlicing()
        statusText = "海报图片已加载 · 可进行取景与切割"
    }
    
    func setIndividualKey(digit: String, image: NSImage) {
        creatorRawIndividualImages[digit] = image
        creatorIndividualOffsets[digit] = .zero
        creatorIndividualZooms[digit] = 1.0
        selectedKeyDigit = digit
        updateIndividualKey(digit: digit)
        statusText = "已更新按键 \(digit) · 可在拨号盘预览上拖拽移动或使用缩放滑块"
    }
    
    func updateIndividualKey(digit: String) {
        guard let raw = creatorRawIndividualImages[digit] else { return }
        let offset = creatorIndividualOffsets[digit] ?? .zero
        let zoom = creatorIndividualZooms[digit] ?? 1.0
        if let cropped = KeypadSlicer.cropToCircle(
            image: raw,
            targetSize: CGSize(width: 225, height: 225),
            circleDiameter: 222.0,
            zoom: zoom,
            offset: offset
        ) {
            creatorCustomKeys[digit] = cropped
        }
    }
    
    func clearIndividualKey(digit: String) {
        creatorCustomKeys.removeValue(forKey: digit)
        creatorRawIndividualImages.removeValue(forKey: digit)
        creatorIndividualOffsets.removeValue(forKey: digit)
        creatorIndividualZooms.removeValue(forKey: digit)
        if selectedKeyDigit == digit {
            selectedKeyDigit = nil
        }
        statusText = "已清除按键 \(digit)"
    }
    
    func clearAllIndividualKeys() {
        creatorCustomKeys.removeAll()
        creatorRawIndividualImages.removeAll()
        creatorIndividualOffsets.removeAll()
        creatorIndividualZooms.removeAll()
        selectedKeyDigit = nil
        statusText = "已清除所有自定义按键"
    }
    
    func adoptPosterSlicesToIndividualKeys() {
        for (k, v) in creatorSlicedKeys {
            creatorCustomKeys[k] = v
            creatorRawIndividualImages[k] = v
            creatorIndividualOffsets[k] = .zero
            creatorIndividualZooms[k] = 1.0
        }
        statusText = "已将海报切片应用到独立按键"
    }
    
    func editLoadedThemeInCreator() {
        guard let theme = loadedPasscodeTheme else { return }
        for (digit, img) in theme.keysPreview {
            creatorCustomKeys[digit] = img
            creatorRawIndividualImages[digit] = img
            creatorIndividualOffsets[digit] = .zero
            creatorIndividualZooms[digit] = 1.0
        }
        selectedKeyDigit = nil
        creatorSubMode = .individualKeys
        passcodeTabMode = .themeCreator
        statusText = "已将 '\(theme.name)' 载入制作器 (\(theme.keysPreview.count) 个按键可编辑)"
        log("已导入主题 '\(theme.name)' 至制作器进行自定义编辑")
    }
    
    func clearCreator() {
        creatorPosterImage = nil
        creatorPosterZoom = 1.0
        creatorPosterOffset = .zero
        creatorSlicedKeys.removeAll()
        clearAllIndividualKeys()
        statusText = "主题制作器已重置"
    }
    
    func flashCreatedTheme() {
        let keys = effectiveCreatorKeys
        guard !keys.isEmpty else {
            errorMessage = "请先添加至少一个按键图标或导入一张海报图片。"
            return
        }
        guard let dev = device, dev.connected, dev.udid != nil else {
            errorMessage = "请先连接并在 iPhone 上信任此 Mac。"
            return
        }
        
        guard let stagedURL = PasscodeThemeExporter.stageTemporaryTheme(
            keys: keys,
            language: passcodeLanguageTarget,
            boldMode: passcodeBoldTarget
        ) else {
            errorMessage = "打包待写入的主题失败。"
            return
        }
        
        let themeInfo = PasscodeThemeInfo(
            name: "自制主题",
            filePath: stagedURL.path,
            detectedVersion: targetTelephonyVersion,
            fileCount: keys.count * 4,
            keysPreview: keys
        )
        self.loadedPasscodeTheme = themeInfo
        self.flashPasscodeTheme()
    }
}

// MARK: - Card View Component (Apple Wallet Style)

struct WalletCardView: View {
    @Binding var card: CardItem
    let cardIndex: Int
    var isFlashed: Bool = false
    var isVerified: Bool = true
    let onPickImage: () -> Void
    let onClearImage: () -> Void
    let onDelete: () -> Void
    let onDropImage: (URL) -> Void
    
    @State private var isHovered = false
    @State private var isTargeted = false
    @State private var copied = false
    
    var body: some View {
        VStack(spacing: 10) {
            // Card Mockup
            ZStack {
                if let img = card.customImage {
                    // Custom Skin Applied
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 290, height: 182)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        
                        // Subtle Gloss
                        LinearGradient(
                            colors: [.white.opacity(0.18), .clear, .black.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        
                        // Top Right Clear Button
                        Button(action: onClearImage) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.white.opacity(0.9))
                                .background(Circle().fill(Color.black.opacity(0.55)))
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                        .help("移除卡面")
                        
                        // Hover overlay: Change Skin
                        if isHovered {
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    Label("更换卡面", systemImage: "photo.badge.arrow.forward")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(.ultraThinMaterial)
                                        .cornerRadius(20)
                                        .shadow(radius: 4)
                                    Spacer()
                                }
                                .padding(.bottom, 12)
                            }
                        }
                    }
                } else {
                    // Empty / Placeholder Card Mockup
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(NSColor.controlBackgroundColor),
                                        Color(NSColor.windowBackgroundColor).opacity(0.8)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                isTargeted ? Color.accentColor : (isHovered ? Color.secondary.opacity(0.4) : Color.secondary.opacity(0.2)),
                                style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: card.customImage == nil ? [6, 4] : [])
                            )
                        
                        // Card Chip & Contactless indicator
                        VStack(alignment: .leading) {
                            HStack {
                                Image(systemName: "wave.3.right")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary.opacity(0.5))
                                Spacer()
                                Image(systemName: "creditcard")
                                    .font(.system(size: 16))
                                    .foregroundColor(.secondary.opacity(0.4))
                            }
                            .padding(14)
                            Spacer()
                        }
                        
                        // Center Action
                        VStack(spacing: 8) {
                            Image(systemName: isHovered || isTargeted ? "photo.badge.plus" : "plus.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(isTargeted ? .accentColor : (isHovered ? .accentColor : .secondary.opacity(0.7)))
                                .scaleEffect(isHovered ? 1.08 : 1.0)
                                .animation(.spring(response: 0.3), value: isHovered)
                            
                            Text(isTargeted ? "将图片拖放至此处" : "设置卡片卡面")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                            
                            Text("点击浏览或拖拽图片到此处")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(width: 290, height: 182)
                }
            }
            .frame(width: 290, height: 182)
            .shadow(color: .black.opacity(isHovered ? 0.22 : 0.12), radius: isHovered ? 10 : 5, y: isHovered ? 5 : 2)
            .onHover { h in isHovered = h }
            .onTapGesture { onPickImage() }
            .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        var fileURL: URL?
                        if let url = item as? URL {
                            fileURL = url
                        } else if let data = item as? Data, let urlStr = String(data: data, encoding: .utf8), let url = URL(string: urlStr) {
                            fileURL = url
                        }
                        if let url = fileURL, NSImage(contentsOf: url) != nil {
                            Task { @MainActor in
                                onDropImage(url)
                            }
                        }
                    }
                    return true
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                        if let url = item as? URL {
                            if NSImage(contentsOf: url) != nil {
                                Task { @MainActor in
                                    onDropImage(url)
                                }
                            }
                        } else if let img = item as? NSImage {
                            let tempURL = FileManager.default.temporaryDirectory
                                .appendingPathComponent("aircard_drop_\(UUID().uuidString).png")
                            if let tiff = img.tiffRepresentation,
                               let rep = NSBitmapImageRep(data: tiff),
                               let pngData = rep.representation(using: .png, properties: [:]) {
                                try? pngData.write(to: tempURL)
                            }
                            Task { @MainActor in
                                onDropImage(tempURL)
                            }
                        }
                    }
                    return true
                }
                return false
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text(card.displayName ?? "未识别卡片")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .help(card.displayName ?? "Mac 缓存中未匹配到名称，卡片 ID 已保留。")
                if isVerified {
                    Text("在当前扫描中匹配到此 iPhone")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if card.confirmed {
                    Text("已保存在此 iPhone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("手动添加 · 可直接写入")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if card.customImageURL != nil && card.customImage == nil {
                    Text("卡面文件不可用，请重新选择图片。")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Bottom Info & Controls
            HStack(spacing: 8) {
                Toggle("", isOn: $card.isSelected)
                    .labelsHidden()
                    .help("包含在写入任务中")
                
                Text("#\(cardIndex + 1)")
                    .font(.system(size: 12, weight: .semibold))
                
                // Monospace Hash Pill with Copy
                HStack(spacing: 4) {
                    Text(card.id.prefix(8) + "…" + card.id.suffix(6))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(card.id, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundColor(copied ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(copied ? "已复制！" : "复制完整卡片 ID")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                
                Spacer()
                
                // Status badge
                if card.customImage != nil {
                    Image(systemName: isFlashed ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                        .foregroundColor(isFlashed ? .green : .orange)
                        .font(.system(size: 12))
                        .help(isFlashed ? "卡面已存在于 iPhone" : "卡面已修改，将被写入")
                }
                
                // Delete button
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("从列表中移除")
            }
            .padding(.horizontal, 4)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(card.isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - Crypto Donation Row (macOS)

struct CryptoDonationRowMac: View {
    let title: String
    let address: String
    let icon: String
    let iconColor: Color

    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .font(.system(size: 13, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isCopied = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation {
                            isCopied = false
                        }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "已复制！" : "复制")
                    }
                    .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(isCopied ? .green : .blue)
            }

            Text(address)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Main UI View

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @AppStorage("aircard.dont_show_support_on_launch") private var dontShowSupportOnLaunch: Bool = false
    @State private var showSupportPopup = false
    @State private var showCredits = false
    @State private var creditsSelectedTab = 0
    @State private var dragOffsetStart: CGPoint = .zero
    @State private var dragKeyStartOffsets: [String: CGPoint] = [:]
    @State private var isTargetedPoster = false
    @State private var isTargetedTheme = false
    
    private var readyToFlashCount: Int {
        vm.cards.filter { $0.isSelected && $0.customImageURL != nil }.count
    }
    
    private var changedCount: Int { vm.cardsNeedingFlash.count }
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. Top Header Bar
            headerView
                .padding(.leading, 78)
                .padding(.trailing, 20)
                .frame(height: 54)
                .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // 2. Control Toolbar (Unified across tabs to prevent resizing/jumping)
            Group {
                if vm.selectedTab == .walletCards {
                    toolbarView
                } else {
                    passcodeToolbarView
                }
            }
            .frame(height: 48)
            .padding(.horizontal, 20)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // 3. Live Scanner Notice Banner (if active)
            if vm.selectedTab == .walletCards && vm.isScanningCards {
                scanningNoticeBanner
                Divider()
            }
            
            if vm.selectedTab == .walletCards {
                WalletDiagnosticsView(vm: vm)
                Divider()
            }

            // 4. Main Workspace
            if vm.selectedTab == .walletCards {
                ScrollView {
                    if vm.cards.isEmpty {
                        emptyStateView
                            .padding(.top, 40)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 310, maximum: 360), spacing: 20)],
                            spacing: 20
                        ) {
                            ForEach(Array(vm.cards.enumerated()), id: \.element.id) { visibleIndex, cardItem in
                                let cardID = cardItem.id
                                let deviceID = vm.device?.udid
                                WalletCardView(
                                    card: walletCardBinding(in: $vm.cards, snapshot: cardItem),
                                    cardIndex: visibleIndex,
                                    isFlashed: vm.isSkinFlashed(cardItem),
                                    isVerified: vm.currentVerifiedCardIDs.contains(cardID),
                                    onPickImage: { openCardImagePicker(for: cardID) },
                                    onClearImage: { vm.clearCardImage(for: cardID) },
                                    onDelete: { vm.deleteCard(id: cardID) },
                                    onDropImage: { url in
                                        guard vm.device?.udid == deviceID else { return }
                                        vm.setCardImage(for: cardID, url: url)
                                    }
                                )
                            }
                        }
                        .padding(20)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Keep the fixed-size preview and creator controls inside the
                // workspace so they cannot push the header/footer offscreen.
                ScrollView(.vertical) {
                    passcodeThemeWorkspaceView
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            // 5. Collapsible Activity Console (if open or flashing)
            if vm.showLogs {
                Divider()
                activityLogView
            }
            
            Divider()
            
            // 6. Bottom Action & Status Bar
            bottomBarView
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(minWidth: 880, minHeight: 680)
        .alert("发生错误", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("好") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .alert("成功！", isPresented: $vm.showSuccessAlert) {
            Button("好的") {}
        } message: {
            if vm.selectedTab == .passcodeThemes {
                Text("锁屏密码主题已成功应用！\n\n请锁定 iPhone（或重启设备）以查看全新的密码键盘效果。")
            } else {
                Text("卡面已成功应用至所有选中的卡片！\n\n请在 iPhone 上的多任务切换器中彻底关闭“钱包”App（或重启设备）以查看新卡面设计。\n\n提示：Apple Card 采用动态矢量渲染，其卡面颜色反映消费类别，而非静态缓存卡面。")
            }
        }
        .sheet(isPresented: $showSupportPopup) {
            supportPopupSheet
        }
        .sheet(isPresented: $vm.showAddCardSheet) {
            addCardSheet
        }
        .onAppear {
            if !dontShowSupportOnLaunch {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    showSupportPopup = true
                }
            }
        }
        .onChange(of: vm.selectedTab) { _, newTab in
            if newTab == .passcodeThemes && vm.isScanningCards {
                vm.stopCardScanning()
            }
            if vm.statusText.contains("Double-click Side button") || vm.statusText.contains("双击侧边键") {
                vm.statusText = "就绪"
            }
        }
    }
    
    // MARK: - Subviews
    
    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "creditcard.circle.fill")
                .font(.system(size: 30))
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("AirCard")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("v1.2.6")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .clipShape(Capsule())
                }
                Text("钱包卡面与锁屏密码主题")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Tab Switcher
            Picker("", selection: $vm.selectedTab) {
                ForEach(AppTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.regular)
            .frame(width: 290)
            
            Spacer()
            
            // Device Status Capsule & Dropdown Selector Menu
            HStack(spacing: 8) {
                Circle()
                    .fill(vm.device?.connected == true ? Color.green : Color.red)
                    .frame(width: 8, height: 8)

                if vm.devices.isEmpty && vm.device?.connected != true {
                    Text("未连接 iPhone (USB)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Menu {
                        Section("已连接设备 (\(max(vm.devices.count, 1)))") {
                            ForEach(vm.devices.isEmpty ? (vm.device.map { [$0] } ?? []) : vm.devices) { dev in
                                Button(action: {
                                    vm.selectDevice(dev)
                                }) {
                                    HStack {
                                        if dev.udid == vm.device?.udid {
                                            Image(systemName: "checkmark")
                                        }
                                        Text(dev.menuLabel)
                                    }
                                }
                            }
                        }

                        Divider()

                        Button(action: { vm.checkDevice() }) {
                            Label("刷新设备列表", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if let dev = vm.device, dev.connected {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(dev.displayName)
                                        .font(.system(size: 11, weight: .semibold))
                                        .lineLimit(1)
                                    Text(dev.subtitle.isEmpty ? (dev.udid.map { "...\($0.suffix(6))" } ?? "") : dev.subtitle)
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            } else {
                                Text("选择设备")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            if vm.devices.count > 1 {
                                Text("\(vm.devices.count)")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.18))
                                    .foregroundColor(.accentColor)
                                    .clipShape(Capsule())
                            }

                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .help("点击以选择当前操作的设备")
                }

                Button(action: { vm.checkDevice() }) {
                    if vm.isCheckingDevice {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 11, height: 11)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.plain)
                .disabled(vm.isCheckingDevice || vm.isFlashing)
                .help("刷新设备连接")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(height: 32)
            .background(Color(NSColor.windowBackgroundColor))
            .cornerRadius(16)
            
            Button(action: { showCredits = true }) {
                Label("关于与致谢", systemImage: "heart.fill")
                    .foregroundColor(.pink)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .sheet(isPresented: $showCredits) {
                creditsSheet
            }
        }
        .controlSize(.regular)
        .frame(height: 54)
    }
    
    private var toolbarView: some View {
        HStack(spacing: 12) {
            // Live Scanner Toggle
            Button(action: { vm.toggleCardScanning() }) {
                HStack(spacing: 6) {
                    if vm.isScanningCards || vm.isCheckingDevice {
                        ProgressView()
                            .scaleEffect(0.65)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "wave.3.forward.circle.fill")
                            .frame(width: 16, height: 16)
                    }
                    Text(vm.isCheckingDevice ? "正在检测 iPhone…" : vm.isScanningCards ? "停止扫描" : "扫描卡片")
                        .fontWeight(.semibold)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.isScanningCards ? .red : .blue)
            .controlSize(.regular)
            .disabled(vm.device?.connected != true || vm.isCheckingDevice || vm.isFlashing)
            
            Button(action: { vm.showAddCardSheet = true }) {
                Label("保存卡片 ID", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            
            if !vm.cards.isEmpty {
                Button(action: openBulkImagePicker) {
                    Label("为全部卡片设置卡面...", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("为所有选中的卡片分配相同卡面")
            }
            
            Spacer()
            
            if !vm.cards.isEmpty {
                HStack(spacing: 8) {
                    Button("全选") {
                        for idx in vm.cards.indices {
                            vm.cards[idx].isSelected = true
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    
                    Text("·").foregroundColor(.secondary)
                    
                    Button("取消全选") {
                        for idx in vm.cards.indices {
                            vm.cards[idx].isSelected = false
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    
                    Text("·").foregroundColor(.secondary)
                    
                    Button("清空全部") {
                        vm.clearAllCards()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .foregroundColor(.red)
                }
            }
        }
        .controlSize(.regular)
        .frame(height: 48)
    }
    
    private var scanningNoticeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 20))
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("实时扫描中")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
                Text("请双击侧边键 (Apple Pay)，通过 Face ID 验证，然后轻触卡片。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("完成") {
                vm.stopCardScanning()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.1))
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 18) {
            Image(systemName: "creditcard.viewfinder")
                .font(.system(size: 54))
                .foregroundColor(.accentColor.opacity(0.8))
            
            Text(vm.isScanningCards ? "正在扫描卡片…" : "尚未检测到卡片")
                .font(.title3)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text("1.")
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                    Text(vm.isScanningCards ? "扫描器已处于活动状态。请在 iPhone 上打开“钱包”。" : "点击上方工具栏中的 **扫描卡片**。")
                }
                HStack(alignment: .top, spacing: 10) {
                    Text("2.")
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                    Text("在 iPhone 上，**双击侧边电源键**（开启 Apple Pay），通过 **Face ID** 验证，并 **轻触你的卡片**。")
                }
                HStack(alignment: .top, spacing: 10) {
                    Text("3.")
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                    Text(vm.isScanningCards ? "检测到的卡片将在 iPhone 响应后立即显示在此处。" : "你的卡片将被立即识别并检测到！")
                }
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            .frame(maxWidth: 460)
            .padding(20)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            
            HStack(spacing: 12) {
                Button(action: { vm.toggleCardScanning() }) {
                    Label(vm.isCheckingDevice ? "正在检测 iPhone…" : vm.isScanningCards ? "停止扫描" : "开始扫描", systemImage: "wave.3.forward.circle.fill")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(vm.device?.connected != true || vm.isCheckingDevice || vm.isFlashing)
                
                Button("手动添加卡片 ID") {
                    vm.showAddCardSheet = true
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .padding(40)
    }
    
    // MARK: - Passcode Views
    
    private var passcodeToolbarView: some View {
        HStack(spacing: 12) {
            // Mode Switcher: [Apply .passthm] | [Theme Creator]
            Picker("", selection: $vm.passcodeTabMode) {
                ForEach(PasscodeTabMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.regular)
            .frame(width: 250)
            
            if vm.passcodeTabMode == .applyTheme {
                Button(action: { openPasscodeThemePicker() }) {
                    Label("选择 .passthm 文件...", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.regular)
            } else {
                Button(action: { openPosterPicker() }) {
                    Label(vm.creatorPosterImage == nil ? "选择海报..." : "更换海报...", systemImage: "photo")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.regular)
                
                Button(action: { openSavePasscodeThemePanel() }) {
                    Label("导出 .passthm...", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(vm.effectiveCreatorKeys.isEmpty)
            }
            
            Spacer()
            
            // Target Version Picker
            HStack(spacing: 6) {
                Text("目标版本：")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $vm.targetTelephonyVersion) {
                    Text("TelephonyUI-10 (iOS 18+)").tag("TelephonyUI-10")
                    Text("TelephonyUI-9 (iOS 16–17)").tag("TelephonyUI-9")
                    Text("TelephonyUI-8 (iOS 14–15)").tag("TelephonyUI-8")
                    Text("通用 (包含 8、9、10)").tag("all")
                }
                .pickerStyle(.menu)
                .controlSize(.regular)
                .frame(width: 205)
            }
            
            Text("·")
                .foregroundColor(.secondary)
            
            if vm.passcodeTabMode == .applyTheme {
                Button("清除主题") {
                    vm.loadedPasscodeTheme = nil
                }
                .buttonStyle(.link)
                .font(.caption)
                .foregroundColor(.red)
                .disabled(vm.loadedPasscodeTheme == nil)
            } else {
                Button("清空全部") {
                    vm.clearCreator()
                }
                .buttonStyle(.link)
                .font(.caption)
                .foregroundColor(.red)
                .disabled(vm.effectiveCreatorKeys.isEmpty && vm.creatorPosterImage == nil)
            }
        }
        .controlSize(.regular)
        .frame(height: 48)
    }
    
    private var passcodeThemeWorkspaceView: some View {
        Group {
            if vm.passcodeTabMode == .applyTheme {
                passcodeApplyThemeWorkspaceView
            } else {
                passcodeThemeCreatorWorkspaceView
            }
        }
    }
    
    // MARK: - Apply Theme Mode
    
    private var passcodeApplyThemeWorkspaceView: some View {
        HStack(alignment: .top, spacing: 20) {
            // Left Column: Controls & Actions (width: 320)
            VStack(alignment: .leading, spacing: 14) {
                applyThemeControlsCard
                targetSettingsCard
                Spacer()
            }
            .frame(width: 320)
            
            // Right Column: Authentic iPhone Lock Screen Mockup
            VStack(spacing: 8) {
                HStack {
                    Text("锁屏数字键盘预览")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Spacer()
                    if vm.loadedPasscodeTheme != nil {
                        Text("已加载自定义主题")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.green)
                    }
                }
                .padding(.horizontal, 6)
                
                phoneMockupContainer {
                    applyThemeDialerCanvas
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .onDrop(of: [UTType.fileURL, UTType.data], isTargeted: nil) { providers in
            if let provider = providers.first {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        Task { @MainActor in
                            vm.inspectPasscodeTheme(url: url)
                        }
                    } else if let url = item as? URL {
                        Task { @MainActor in
                            vm.inspectPasscodeTheme(url: url)
                        }
                    }
                }
                return true
            }
            return false
        }
    }
    
    private var applyThemeControlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("锁屏密码主题文件")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            
            if let theme = vm.loadedPasscodeTheme {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.square.stack.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.purple)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(theme.name)
                                .font(.headline)
                                .fontWeight(.bold)
                            
                            Text(theme.detectedVersion)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.15))
                                .foregroundColor(.purple)
                                .cornerRadius(4)
                        }
                    }
                    
                    Text("已加载 \(theme.fileCount) 个素材 · 可写入至 iPhone")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 8) {
                        Button(action: { vm.editLoadedThemeInCreator() }) {
                            Label("在制作器中编辑", systemImage: "pencil.and.outline")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .controlSize(.regular)
                        
                        Button("更换...") {
                            openPasscodeThemePicker()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        
                        Button("清除") {
                            vm.loadedPasscodeTheme = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.purple)
                    
                    Text("将 .passthm 文件拖放至此处")
                        .font(.caption)
                        .fontWeight(.semibold)
                    
                    Text("支持 Cowabunga 或 Nugget 导出的 .passthm、.passtheme 或 .zip 主题包")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                    
                    Button("选择文件...") {
                        openPasscodeThemePicker()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.regular)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isTargetedTheme ? Color.purple : Color.purple.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.4).cornerRadius(12))
                )
                .onDrop(of: [UTType.fileURL, UTType.data], isTargeted: $isTargetedTheme) { providers in
                    if let provider = providers.first {
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                                Task { @MainActor in
                                    vm.inspectPasscodeTheme(url: url)
                                }
                            } else if let url = item as? URL {
                                Task { @MainActor in
                                    vm.inspectPasscodeTheme(url: url)
                                }
                            }
                        }
                        return true
                    }
                    return false
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 1)
        )
    }
    
    private var applyThemeDialerCanvas: some View {
        ZStack {
            ForEach(KeypadLayout.allButtons) { btn in
                let cellX = CGFloat(btn.col) * KeypadLayout.colWidth
                let cellY = CGFloat(btn.row) * KeypadLayout.rowHeight
                let centerX = cellX + KeypadLayout.colWidth / 2.0
                let centerY = cellY + KeypadLayout.rowHeight / 2.0
                
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                    
                    if let img = vm.loadedPasscodeTheme?.keysPreview[btn.digit] {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                            .clipShape(Circle())
                    }
                    
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
                        .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                    
                    VStack(spacing: 1) {
                        Text(btn.digit)
                            .font(.system(size: 28, weight: .light))
                            .foregroundColor(.white)
                        if !btn.letters.isEmpty {
                            Text(btn.letters)
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(1)
                                .foregroundColor(.white.opacity(0.9))
                        }
                    }
                }
                .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                .position(x: centerX, y: centerY)
            }
        }
        .frame(width: KeypadLayout.gridWidth, height: KeypadLayout.gridHeight)
    }
    
    // MARK: - Theme Creator Mode
    
    private var passcodeThemeCreatorWorkspaceView: some View {
        HStack(alignment: .top, spacing: 20) {
            // Left Column: Controls & Actions (width: 320)
            VStack(alignment: .leading, spacing: 14) {
                creatorControlsCard
                targetSettingsCard
                Spacer()
            }
            .frame(width: 320)
            
            // Right Column: Authentic iPhone Lock Screen Mockup
            VStack(spacing: 8) {
                HStack {
                    Text("iPhone 锁屏交互式实时预览")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Spacer()
                    if vm.creatorSubMode == .posterSlice && vm.creatorPosterImage != nil {
                        Text("拖拽拨号盘可平移 · 使用滑块缩放")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                
                phoneMockupContainer {
                    creatorDialerCanvas
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
    
    private var creatorControlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Mode Selector: Poster Slice vs Individual Keys
            Picker("", selection: $vm.creatorSubMode) {
                ForEach(CreatorSubMode.allCases) { subMode in
                    Text(subMode.rawValue).tag(subMode)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.regular)
            
            Divider()
            
            if vm.creatorSubMode == .posterSlice {
                // 1. Poster Source Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("海报素材")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    if let poster = vm.creatorPosterImage {
                        HStack(spacing: 12) {
                            Image(nsImage: poster)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 50, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.purple.opacity(0.4), lineWidth: 1)
                                )
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("素材已载入")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                HStack(spacing: 8) {
                                    Button("更换...") {
                                        openPosterPicker()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    
                                    Button("移除") {
                                        vm.clearCreator()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 26))
                                .foregroundColor(.purple)
                            
                            Text("将海报或壁纸拖放至此处")
                                .font(.caption)
                                .fontWeight(.medium)
                            
                            Button("选择图片...") {
                                openPosterPicker()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            .controlSize(.regular)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(isTargetedPoster ? Color.purple : Color.purple.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                                .background(Color(NSColor.controlBackgroundColor).opacity(0.4).cornerRadius(10))
                        )
                        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $isTargetedPoster) { providers in
                            handlePosterDrop(providers: providers)
                        }
                    }
                }
                
                Divider()
                
                // 2. Style Section
                VStack(alignment: .leading, spacing: 6) {
                    Text("切割样式")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    Picker("", selection: $vm.creatorMaskToCircles) {
                        Text("无缝海报").tag(false)
                        Text("圆形按键").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: vm.creatorMaskToCircles) { _, _ in
                        vm.updatePosterSlicing()
                    }
                    
                    Text(vm.creatorMaskToCircles ? "素材被裁剪为独立的圆形按键图标。" : "整张海报跨拨号盘按键无缝拼接展现，无圆形裁剪切割。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Divider()
                
                // 3. Framing & Zoom Section
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("取景与缩放")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Button("重置位置") {
                            withAnimation(.spring()) {
                                vm.creatorPosterZoom = 1.0
                                vm.creatorPosterOffset = .zero
                                dragOffsetStart = .zero
                                vm.updatePosterSlicing()
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption2)
                        .disabled(vm.creatorPosterImage == nil)
                    }
                    
                    HStack(spacing: 8) {
                        Image(systemName: "minus.magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        
                        Slider(value: $vm.creatorPosterZoom, in: 0.5...3.0, step: 0.05) {
                            Text("缩放")
                        }
                        .onChange(of: vm.creatorPosterZoom) { _, _ in
                            vm.updatePosterSlicing()
                        }
                        .disabled(vm.creatorPosterImage == nil)
                        
                        Image(systemName: "plus.magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        
                        Text(String(format: "%.1fx", vm.creatorPosterZoom))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .frame(width: 32, alignment: .trailing)
                    }
                    
                    HStack(spacing: 6) {
                        Image(systemName: "hand.draw")
                            .foregroundColor(.secondary)
                            .font(.caption2)
                        Text("在拨号盘预览区域任意拖拽以调整位置")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                // Individual Keys Mode Controls
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("独立按键")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Spacer()
                        if let sel = vm.selectedKeyDigit {
                            Button("取消选择按键 \(sel)") {
                                vm.selectedKeyDigit = nil
                            }
                            .buttonStyle(.link)
                            .font(.caption2)
                        }
                    }
                    
                    if let selDigit = vm.selectedKeyDigit, vm.creatorRawIndividualImages[selDigit] != nil || vm.creatorCustomKeys[selDigit] != nil {
                        // Per-key framing controls
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("按键 \(selDigit) 取景裁剪", systemImage: "crop")
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                                    .foregroundColor(.purple)
                                Spacer()
                                Button("重置") {
                                    withAnimation(.spring()) {
                                        vm.creatorIndividualOffsets[selDigit] = .zero
                                        vm.creatorIndividualZooms[selDigit] = 1.0
                                        dragKeyStartOffsets[selDigit] = .zero
                                        vm.updateIndividualKey(digit: selDigit)
                                    }
                                }
                                .buttonStyle(.link)
                                .font(.caption2)
                            }
                            
                            // Zoom Slider for the selected key
                            let zoomVal = vm.creatorIndividualZooms[selDigit] ?? 1.0
                            HStack(spacing: 8) {
                                Image(systemName: "minus.magnifyingglass")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                
                                Slider(
                                    value: Binding(
                                        get: { vm.creatorIndividualZooms[selDigit] ?? 1.0 },
                                        set: { newVal in
                                             vm.creatorIndividualZooms[selDigit] = newVal
                                             vm.updateIndividualKey(digit: selDigit)
                                        }
                                    ),
                                    in: 0.5...3.0,
                                    step: 0.05
                                )
                                
                                Image(systemName: "plus.magnifyingglass")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                
                                Text(String(format: "%.1fx", zoomVal))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .frame(width: 32, alignment: .trailing)
                            }
                            
                            HStack(spacing: 6) {
                                Image(systemName: "hand.draw")
                                    .foregroundColor(.secondary)
                                    .font(.caption2)
                                Text("在拨号盘预览上拖拽按键 \(selDigit) 以调整位置")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            HStack(spacing: 8) {
                                Button("更换图片...") {
                                    openIndividualKeyPicker(for: selDigit)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                
                                Button("移除") {
                                    vm.clearIndividualKey(digit: selDigit)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.top, 2)
                        }
                        .padding(10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.purple.opacity(0.35), lineWidth: 1)
                        )
                        
                        Divider()
                    }
                    
                    Text("点击拨号盘上的任意按键进行选中，可平移图片、调整缩放或直接拖入文件。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                        Text("已配置 \(vm.creatorCustomKeys.count)/10 个按键")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    
                    HStack(spacing: 8) {
                        if !vm.creatorSlicedKeys.isEmpty {
                            Button("从海报切片填充") {
                                vm.adoptPosterSlicesToIndividualKeys()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        }
                        
                        Button("清空所有按键") {
                            vm.clearAllIndividualKeys()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(vm.creatorCustomKeys.isEmpty)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 1)
        )
    }
    
    private func scaledPosterDimensions(for poster: NSImage) -> (width: CGFloat, height: CGFloat) {
        let imgAspect = poster.size.width / poster.size.height
        let gridAspect = KeypadLayout.gridWidth / KeypadLayout.gridHeight
        let zoom = CGFloat(max(0.1, vm.creatorPosterZoom))
        if imgAspect > gridAspect {
            let h = KeypadLayout.gridHeight * zoom
            return (width: h * imgAspect, height: h)
        } else {
            let w = KeypadLayout.gridWidth * zoom
            return (width: w, height: w / imgAspect)
        }
    }
    
    private var creatorDialerCanvas: some View {
        ZStack {
            // Layer 1: Background Poster Image (Seamless Poster Mode)
            if vm.creatorSubMode == .posterSlice, let poster = vm.creatorPosterImage, !vm.creatorMaskToCircles {
                let dims = scaledPosterDimensions(for: poster)
                Image(nsImage: poster)
                    .resizable()
                    .frame(width: dims.width, height: dims.height)
                    .position(
                        x: KeypadLayout.gridWidth / 2.0 + vm.creatorPosterOffset.x,
                        y: KeypadLayout.gridHeight / 2.0 + vm.creatorPosterOffset.y
                    )
            }
            
            // Layer 2: 10 Buttons laid out in exact cell frames
            ForEach(KeypadLayout.allButtons) { btn in
                let cellX = CGFloat(btn.col) * KeypadLayout.colWidth
                let cellY = CGFloat(btn.row) * KeypadLayout.rowHeight
                let centerX = cellX + KeypadLayout.colWidth / 2.0
                let centerY = cellY + KeypadLayout.rowHeight / 2.0
                
                creatorButtonView(for: btn)
                    .position(x: centerX, y: centerY)
            }
        }
        .frame(width: KeypadLayout.gridWidth, height: KeypadLayout.gridHeight)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if vm.creatorSubMode == .posterSlice && vm.creatorPosterImage != nil {
                        vm.creatorPosterOffset = CGPoint(
                            x: dragOffsetStart.x + value.translation.width,
                            y: dragOffsetStart.y + value.translation.height
                        )
                        vm.updatePosterSlicing()
                    }
                }
                .onEnded { _ in
                    dragOffsetStart = vm.creatorPosterOffset
                }
        )
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: nil) { providers in
            handlePosterDrop(providers: providers)
        }
    }
    
    private func creatorButtonView(for btn: KeypadButtonGeometry) -> some View {
        let customIndividualImage = vm.creatorCustomKeys[btn.digit]
        let slicedImage = vm.creatorSlicedKeys[btn.digit]
        
        return ZStack {
            if vm.creatorSubMode == .posterSlice {
                if vm.creatorMaskToCircles {
                    // Circular Cutouts mode: display sliced circular preview
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                    
                    if let img = slicedImage {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                            .clipShape(Circle())
                    }
                    
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
                        .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                } else {
                    // Seamless Poster mode: frosted translucent circle indicator
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                    
                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                        .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                }
            } else {
                // Individual Keys mode
                let isSelected = (vm.selectedKeyDigit == btn.digit)
                Circle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                
                if let img = customIndividualImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                }
                
                Circle()
                    .stroke(isSelected ? Color.purple : Color.white.opacity(0.3), lineWidth: isSelected ? 2.5 : 1)
                    .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                    .shadow(color: isSelected ? Color.purple.opacity(0.8) : Color.clear, radius: 4)
            }
            
            // Authentic Digits & Letters Typography
            VStack(spacing: 1) {
                Text(btn.digit)
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.white)
                if !btn.letters.isEmpty {
                    Text(btn.letters)
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1)
                        .foregroundColor(.white.opacity(0.9))
                }
            }
        }
        .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if vm.creatorSubMode == .individualKeys && (vm.creatorRawIndividualImages[btn.digit] != nil || vm.creatorCustomKeys[btn.digit] != nil) {
                        if vm.selectedKeyDigit != btn.digit {
                            vm.selectedKeyDigit = btn.digit
                        }
                        let start = dragKeyStartOffsets[btn.digit] ?? (vm.creatorIndividualOffsets[btn.digit] ?? .zero)
                        vm.creatorIndividualOffsets[btn.digit] = CGPoint(
                            x: start.x + value.translation.width,
                            y: start.y + value.translation.height
                        )
                        vm.updateIndividualKey(digit: btn.digit)
                    }
                }
                .onEnded { _ in
                    if let cur = vm.creatorIndividualOffsets[btn.digit] {
                        dragKeyStartOffsets[btn.digit] = cur
                    }
                }
        )
        .onTapGesture {
            if vm.creatorSubMode == .individualKeys {
                if customIndividualImage == nil && vm.creatorRawIndividualImages[btn.digit] == nil {
                    openIndividualKeyPicker(for: btn.digit)
                } else {
                    vm.selectedKeyDigit = (vm.selectedKeyDigit == btn.digit ? nil : btn.digit)
                }
            }
        }
        .contextMenu {
            if vm.creatorSubMode == .individualKeys {
                Button("更换按键 \(btn.digit) 图标...") {
                    openIndividualKeyPicker(for: btn.digit)
                }
                if customIndividualImage != nil {
                    Button("重置位置与缩放") {
                        vm.creatorIndividualOffsets[btn.digit] = .zero
                        vm.creatorIndividualZooms[btn.digit] = 1.0
                        dragKeyStartOffsets[btn.digit] = .zero
                        vm.updateIndividualKey(digit: btn.digit)
                    }
                    Button("清除按键 \(btn.digit)") {
                        vm.clearIndividualKey(digit: btn.digit)
                    }
                }
            }
        }
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: nil) { providers in
            if vm.creatorSubMode == .individualKeys {
                return handleIndividualKeyDrop(digit: btn.digit, providers: providers)
            }
            return false
        }
    }
    
    // MARK: - Authentic Phone Lock Screen Mockup Container
    
    private func phoneMockupContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            // Phone Background (Deep Lock Screen Slate / Black)
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.10))
            
            // Subtle frosted gradient
            LinearGradient(
                colors: [Color.white.opacity(0.04), Color.clear, Color.black.opacity(0.3)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
            
            VStack(spacing: 0) {
                // Lock Screen Header (Height ~64)
                VStack(spacing: 4) {
                    Capsule()
                        .fill(Color.black.opacity(0.6))
                        .frame(width: 60, height: 18)
                        .overlay(
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.9))
                        )
                    
                    Text("输入密码")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.white.opacity(0.95))
                        .padding(.top, 2)
                    
                    // 6-Dot Indicator
                    HStack(spacing: 10) {
                        ForEach(0..<6, id: \.self) { _ in
                            Circle()
                                .stroke(Color.white.opacity(0.7), lineWidth: 1.5)
                                .frame(width: 9, height: 9)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.top, 12)
                
                Spacer(minLength: 2)
                
                // The Dialer Grid (Exact 305 x 382.67 pt Canvas)
                content()
                    .frame(width: KeypadLayout.gridWidth, height: KeypadLayout.gridHeight)
                
                Spacer(minLength: 2)
                
                // Lock Screen Footer (Height ~28)
                HStack {
                    Text("紧急呼叫")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white.opacity(0.9))
                    Spacer()
                    Text("取消")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white.opacity(0.9))
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 326, height: 512)
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 16, x: 0, y: 8)
    }
    
    // MARK: - Passcode Target Configuration Box
    
    private var targetSettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(.purple)
                    .font(.system(size: 13, weight: .semibold))
                Text("写入目标与语言设置")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Spacer()
                if let dev = vm.device, dev.connected {
                    Button(action: { vm.applyDevicePreferences(from: dev) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                            Text("自动检测")
                        }
                        .font(.system(size: 9, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .help("恢复为 iPhone 检测到的语言与字体样式")
                }
            }
            
            // 1. Language Target Selector
            VStack(alignment: .leading, spacing: 4) {
                Text("系统语言：")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                
                Picker("", selection: $vm.passcodeLanguageTarget) {
                    ForEach(PasscodeLanguageTarget.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            
            // 2. Bold / Font Weight Selector
            VStack(alignment: .leading, spacing: 4) {
                Text("字重 / 字体样式：")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                
                Picker("", selection: $vm.passcodeBoldTarget) {
                    ForEach(PasscodeBoldTarget.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            
            // Helpful Speed / Info Hint
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: vm.passcodeLanguageTarget == .all && vm.passcodeBoldTarget == .both ? "globe" : "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundColor(vm.passcodeLanguageTarget == .all && vm.passcodeBoldTarget == .both ? .secondary : .orange)
                    .padding(.top, 1)
                
                if vm.passcodeLanguageTarget == .all && vm.passcodeBoldTarget == .both {
                    Text("通用模式会为所有语言及粗体文本写入约 600 个文件。选择特定语言（如中文）可显著提升写入速度。")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("已选择极速模式：仅针对 \(vm.passcodeLanguageTarget.rawValue) 及 \(vm.passcodeBoldTarget.rawValue)。")
                        .font(.system(size: 9))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.purple.opacity(0.3), lineWidth: 1))
    }
    
    private var activityLogView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("运行日志")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                Button("清空") {
                    vm.logs.removeAll()
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(vm.logs.enumerated()), id: \.offset) { idx, log in
                            Text(log)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .id(idx)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
                .frame(height: 90)
                .onChange(of: vm.logs.count) { _, _ in
                    if let last = vm.logs.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }
    
    private var bottomBarView: some View {
        VStack(spacing: 8) {
            if vm.isFlashing || vm.progress > 0 {
                ProgressView(value: vm.progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .animation(.easeInOut(duration: 0.2), value: vm.progress)
            }
            
            HStack(spacing: 16) {
                // Left Status Text
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(vm.statusText)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        if vm.isFlashing || vm.progress > 0 {
                            Text("\(Int(min(max(vm.progress, 0.0), 1.0) * 100))%")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                    
                    if vm.selectedTab == .passcodeThemes {
                        if vm.passcodeTabMode == .themeCreator {
                            let count = vm.effectiveCreatorKeys.count
                            let targetInfo = "\(vm.targetTelephonyVersion) · \(vm.passcodeLanguageTarget.code.uppercased()) · \(vm.passcodeBoldTarget.code)"
                            if count > 0 {
                                Text("主题制作器 · 已配置 \(count)/10 个按键 · 目标：\(targetInfo)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            } else {
                                Text("主题制作器 · 导入海报或拖放图标到按键上")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        } else if let theme = vm.loadedPasscodeTheme {
                            let targetInfo = "\(vm.targetTelephonyVersion) · \(vm.passcodeLanguageTarget.code.uppercased()) · \(vm.passcodeBoldTarget.code)"
                            Text("已载入 \(theme.fileCount) 个素材 · 目标：\(targetInfo)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        } else {
                            Text("未加载 .passthm · 请选择要写入的主题包")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    } else if !vm.cards.isEmpty {
                        let selectedCount = vm.cards.filter { $0.isSelected }.count
                        Text("已选择 \(selectedCount)/\(vm.cards.count) 张卡片 · \(changedCount) 张已修改 · \(readyToFlashCount - changedCount) 张已存在于 iPhone")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Toggle Log Drawer
                Button(action: { withAnimation { vm.showLogs.toggle() } }) {
                    HStack(spacing: 5) {
                        Image(systemName: "terminal")
                            .frame(width: 14, height: 14)
                        Text("日志")
                        Image(systemName: vm.showLogs ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                
                // Apply / Flash Button
                if vm.selectedTab == .passcodeThemes {
                    if vm.passcodeTabMode == .themeCreator {
                        Button(action: { vm.flashCreatedTheme() }) {
                            HStack(spacing: 6) {
                                if vm.isFlashing {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: "lock.shield.fill")
                                        .frame(width: 16, height: 16)
                                }
                                Text(vm.isFlashing ? "正在写入密码键盘..." : "写入至 iPhone")
                                    .fontWeight(.semibold)
                            }
                            .padding(.horizontal, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .controlSize(.regular)
                        .disabled(vm.effectiveCreatorKeys.isEmpty || vm.isFlashing || vm.device?.connected != true)
                    } else {
                        Button(action: { vm.flashPasscodeTheme() }) {
                            HStack(spacing: 6) {
                                if vm.isFlashing {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: "lock.shield.fill")
                                        .frame(width: 16, height: 16)
                                }
                                Text(vm.isFlashing ? "正在写入密码键盘..." : "写入锁屏密码主题")
                                    .fontWeight(.semibold)
                            }
                            .padding(.horizontal, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .controlSize(.regular)
                        .disabled(vm.loadedPasscodeTheme == nil || vm.isFlashing || vm.device?.connected != true)
                    }
                } else {
                    Button(action: { vm.applySkin() }) {
                        HStack(spacing: 6) {
                            if vm.isFlashing {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "sparkles")
                                    .frame(width: 16, height: 16)
                            }
                            Text(vm.isFlashing ? "正在写入卡面..." : (changedCount > 0 ? "写入卡面 (\(changedCount) 张变更)" : (readyToFlashCount > 0 ? "全部重新写入 (\(readyToFlashCount))" : "写入卡面")))
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.regular)
                    .disabled(readyToFlashCount == 0 || vm.isFlashing || vm.device?.connected != true)
                }
            }
            
            // Subtle Footer Credits
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Text("开发者：")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Link("@mak5er", destination: URL(string: "https://github.com/mak5er")!)
                        .font(.system(size: 10))
                    Text("&")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Link("@Lumid-Off", destination: URL(string: "https://github.com/Lumid-Off")!)
                        .font(.system(size: 10))
                }
            }
        }
    }
    
    // MARK: - Sheets & Pickers
    
    @ViewBuilder
    private var macDonateContentView: some View {
        VStack(spacing: 12) {
            // Creator Card
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "heart.circle.fill")
                        .font(.system(size: 34))
                        .foregroundColor(.pink)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Maksym Reva")
                                .font(.system(size: 14, weight: .bold))
                            Text("🇺🇦")
                                .font(.system(size: 13))
                        }
                        Text("@mak5er • 主开发者")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                // Social Links
                HStack(spacing: 8) {
                    Link(destination: URL(string: "https://x.com/mak5er")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                            Text("Twitter / X")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.12))
                        .foregroundColor(.blue)
                        .cornerRadius(6)
                    }

                    Link(destination: URL(string: "https://github.com/mak5er")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                            Text("GitHub")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.08))
                        .foregroundColor(.primary)
                        .cornerRadius(6)
                    }
                }
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)

            // Payment Methods
            VStack(alignment: .leading, spacing: 8) {
                Text("捐赠与支持")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 2)

                // PayPal Button
                Link(destination: URL(string: "https://www.paypal.com/donate/?hosted_button_id=98QRTC2HFRA4Y")!) {
                    HStack(spacing: 8) {
                        Image(systemName: "creditcard.fill")
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("通过 PayPal 捐赠")
                                .font(.system(size: 12, weight: .bold))
                            Text("收款人：Maksym Reva")
                                .font(.system(size: 10))
                                .opacity(0.85)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundColor(.white)
                    .background(Color.blue)
                    .cornerRadius(8)
                }

                // TON
                CryptoDonationRowMac(
                    title: "💎 TON (The Open Network)",
                    address: "UQBm9KPhtMw-XVVjirUoa09wzrlyWsbeZhKfefl1Uw-qNZ-r",
                    icon: "diamond.fill",
                    iconColor: .cyan
                )

                // USDT TRC20
                CryptoDonationRowMac(
                    title: "💵 USDT (TRC20)",
                    address: "TDkDMCyjYxgvkWUnQiF5Erk2RyPQMT6G1n",
                    icon: "dollarsign.circle.fill",
                    iconColor: .green
                )

                // BEP20
                CryptoDonationRowMac(
                    title: "🪙 BEP20 (BNB / USDT)",
                    address: "0x0954dc491c502849d04956ef74634aa5931a08e8",
                    icon: "bitcoinsign.circle.fill",
                    iconColor: .orange
                )
            }

            Text("感谢你对 AirCard 开发的支持！❤️")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var supportPopupSheet: some View {
        VStack(spacing: 14) {
            // Header
            VStack(spacing: 4) {
                Image(systemName: "heart.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.pink)

                Text("欢迎使用 AirCard！")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("免费开源 • 由 @mak5er 开发")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            macDonateContentView

            Divider()

            VStack(spacing: 8) {
                Button("进入 AirCard") {
                    showSupportPopup = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .frame(maxWidth: .infinity)

                Toggle("启动时不再显示此弹窗", isOn: $dontShowSupportOnLaunch)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("你可以随时在“关于与致谢”中重新打开捐赠页面 ❤️")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var creditsSheet: some View {
        VStack(spacing: 14) {
            Picker("分类", selection: $creditsSelectedTab) {
                Text("关于项目").tag(0)
                Text("支持作者 ❤️").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 4)

            Divider()

            if creditsSelectedTab == 0 {
                VStack(spacing: 16) {
                    Image(systemName: "creditcard.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.accentColor)
                    
                    Text("AirCard")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Apple 钱包卡面与锁屏密码主题定制 (iOS 18.0 – 27.2 b2)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // Button to Donate
                    Button(action: {
                        withAnimation {
                            creditsSelectedTab = 1
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "heart.fill")
                                .foregroundColor(.pink)
                            Text("支持 @mak5er (前往赞助 ❤️)")
                                .fontWeight(.semibold)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .background(Color.pink.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    Divider()
                    
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "person.crop.circle.fill")
                                .foregroundColor(.blue)
                            Text("开发者：")
                                .fontWeight(.medium)
                            Link("@mak5er", destination: URL(string: "https://github.com/mak5er")!)
                            Text("·")
                                .foregroundColor(.secondary)
                            Link("Twitter / X", destination: URL(string: "https://x.com/mak5er")!)
                        }
                        
                        HStack {
                            Image(systemName: "person.crop.circle.fill")
                                .foregroundColor(.blue)
                            Text("开发者：")
                                .fontWeight(.medium)
                            Link("@Lumid-Off", destination: URL(string: "https://github.com/Lumid-Off")!)
                            Text("·")
                                .foregroundColor(.secondary)
                            Link("Twitter / X", destination: URL(string: "https://x.com/LumidOff")!)
                        }
                        
                        HStack {
                            Image(systemName: "bolt.shield.fill")
                                .foregroundColor(.orange)
                            Text("核心漏洞机制：")
                                .fontWeight(.medium)
                            Text("airlift (AirTraffic 同步逃逸)")
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Image(systemName: "lock.shield.fill")
                                .foregroundColor(.purple)
                            Text("密码主题格式：")
                                .fontWeight(.medium)
                            Text(".passthm 标准格式 (Cowabunga / Nugget)")
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                }
            } else {
                macDonateContentView
            }
            
            Divider()
            
            Button("关闭") {
                showCredits = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(20)
        .frame(width: 440)
    }
    
    private var addCardSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("保存卡片 ID 用于匹配")
                .font(.headline)
            Text("粘贴一个或多个卡片 ID。已保存的 ID 在连接的 iPhone 于扫描中上报前会保持隐藏。")
                .font(.caption)
                .foregroundColor(.secondary)
            
            TextEditor(text: $vm.manualHashInput)
                .font(.system(.body, design: .monospaced))
                .frame(height: 120)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            
            HStack {
                Button("取消") {
                    vm.showAddCardSheet = false
                    vm.manualHashInput = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                
                Spacer()
                
                Button("保存 ID") {
                    vm.addCardHash(vm.manualHashInput)
                    vm.showAddCardSheet = false
                    vm.manualHashInput = ""
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(vm.manualHashInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 440)
    }
    
    private func openCardImagePicker(for cardId: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "为卡片 \(cardId.prefix(12))... 选择自定义卡面图片"
        if panel.runModal() == .OK, let url = panel.url {
            vm.setCardImage(for: cardId, url: url)
        }
    }
    
    private func openBulkImagePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要分配给所有选中卡片的卡面图片..."
        if panel.runModal() == .OK, let url = panel.url {
            for card in vm.cards where card.isSelected {
                vm.setCardImage(for: card.id, url: url)
            }
        }
    }
    
    private func openPasscodeThemePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "passthm") ?? .data,
            UTType(filenameExtension: "passtheme") ?? .data,
            .zip
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择 .passthm 锁屏密码主题包..."
        if panel.runModal() == .OK, let url = panel.url {
            vm.inspectPasscodeTheme(url: url)
        }
    }
    
    private func openPosterPicker() {
        let panel = NSOpenPanel()
        panel.title = "选择海报图片"
        panel.message = "选择要为密码键盘切割的壁纸或照片..."
        panel.allowedContentTypes = [
            UTType.png,
            UTType.jpeg,
            UTType(filenameExtension: "heic") ?? .image,
            UTType(filenameExtension: "webp") ?? .image,
            .image
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            vm.setPosterImage(img)
        }
    }
    
    private func openIndividualKeyPicker(for digit: String) {
        let panel = NSOpenPanel()
        panel.title = "选择按键 \(digit) 的图标"
        panel.message = "为按键 \(digit) 选择图标或图片..."
        panel.allowedContentTypes = [
            UTType.png,
            UTType.jpeg,
            UTType(filenameExtension: "heic") ?? .image,
            UTType(filenameExtension: "webp") ?? .image,
            .image
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            vm.setIndividualKey(digit: digit, image: img)
        }
    }
    
    private func openSavePasscodeThemePanel() {
        let keys = vm.effectiveCreatorKeys
        guard !keys.isEmpty else {
            vm.errorMessage = "导出前请至少配置一个按键。"
            return
        }
        
        let panel = NSSavePanel()
        panel.title = "保存锁屏密码主题"
        panel.prompt = "导出"
        panel.nameFieldStringValue = "自制密码主题.passthm"
        panel.allowedContentTypes = [UTType(filenameExtension: "passthm") ?? .data]
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try PasscodeThemeExporter.exportTheme(keys: keys, targetURL: url)
                vm.statusText = "主题已成功导出至 \(url.lastPathComponent)"
                vm.log("已导出 .passthm 至 \(url.path)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                vm.errorMessage = "导出主题失败：\(error.localizedDescription)"
            }
        }
    }
    
    private func handlePosterDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        loadImage(from: provider) { img in
            if let img = img {
                vm.setPosterImage(img)
            }
        }
        return true
    }
    
    private func handleIndividualKeyDrop(digit: String, providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        loadImage(from: provider) { img in
            if let img = img {
                vm.setIndividualKey(digit: digit, image: img)
            }
        }
        return true
    }
    
    private func loadImage(from provider: NSItemProvider, completion: @escaping (NSImage?) -> Void) {
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url, let img = NSImage(contentsOf: url) {
                    DispatchQueue.main.async { completion(img) }
                    return
                }
                if provider.canLoadObject(ofClass: NSImage.self) {
                    _ = provider.loadObject(ofClass: NSImage.self) { img, _ in
                        DispatchQueue.main.async { completion(img as? NSImage) }
                    }
                } else {
                    DispatchQueue.main.async { completion(nil) }
                }
            }
        } else if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { img, _ in
                DispatchQueue.main.async { completion(img as? NSImage) }
            }
        } else {
            completion(nil)
        }
    }
}

// MARK: - App Entry Point

#if !WALLET_TESTS
@main
struct AirCardApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
#endif
