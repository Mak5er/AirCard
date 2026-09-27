import SwiftUI
import AppKit
import IOKit
import UniformTypeIdentifiers
import Darwin

// A descendant may inherit stdout. Do not wait forever for its EOF after
// the backend itself exits; drain available output, then inspect its status.
struct BackendPipeReader {
    let handle: FileHandle

    init(_ handle: FileHandle) throws {
        self.handle = handle
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    // nil: backend exited and buffered output drained; empty: still waiting.
    func readChunk(process: Process) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
        if count > 0 { return Data(bytes.prefix(count)) }
        if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if process.isRunning { return Data() }
        // Retry after observing exit so output written just before exit is kept.
        let finalCount = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
        if finalCount > 0 { return Data(bytes.prefix(finalCount)) }
        if finalCount < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return nil
    }
}

// Observe USB arrival/removal without repeatedly opening sessions on a connected phone.
final class USBDeviceObserver {
    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0
    private let changed: () -> Void

    init(changed: @escaping () -> Void) {
        self.changed = changed
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            let observer = Unmanaged<USBDeviceObserver>.fromOpaque(context).takeUnretainedValue()
            observer.drain(iterator)
            observer.changed()
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
            IOServiceMatching("IOUSBHostDevice"), callback, context, &added)
        drain(added)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
            IOServiceMatching("IOUSBHostDevice"), callback, context, &removed)
        drain(removed)
    }

    private func drain(_ iterator: io_iterator_t) {
        guard iterator != 0 else { return }
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            IOObjectRelease(service)
        }
    }

    deinit {
        if added != 0 { IOObjectRelease(added) }
        if removed != 0 { IOObjectRelease(removed) }
        if let port { IONotificationPortDestroy(port) }
    }
}

// MARK: - Models

struct DeviceInfo: Codable {
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
    var error_message: String?
}

enum CardSuffixMode: String, CaseIterable, Identifiable {
    case unchanged = "不變更"
    case custom = "自訂"
    case hidden = "隱藏"
    var id: String { rawValue }
}

struct CardItem: Identifiable, Hashable {
    let id: String
    var name: String = ""
    var logLabel: String { name.isEmpty ? id : "\(name)（\(id)）" }
    var editForegroundColor = false
    var foregroundColor: Color = .white
    var primaryAccountSuffixMode: CardSuffixMode = .unchanged
    var editPrimaryAccountSuffix: Bool { primaryAccountSuffixMode != .unchanged }
    var hasReadWalletSettings = false
    var hasValidPrimaryAccountSuffix: Bool {
        primaryAccountSuffixMode != .custom || primaryAccountSuffixDraft.range(of: "^[0-9]{4}$", options: .regularExpression) != nil
    }
    var primaryAccountSuffixUpdate: Any? {
        switch primaryAccountSuffixMode {
        case .unchanged: return nil
        case .custom: return primaryAccountSuffixDraft
        case .hidden: return NSNull()
        }
    }
    var previewPrimaryAccountSuffix: String? {
        switch primaryAccountSuffixMode {
        case .unchanged: return currentPrimaryAccountSuffix
        case .custom: return primaryAccountSuffixDraft
        case .hidden: return nil
        }
    }
    var primaryAccountSuffixDraft = ""
    var originalForegroundColor: String?
    var currentForegroundColor: String?
    var currentPrimaryAccountSuffix: String?
    var hasDatabaseChanges: Bool { editForegroundColor || editPrimaryAccountSuffix }
    var hasPendingChanges: Bool { customImageURL != nil || hasDatabaseChanges }
    var isSelected: Bool = true
    var customImageURL: URL? = nil
    var customImage: NSImage? = nil
    var appliedImage: NSImage? = nil
    var previewImage: NSImage? { customImage ?? appliedImage }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
    }
    
    static func == (lhs: CardItem, rhs: CardItem) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.isSelected == rhs.isSelected && lhs.customImageURL == rhs.customImageURL &&
        lhs.editForegroundColor == rhs.editForegroundColor && lhs.foregroundColor == rhs.foregroundColor &&
        lhs.primaryAccountSuffixMode == rhs.primaryAccountSuffixMode && lhs.hasReadWalletSettings == rhs.hasReadWalletSettings && lhs.primaryAccountSuffixDraft == rhs.primaryAccountSuffixDraft &&
        lhs.originalForegroundColor == rhs.originalForegroundColor && lhs.currentForegroundColor == rhs.currentForegroundColor &&
        lhs.currentPrimaryAccountSuffix == rhs.currentPrimaryAccountSuffix
    }
}

enum WalletColor {
    static func parse(_ value: String) -> Color? {
        if value.hasPrefix("#"), value.count == 7, let rgb = UInt32(value.dropFirst(), radix: 16) {
            return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        }
        guard value.hasPrefix("rgb"), let start = value.firstIndex(of: "("), let end = value.firstIndex(of: ")") else { return nil }
        let parts = value[value.index(after: start)..<end].split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 3, let r = parts[0], let g = parts[1], let b = parts[2], [r, g, b].allSatisfy({ (0...255).contains($0) }) else { return nil }
        return Color(red: r / 255, green: g / 255, blue: b / 255)
    }
    static func hex(_ color: Color) -> String {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case walletCards = "錢包卡片"
    case passcodeThemes = "密碼主題 (.passthm)"
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
    case applyTheme = "應用主題"
    case themeCreator = "主題編輯器"
    var id: String { rawValue }
}

enum CreatorSubMode: String, CaseIterable, Identifiable {
    case posterSlice = "海報切片（拼圖）"
    case individualKeys = "獨立按鍵"
    var id: String { rawValue }
}

enum PasscodeLanguageTarget: String, CaseIterable, Identifiable {
    case all = "所有語言（通用）"
    case uk = "烏克蘭語 (uk)"
    case ru = "俄語 (ru)"
    case en = "英語 (en)"
    case other = "其他 / 預設"
    case es = "西班牙語 (es)"
    case de = "德語 (de)"
    case fr = "法語 (fr)"
    case pl = "波蘭語 (pl)"
    case it = "意大利語 (it)"
    case pt = "葡萄牙語 (pt)"
    case tr = "土耳其語 (tr)"
    case ja = "日語 (ja)"
    case ko = "韓語 (ko)"
    case zh = "中文 (zh)"
    case ar = "阿拉伯語 (ar)"
    case he = "希伯來語 (he)"
    
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
    case both = "通用（常規 + 粗體）"
    case boldOnly = "僅粗體（快速）"
    case regularOnly = "僅常規字型（快速）"
    
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
                userInfo: [NSLocalizedDescriptionKey: "無法創建 .passthm 壓縮包（退出碼 \(process.terminationStatus)）"]
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
            print("Failed to stage temporary theme: \(error)")
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
    
    @Published var device: DeviceInfo?
    @Published var isCheckingDevice = false
    @Published var isScanningCards = false
    @Published var cards: [CardItem] = []
    
    @Published var lastFlashChangedDatabase = false
    @Published var isFlashing = false
    @Published var progress: Double = 0.0
    @Published var statusText: String = "就緒"
    @Published var logs: [String] = []
    @Published var showSuccessAlert = false
    @Published var errorMessage: String?
    
    @Published var showAddCardSheet = false
    @Published var manualHashInput = ""
    @Published var showLogs = false
    
    private var deviceObserver: USBDeviceObserver?
    private var deviceRefreshTask: Task<Void, Never>?
    private var deviceRefreshPending = false
    private var scanProcess: Process?
    private let scriptDir: String
    private let cardNamesKey = "aircard.cardNames"
    private let storageKey = "mak5er.aircard.savedCards"
    private let legacyStorageKey1 = "mak5er.savedCards"
    private let legacyStorageKey2 = "LumiCards.savedCards"
    
    nonisolated static let cardRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: "/(?:Cards|Passes/Cards)/([-A-Za-z0-9_+=]{20,44})(?:\\.pkpass|\\.cache|\\.pkcache|/|\\s|\"|'|\\)|,|$)"),
        try! NSRegularExpression(pattern: "/([-A-Za-z0-9_+=]{20,44})\\.(?:pkpass|cache|pkcache)"),
        try! NSRegularExpression(pattern: "(?<![A-Za-z0-9+/_-])([A-Za-z0-9+/_-]{27}=)(?![A-Za-z0-9+/_-])")
    ]
    
    init() {
        let cwd = FileManager.default.currentDirectoryPath
        if let resPath = Bundle.main.resourcePath, FileManager.default.fileExists(atPath: resPath + "/aircard_backend.py") {
            self.scriptDir = resPath
        } else if FileManager.default.fileExists(atPath: cwd + "/aircard_backend.py") {
            self.scriptDir = cwd
        } else {
            self.scriptDir = Bundle.main.bundleURL.deletingLastPathComponent().path
        }
        
        loadSavedCards()
        deviceObserver = USBDeviceObserver { [weak self] in
            Task { @MainActor in self?.scheduleDeviceCheck() }
        }
        checkDevice()
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
        candidates.append(FileManager.default.currentDirectoryPath + "/build/device_helper")
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
        extraPaths.append(FileManager.default.currentDirectoryPath + "/build")
        env["PATH"] = (extraPaths + [path]).joined(separator: ":")
        
        var libPaths: [String] = []
        if let res = Bundle.main.resourceURL {
            libPaths.insert(res.appendingPathComponent("lib").path, at: 0)
        }
        let curDyld = env["DYLD_LIBRARY_PATH"] ?? ""
        env["DYLD_LIBRARY_PATH"] = (libPaths + (curDyld.isEmpty ? [] : [curDyld])).joined(separator: ":")
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
    
    func loadSavedCards() {
        var loaded: [String] = []
        
        if let saved = UserDefaults.standard.stringArray(forKey: storageKey), !saved.isEmpty {
            loaded.append(contentsOf: saved)
        } else if let saved = UserDefaults.standard.stringArray(forKey: legacyStorageKey1), !saved.isEmpty {
            loaded.append(contentsOf: saved)
        } else if let saved = UserDefaults.standard.stringArray(forKey: legacyStorageKey2), !saved.isEmpty {
            loaded.append(contentsOf: saved)
        }
        
        for p in ["~/.aircard_cards.json", "~/.lumicards_cards.json"] {
            let jsonPath = NSString(string: p).expandingTildeInPath
            if let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
               let jsonHashes = try? JSONDecoder().decode([String].self, from: data) {
                for h in jsonHashes where !loaded.contains(h) {
                    loaded.append(h)
                }
            }
        }
        
        let dummyHashes = [
            "M6nDwZrkYbFlsodLgCbvyFZQ1cc=",
            "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
            "hwAtAmHKYwsQrJbT5cTNDsaxVME="
        ]
        loaded.removeAll { dummyHashes.contains($0) || ($0.contains("-") && $0.count == 36) }
        
        let names = UserDefaults.standard.dictionary(forKey: cardNamesKey) as? [String: String] ?? [:]
        self.cards = loaded.map { makeCard(id: $0, name: names[$0] ?? "") }
        log("已從本地載入 \(cards.count) 張卡片。")
    }
    
    private func appliedSkinURL(for id: String) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirCard/AppliedSkins", isDirectory: true)
        // Card hashes may contain slashes; encode the identifier as a safe filename.
        let filename = id.utf8.map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(filename + ".png")
    }

    private func makeCard(id: String, name: String = "") -> CardItem {
        var card = CardItem(id: id, name: name)
        card.appliedImage = NSImage(contentsOf: appliedSkinURL(for: id))
        card.originalForegroundColor = walletStyleKey(id).flatMap { UserDefaults.standard.string(forKey: $0) }
        return card
    }

    func rememberAppliedSkin(cardId: String, preparedURL: URL, originalURL: URL) {
        do {
            let data = try Data(contentsOf: preparedURL)
            guard let image = NSImage(data: data) else { return }
            let destination = appliedSkinURL(for: cardId)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            if let index = cards.firstIndex(where: { $0.id == cardId }) {
                cards[index].appliedImage = image
                // Keep a newer selection if the user changed the image during writing.
                if cards[index].customImageURL == originalURL {
                    cards[index].customImageURL = nil
                    cards[index].customImage = nil
                }
            }
            log("已儲存上次寫入的外觀預覽：\(cardId)")
        } catch {
            log("外觀已寫入，但本地預覽儲存失敗：\(error.localizedDescription)")
        }
    }

    func saveCards() {
        let hashes = cards.map { $0.id }
        UserDefaults.standard.set(hashes, forKey: storageKey)
        // Keep the existing hash-only file compatible with the Python backend.
        let names = cards.reduce(into: [String: String]()) { result, card in
            if !card.name.isEmpty { result[card.id] = card.name }
        }
        UserDefaults.standard.set(names, forKey: cardNamesKey)
        
        let jsonPath = NSString(string: "~/.aircard_cards.json").expandingTildeInPath
        if let data = try? JSONEncoder().encode(hashes) {
            try? data.write(to: URL(fileURLWithPath: jsonPath), options: .atomic)
        }
    }
    
    func addCardHash(_ raw: String) {
        let components = raw.components(separatedBy: CharacterSet(charactersIn: " \n\r\t,;"))
        var addedCount = 0
        for comp in components {
            let clean = comp.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if clean.count >= 16 && clean.count <= 64 && !cards.contains(where: { $0.id == clean }) {
                cards.append(makeCard(id: clean))
                addedCount += 1
                log("已新增卡片： \(clean)")
            }
        }
        if addedCount > 0 {
            saveCards()
        }
    }
    
    func renameCard(id: String, name: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        cards[index].name = cleaned
        saveCards()
        log(cleaned.isEmpty ? "已恢復卡片預設名稱：\(id)" : "卡片已重新命名為“\(cleaned)”：\(id)")
    }

    func deleteCard(id: String) {
        cards.removeAll { $0.id == id }
        saveCards()
        log("已移除卡片： \(id)")
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
            log("已為卡片設定外觀： \(cards[idx].logLabel)")
        }
    }
    
    func clearCardImage(for cardId: String) {
        if let idx = cards.firstIndex(where: { $0.id == cardId }) {
            cards[idx].customImageURL = nil
            cards[idx].customImage = nil
            log("已清除卡片外觀： \(cards[idx].logLabel)")
        }
    }
    
    // MARK: - Device Connection
    
    func scheduleDeviceCheck() {
        deviceRefreshTask?.cancel()
        deviceRefreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 700_000_000) }
            catch { return }
            guard let self else { return }
            if self.isCheckingDevice {
                self.deviceRefreshPending = true
            } else {
                self.checkDevice(automatically: true)
            }
        }
    }

    private func receiveDevice(_ dev: DeviceInfo, automatically: Bool) {
        let changedDevice = device?.udid != dev.udid
        let changedStatus = changedDevice || device?.connected != dev.connected || device?.error != dev.error || device?.error_message != dev.error_message
        device = dev
        if changedDevice {
            if isScanningCards { stopCardScanning() }
            resetPasscodeTargetsToDevice()
            for index in cards.indices {
                cards[index].originalForegroundColor = walletStyleKey(cards[index].id).flatMap { UserDefaults.standard.string(forKey: $0) }
                cards[index].currentForegroundColor = nil
                cards[index].currentPrimaryAccountSuffix = nil
                cards[index].hasReadWalletSettings = false
                cards[index].editForegroundColor = false
                cards[index].primaryAccountSuffixMode = .unchanged
            }
        }
        if !automatically || changedStatus {
            if dev.connected {
                statusText = "已連線 \(dev.name ?? "iPhone")"
                log("裝置已連線：\(dev.name ?? "iPhone")（iOS \(dev.version ?? "")）")
            } else {
                statusText = dev.error_message ?? (dev.error == "device_helper_missing"
                    ? "缺少裝置輔助工具，請重新建置 App。"
                    : "未發現 iPhone，請連線並解鎖手機。")
                log(statusText)
                if dev.error != "no_device" { showLogs = true }
            }
        }
    }

    func checkDevice(automatically: Bool = false) {
        guard !isFlashing, !isCheckingDevice else { return }
        isCheckingDevice = true
        if !automatically { statusText = "正在檢查裝置連線…" }
        let scriptDir = self.scriptDir
        Task.detached {
            let process = Process()
            process.executableURL = AppViewModel.pythonExecutableURL
            process.environment = AppViewModel.processEnvironment
            process.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
            process.arguments = ["-u", "aircard_backend.py", "--device"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                try? pipe.fileHandleForWriting.close()
                let reader = try BackendPipeReader(pipe.fileHandleForReading)
                var data = Data()
                while let chunk = try reader.readChunk(process: process) {
                    data.append(chunk)
                    if chunk.isEmpty { try await Task.sleep(nanoseconds: 200_000_000) }
                }
                process.waitUntilExit()
                // Preserve diagnostics but decode only the backend's final JSON line.
                guard let line = data.split(separator: 10).last else {
                    throw NSError(domain: "AirCard", code: 1, userInfo: [NSLocalizedDescriptionKey: "裝置輔助程式沒有輸出（exit \(process.terminationStatus)）。"])
                }
                let dev = try JSONDecoder().decode(DeviceInfo.self, from: Data(line))
                await MainActor.run { self.receiveDevice(dev, automatically: automatically) }
            } catch {
                let message = "裝置檢測失敗：\(error.localizedDescription)"
                await MainActor.run {
                    self.receiveDevice(DeviceInfo(connected: false, error: "device_detection_failed", error_message: message), automatically: automatically)
                }
            }
            await MainActor.run {
                self.isCheckingDevice = false
                if self.deviceRefreshPending {
                    self.deviceRefreshPending = false
                    self.scheduleDeviceCheck()
                }
            }
        }
    }

    // MARK: - Live Card Scanner
    
    func toggleCardScanning() {
        guard !isFlashing else { return }
        if isScanningCards {
            stopCardScanning()
        } else {
            startCardScanning()
        }
    }
    
    func startCardScanning() {
        guard !isScanningCards else { return }
        guard let deviceHelper = AppViewModel.deviceHelperExecutableURL else {
            errorMessage = "當前版本缺少裝置輔助工具。"
            log("缺少 device_helper，無法掃描。")
            return
        }
        guard let udid = device?.udid else {
            errorMessage = "尚未連線 iPhone。"
            return
        }
        isScanningCards = true
        statusText = "雙擊側邊按鈕，通過面容 ID 驗證，然後輕點卡片…"
        log("已開始掃描裝置紀錄以查找卡片…")
        
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = deviceHelper
        proc.environment = AppViewModel.processEnvironment
        proc.arguments = ["syslog", udid]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        
        self.scanProcess = proc
        
        let dummyHashes = [
            "M6nDwZrkYbFlsodLgCbvyFZQ1cc=",
            "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
            "hwAtAmHKYwsQrJbT5cTNDsaxVME="
        ]
        
        Task.detached {
            do {
                try proc.run()
                let handle = pipe.fileHandleForReading
                var buffer = Data()
                
                while proc.isRunning {
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        usleep(100000)
                        continue
                    }
                    buffer.append(chunk)
                    
                    while let newlineRange = buffer.range(of: Data([0x0A])) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                        buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)
                        
                        guard let line = String(data: lineData, encoding: .utf8) else { continue }
                        let lower = line.lowercased()
                        
                        let isWalletSubsystem = lower.contains("passd") ||
                                                lower.contains("passbook") ||
                                                lower.contains("passkit") ||
                                                lower.contains("stockholm") ||
                                                lower.contains("nanopassd") ||
                                                lower.contains("wallet") ||
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
                                              lower.contains("/cards/")
                        
                        guard isWalletContext else { continue }
                        
                        for regex in AppViewModel.cardRegexes {
                            let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
                            for m in matches {
                                if m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: line) {
                                    let candidate = String(line[r])
                                    if candidate.count == 36 && candidate.contains("-") { continue }
                                    if dummyHashes.contains(candidate) { continue }
                                    
                                    await MainActor.run {
                                        if !self.cards.contains(where: { $0.id == candidate }) {
                                            self.cards.append(self.makeCard(id: candidate))
                                            self.saveCards()
                                            self.log("發現卡片： \(candidate)")
                                            NSSound(named: "Glass")?.play()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.log("系統紀錄監控已停止： \(error.localizedDescription)")
                    self.isScanningCards = false
                }
            }
        }
    }
    
    func stopCardScanning() {
        scanProcess?.terminate()
        scanProcess = nil
        isScanningCards = false
        if statusText.contains("雙擊側邊按鈕") {
            statusText = "就緒"
        }
        saveCards()
        log("掃描已停止，卡片總數： \(cards.count).")
    }
    
    // MARK: - Skin Application
    
    private func walletStyleKey(_ cardID: String) -> String? {
        guard let udid = device?.udid else { return nil }
        return "aircard.walletOriginalColor.\(udid).\(cardID)"
    }

    private func rememberWalletResult(_ result: [String: Any], cardID: String, applied: Bool) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        let original = (result["originalColors"] as? [String: Any])?["foregroundColor"] as? String
            ?? result["foregroundColor"] as? String
        if cards[index].originalForegroundColor == nil, let original,
           WalletColor.parse(original) != nil {
            cards[index].originalForegroundColor = original
            if let key = walletStyleKey(cardID) { UserDefaults.standard.set(original, forKey: key) }
        }
        let current = (result["appliedColors"] as? [String: Any])?["foregroundColor"] as? String
            ?? result["foregroundColor"] as? String
        cards[index].currentForegroundColor = current
        cards[index].hasReadWalletSettings = true
        cards[index].currentPrimaryAccountSuffix = result["appliedPrimaryAccountSuffix"] as? String
            ?? result["primaryAccountSuffix"] as? String
        if applied {
            cards[index].editForegroundColor = false
            cards[index].primaryAccountSuffixMode = .unchanged
        }
    }

    // Drain stderr independently and parse complete UTF-8 lines, including final output.
    private func runWalletCommand(_ arguments: [String], base: Double = 0, span: Double = 1) async -> [String: Any]? {
        let directory = scriptDir
        return await Task.detached { () -> [String: Any]? in
            let process = Process()
            process.executableURL = Self.pythonExecutableURL
            process.environment = Self.processEnvironment
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.arguments = ["-u", "aircard_backend.py"] + arguments
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            errors.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                    Task { @MainActor in self.log(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }
            }
            defer { errors.fileHandleForReading.readabilityHandler = nil }
            do { try process.run() }
            catch {
                await MainActor.run { self.log("無法啟動後端：\(error.localizedDescription)") }
                return nil
            }
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            var pending = Data()
            var finalResult: [String: Any]?
            func consume(_ line: Data) async {
                guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
                if event["type"] as? String == "success" || event["ok"] as? Bool == true { finalResult = event }
                await MainActor.run {
                    if let message = event["message"] as? String ?? event["error"] as? String {
                        self.statusText = message
                        self.log(message)
                    }
                    if let step = event["step"] as? Double, let total = event["total"] as? Double, total > 0 {
                        self.progress = max(self.progress, min(base + span * step / total, 1))
                    }
                }
            }
            do {
                let reader = try BackendPipeReader(output.fileHandleForReading)
                var lastOutput = Date()
                while let chunk = try reader.readChunk(process: process) {
                    if chunk.isEmpty {
                        if Date().timeIntervalSince(lastOutput) >= 15 {
                            await MainActor.run { self.log("後端仍在執行，正在等待目前步驟回報；請保持 iPhone 連線。") }
                            lastOutput = Date()
                        }
                        try await Task.sleep(nanoseconds: 200_000_000)
                        continue
                    }
                    lastOutput = Date()
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 10) {
                        await consume(Data(pending[..<newline]))
                        pending.removeSubrange(...newline)
                    }
                }
            } catch {
                await MainActor.run { self.log("無法繼續讀取後端紀錄：\(error.localizedDescription)；正在等待後端結束。") }
                process.waitUntilExit()
                return nil
            }
            if !pending.isEmpty { await consume(pending) }
            process.waitUntilExit()
            let receivedResult = finalResult != nil
            await MainActor.run {
                if process.terminationStatus != 0 {
                    self.log("後端已結束（退出碼 \(process.terminationStatus)），本次更新未確認成功。")
                } else if !receivedResult {
                    self.log("後端已結束，但未回報完成結果，本次更新未確認成功。")
                }
            }
            return process.terminationStatus == 0 ? finalResult : nil
        }.value
    }

    func inspectWalletCard(id: String) {
        guard !isFlashing, !isCheckingDevice, let udid = device?.udid, device?.connected == true else { return }
        stopCardScanning()
        isFlashing = true
        showLogs = true
        progress = 0
        Task {
            let result = await runWalletCommand(["--inspect-wallet-db", udid, id])
            if let result {
                rememberWalletResult(result, cardID: id, applied: false)
                statusText = "已讀取卡片文字顏色與顯示末四碼。"
            } else {
                errorMessage = "讀取卡片設定失敗，請查看紀錄。"
            }
            isFlashing = false
        }
    }

    func resetPasscodeTargetsToDevice() {
        guard let device, device.connected else { return }
        passcodeLanguageTarget = .all
        passcodeBoldTarget = .both
        if let language = device.language?.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first {
            passcodeLanguageTarget = PasscodeLanguageTarget.allCases.first { $0.code == String(language) } ?? .other
        }
        if let bold = device.bold_text { passcodeBoldTarget = bold ? .boldOnly : .regularOnly }
    }

    func applySkin() {
        guard !isFlashing, !isCheckingDevice, let udid = device?.udid, device?.connected == true else {
            errorMessage = "尚未連線 iPhone。"
            return
        }
        let selected = cards.filter { $0.isSelected && $0.hasPendingChanges }
        guard !selected.isEmpty else { return }
        for card in selected where card.primaryAccountSuffixMode == .custom {
            guard card.hasValidPrimaryAccountSuffix else {
                errorMessage = "\(card.name.isEmpty ? "卡片" : card.name)的顯示末四碼必須是四位數字。"
                return
            }
        }
        stopCardScanning()
        isFlashing = true
        lastFlashChangedDatabase = false
        showLogs = true
        progress = 0
        errorMessage = nil
        Task {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("aircard-\(UUID().uuidString)", isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: work)
                isFlashing = false
            }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                // Prepare every selected image before starting a device transaction.
                var images: [(CardItem, URL)] = []
                for (index, card) in selected.enumerated() {
                    if let original = card.customImageURL {
                        let prepared = work.appendingPathComponent("\(index).png")
                        guard Self.prepareCardImage(srcURL: original, dstURL: prepared) else {
                            throw NSError(domain: "AirCard", code: 1, userInfo: [NSLocalizedDescriptionKey: "無法準備卡片圖片：\(card.logLabel)"])
                        }
                        images.append((card, prepared))
                    }
                }
                let edits = selected.filter { $0.hasDatabaseChanges }
                if !edits.isEmpty {
                    let updates: [[String: Any]] = edits.enumerated().map { index, card in
                        var update: [String: Any] = ["cardHash": card.id, "requestIndex": index]
                        if card.editForegroundColor { update["foregroundColor"] = WalletColor.hex(card.foregroundColor) }
                        if let suffix = card.primaryAccountSuffixUpdate { update["primaryAccountSuffix"] = suffix }
                        return update
                    }
                    let input = work.appendingPathComponent("wallet-updates.json")
                    try JSONSerialization.data(withJSONObject: updates).write(to: input, options: .atomic)
                    guard let result = await runWalletCommand(["--flash-wallet-db-batch", udid, input.path], span: images.isEmpty ? 1 : 0.3),
                          let results = result["cards"] as? [[String: Any]], results.count == edits.count else {
                        throw NSError(domain: "AirCard", code: 2, userInfo: [NSLocalizedDescriptionKey: "卡片設定更新失敗，請查看紀錄。"])
                    }
                    lastFlashChangedDatabase = true
                    for result in results {
                        guard let index = result["requestIndex"] as? Int, edits.indices.contains(index) else { continue }
                        rememberWalletResult(result, cardID: edits[index].id, applied: true)
                    }
                }
                let base = edits.isEmpty ? 0.0 : 0.3
                for (index, item) in images.enumerated() {
                    let (card, prepared) = item
                    log("正在寫入外觀：\(card.logLabel)")
                    let span = (1 - base) / Double(images.count)
                    guard await runWalletCommand(["--flash", udid, card.id, prepared.path], base: base + Double(index) * span, span: span) != nil else {
                        throw NSError(domain: "AirCard", code: 3, userInfo: [NSLocalizedDescriptionKey: "外觀更新失敗，已停止。\(lastFlashChangedDatabase ? "文字顏色或末四碼已更新，請重新啟動 iPhone。" : "")"])
                    }
                    if let original = card.customImageURL {
                        rememberAppliedSkin(cardId: card.id, preparedURL: prepared, originalURL: original)
                    }
                }
                progress = 1
                statusText = "完成！所選卡片已更新。"
                showSuccessAlert = true
            } catch {
                statusText = "卡片更新未完成。"
                errorMessage = error.localizedDescription
                log(error.localizedDescription)
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
                    self.statusText = "已載入密碼主題“\(name)”（\(fileCount) 個資源）"
                    self.log("已載入 .passthm：\(name) [\(detectedVersion)]，共 \(fileCount) 個圖片資源")
                }
            } else {
                await MainActor.run {
                    self.isInspectingTheme = false
                    self.errorMessage = "無法讀取 .passthm 檔案"
                }
            }
        }
    }
    
    func flashPasscodeTheme() {
        guard let theme = loadedPasscodeTheme else { return }
        guard let dev = device, dev.connected, let udid = dev.udid else {
            errorMessage = "請先連線 iPhone，並在手機上信任此電腦。"
            return
        }
        
        isFlashing = true
        showLogs = true
        progress = 0.0
        statusText = "正在開始寫入密碼主題…"
        log("正在向裝置寫入密碼主題“\(theme.name)”…")
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
                if exitCode == 0 && self.errorMessage == nil {
                    self.progress = 1.0
                    self.statusText = "密碼主題已成功應用！"
                    self.showSuccessAlert = true
                    self.log("密碼主題“\(theme.name)”已成功寫入！")
                } else {
                    let err = self.errorMessage ?? "寫入失敗（退出碼 \(exitCode)）"
                    self.statusText = err
                    self.log("錯誤： \(err)")
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
        statusText = "已載入海報圖片 · 可以調整取景並切片"
    }
    
    func setIndividualKey(digit: String, image: NSImage) {
        creatorRawIndividualImages[digit] = image
        creatorIndividualOffsets[digit] = .zero
        creatorIndividualZooms[digit] = 1.0
        selectedKeyDigit = digit
        updateIndividualKey(digit: digit)
        statusText = "已更新按鍵 \(digit) · 拖動調整位置或使用滑塊縮放"
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
        statusText = "已清除按鍵 \(digit)"
    }
    
    func clearAllIndividualKeys() {
        creatorCustomKeys.removeAll()
        creatorRawIndividualImages.removeAll()
        creatorIndividualOffsets.removeAll()
        creatorIndividualZooms.removeAll()
        selectedKeyDigit = nil
        statusText = "已清空所有自訂按鍵"
    }
    
    func adoptPosterSlicesToIndividualKeys() {
        for (k, v) in creatorSlicedKeys {
            creatorCustomKeys[k] = v
            creatorRawIndividualImages[k] = v
            creatorIndividualOffsets[k] = .zero
            creatorIndividualZooms[k] = 1.0
        }
        statusText = "已使用海報切片填充獨立按鍵"
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
        statusText = "已將“\(theme.name)”載入到編輯器（\(theme.keysPreview.count) 個按鍵可編輯）"
        log("已將主題“\(theme.name)”匯入編輯器")
    }
    
    func clearCreator() {
        creatorPosterImage = nil
        creatorPosterZoom = 1.0
        creatorPosterOffset = .zero
        creatorSlicedKeys.removeAll()
        clearAllIndividualKeys()
        statusText = "主題編輯器已重置"
    }
    
    func flashCreatedTheme() {
        let keys = effectiveCreatorKeys
        guard !keys.isEmpty else {
            errorMessage = "請先新增至少一個按鍵圖示或匯入海報圖片。"
            return
        }
        guard let dev = device, dev.connected, dev.udid != nil else {
            errorMessage = "請先連線 iPhone，並在手機上信任此電腦。"
            return
        }
        
        guard let stagedURL = PasscodeThemeExporter.stageTemporaryTheme(
            keys: keys,
            language: passcodeLanguageTarget,
            boldMode: passcodeBoldTarget
        ) else {
            errorMessage = "主題打包失敗，無法寫入。"
            return
        }
        
        let themeInfo = PasscodeThemeInfo(
            name: "自訂主題",
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
    let onPickImage: () -> Void
    let onClearImage: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void
    let onInspect: () -> Void
    var canInspect: Bool = false
    
    @State private var isHovered = false
    @State private var isTargeted = false
    @State private var copied = false
    @State private var showRename = false
    @State private var draftName = ""
    
    var body: some View {
        VStack(spacing: 10) {
            // Card Mockup
            ZStack {
                if let img = card.previewImage {
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
                        if card.customImage != nil {
                        Button(action: onClearImage) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.white.opacity(0.9))
                                .background(Circle().fill(Color.black.opacity(0.55)))
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                        .help("取消待寫入外觀")
                        }
                        
                        // Hover overlay: Change Skin
                        if isHovered {
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    Label("更換外觀", systemImage: "photo.badge.arrow.forward")
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
                            
                            Text(isTargeted ? "將圖片拖到此處" : "設定卡片外觀")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                            
                            Text("點選選擇或拖曳加入圖片")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(width: 290, height: 182)
                }
            }
            .frame(width: 290, height: 182)
            .overlay(alignment: .bottomLeading) {
                if let suffix = card.previewPrimaryAccountSuffix {
                    Text("•••• " + suffix)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundColor(card.editForegroundColor ? card.foregroundColor : (card.currentForegroundColor.flatMap(WalletColor.parse) ?? .white))
                        .padding(18)
                        .allowsHitTesting(false)
                }
            }
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
                        if let url = fileURL, let img = NSImage(contentsOf: url) {
                            Task { @MainActor in
                                card.customImageURL = url
                                card.customImage = img
                                card.isSelected = true
                            }
                        }
                    }
                    return true
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                        if let url = item as? URL, let img = NSImage(contentsOf: url) {
                            Task { @MainActor in
                                card.customImageURL = url
                                card.customImage = img
                                card.isSelected = true
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
                                card.customImageURL = tempURL
                                card.customImage = img
                                card.isSelected = true
                            }
                        }
                    }
                    return true
                }
                return false
            }
            
            HStack(spacing: 6) {
                Text(card.name.isEmpty ? "卡片 \(cardIndex + 1)" : card.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(card.name.isEmpty ? "卡片 \(cardIndex + 1)" : card.name)
                Spacer(minLength: 4)
                Button {
                    draftName = card.name
                    showRename = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .help("重新命名卡片")
                .accessibilityLabel("重新命名卡片")
            }
            .padding(.horizontal, 4)

            if card.previewImage != nil {
                Text(card.customImage != nil ? "待寫入的外觀" : "上次寫入的外觀")
                    .font(.caption2)
                    .foregroundColor(card.customImage != nil ? .orange : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("卡號顯示設定").font(.caption).fontWeight(.semibold)
                    Spacer()
                    Button("讀取當前設定", action: onInspect).disabled(!canInspect)
                        .font(.caption2)
                }
                Toggle("修改文字顏色", isOn: $card.editForegroundColor).font(.caption)
                if card.editForegroundColor {
                    HStack {
                        ColorPicker("顏色", selection: $card.foregroundColor, supportsOpacity: false)
                        Text(WalletColor.hex(card.foregroundColor)).font(.system(size: 10, design: .monospaced))
                    }
                    Text("改卡號顏色後需重新啟動 iPhone，否則 Wallet 可能暫時不顯示卡片。若重開機後仍空白，開啟 Wallet 等約一分鐘，再從多工畫面關閉 Wallet 並重新開啟。")
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let original = card.originalForegroundColor, let color = WalletColor.parse(original) {
                    Button("恢復原始文字顏色") {
                        card.foregroundColor = color
                        card.editForegroundColor = true
                    }.font(.caption2)
                }
                Picker("末四碼", selection: $card.primaryAccountSuffixMode) {
                    ForEach(CardSuffixMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
                if card.primaryAccountSuffixMode == .custom {
                    TextField("四位數字", text: $card.primaryAccountSuffixDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                if card.primaryAccountSuffixMode == .hidden {
                    Text("清空 Wallet 的末四碼顯示欄位，寫入後請重新啟動 iPhone。")
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if card.hasReadWalletSettings {
                    Text("目前末四碼：\(card.currentPrimaryAccountSuffix ?? "未設定")")
                        .font(.caption2).foregroundColor(.secondary)
                }
                if let current = card.currentForegroundColor {
                    Text("當前顏色：\(current)").font(.caption2).foregroundColor(.secondary)
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(8)

            // Bottom Info & Controls
            HStack(spacing: 8) {
                Toggle("", isOn: $card.isSelected)
                    .labelsHidden()
                    .help("選中以寫入")
                
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
                    .help(copied ? "已複製！" : "複製完整雜湊值")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                
                Spacer()
                
                // Status badge
                if card.customImage != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 12))
                        .help("外觀已設定，可以寫入")
                }
                
                // Delete button
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("從清單移除")
            }
            .padding(.horizontal, 4)
        }
        .alert("重新命名卡片", isPresented: $showRename) {
            TextField("例如：招商銀行儲蓄卡", text: $draftName)
            Button("取消", role: .cancel) {}
            Button("儲存") { onRename(draftName) }
        } message: {
            Text("名稱僅用於本地識別，不會修改手機中的卡片。留空可恢復預設名稱。")
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

// MARK: - Main UI View

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @State private var showCredits = false
    @State private var dragOffsetStart: CGPoint = .zero
    @State private var dragKeyStartOffsets: [String: CGPoint] = [:]
    @State private var isTargetedPoster = false
    @State private var isTargetedTheme = false
    
    private var readyToFlashCount: Int {
        vm.cards.filter { $0.isSelected && $0.hasPendingChanges }.count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. Top Header Bar
            headerView
                .disabled(vm.isFlashing)
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
            .disabled(vm.isFlashing)
            .frame(height: 48)
            .padding(.horizontal, 20)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // 3. Live Scanner Notice Banner (if active)
            if vm.selectedTab == .walletCards && vm.isScanningCards {
                scanningNoticeBanner
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
                            ForEach(Array(vm.cards.indices), id: \.self) { idx in
                                WalletCardView(
                                    card: $vm.cards[idx],
                                    cardIndex: idx,
                                    onPickImage: { openCardImagePicker(for: vm.cards[idx].id) },
                                    onClearImage: { vm.clearCardImage(for: vm.cards[idx].id) },
                                    onDelete: { vm.deleteCard(id: vm.cards[idx].id) },
                                    onRename: { vm.renameCard(id: vm.cards[idx].id, name: $0) },
                                    onInspect: { vm.inspectWalletCard(id: vm.cards[idx].id) },
                                    canInspect: vm.device?.connected == true && !vm.isCheckingDevice

                                )
                                .disabled(vm.isFlashing)
                            }
                        }
                        .padding(20)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                passcodeThemeWorkspaceView
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
        .alert("操作成功", isPresented: $vm.showSuccessAlert) {
            Button("確定") {}
        } message: {
            if vm.selectedTab == .passcodeThemes {
                Text("密碼主題已應用！\n\n鎖定 iPhone（或重新啟動）即可查看新的密碼鍵盤。")
            } else {
                Text(vm.lastFlashChangedDatabase ? "卡片設定已更新！\n\n請重新啟動 iPhone，使文字顏色與顯示末四碼生效。\n\nWallet 可能暫時不顯示卡片；若重開機後仍空白，開啟 Wallet 等約一分鐘，再從多工畫面關閉 Wallet 並重新開啟。" : "所有選中卡片的外觀均已應用！\n\n請重新打開錢包 App（或重新啟動手機）查看新外觀。")
            }
        }
        .sheet(isPresented: $showCredits) {
            creditsSheet
        }
        .sheet(isPresented: $vm.showAddCardSheet) {
            addCardSheet
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            vm.scheduleDeviceCheck()
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            // Retry after the user unlocks/trusts a newly attached phone.
            if vm.device?.connected != true { vm.checkDevice(automatically: true) }
        }
        .onChange(of: vm.isFlashing) { _, flashing in
            if !flashing { vm.scheduleDeviceCheck() }
        }
        .onChange(of: vm.selectedTab) { _, newTab in
            if newTab == .passcodeThemes && vm.isScanningCards {
                vm.stopCardScanning()
            }
            if vm.statusText.contains("雙擊側邊按鈕") {
                vm.statusText = "就緒"
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
                    Text("Aircard")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("v1.2.4.114514")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .clipShape(Capsule())
                }
                Text("錢包卡片外觀與鎖定畫面密碼主題")
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
            
            // Device Status Capsule
            HStack(spacing: 8) {
                Circle()
                    .fill(vm.device?.connected == true ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                
                if let dev = vm.device, dev.connected {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(dev.name ?? "iPhone")
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Text("\(dev.product ?? "") · iOS \(dev.version ?? "")")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("未連線 iPhone")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Button(action: { vm.checkDevice() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .disabled(vm.isCheckingDevice || vm.isFlashing)
                .help("刷新裝置連線")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(height: 32)
            .background(Color(NSColor.windowBackgroundColor))
            .cornerRadius(16)
            
            Button(action: { showCredits = true }) {
                Label("作者與致謝", systemImage: "heart.fill")
                    .foregroundColor(.pink)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .controlSize(.regular)
        .frame(height: 54)
    }
    
    private var toolbarView: some View {
        HStack(spacing: 12) {
            // Live Scanner Toggle
            Button(action: { vm.toggleCardScanning() }) {
                HStack(spacing: 6) {
                    if vm.isScanningCards {
                        ProgressView()
                            .scaleEffect(0.65)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "wave.3.forward.circle.fill")
                            .frame(width: 16, height: 16)
                    }
                    Text(vm.isScanningCards ? "停止掃描" : "掃描卡片")
                        .fontWeight(.semibold)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.isScanningCards ? .red : .blue)
            .controlSize(.regular)
            .disabled(vm.device?.connected != true)
            
            Button(action: { vm.showAddCardSheet = true }) {
                Label("手動新增", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            
            if !vm.cards.isEmpty {
                Button(action: openBulkImagePicker) {
                    Label("批量設定外觀…", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("為所有選中卡片設定同一外觀")
            }
            
            Spacer()
            
            if !vm.cards.isEmpty {
                HStack(spacing: 8) {
                    Button("全選") {
                        for idx in vm.cards.indices { vm.cards[idx].isSelected = true }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    
                    Text("·").foregroundColor(.secondary)
                    
                    Button("取消全選") {
                        for idx in vm.cards.indices { vm.cards[idx].isSelected = false }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    
                    Text("·").foregroundColor(.secondary)
                    
                    Button("全部清空") {
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
                Text("正在掃描卡片")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
                Text("雙擊側邊按鈕打開 Apple Pay，通過面容 ID 驗證後，輕點卡片。")
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
            
            Text("尚未發現卡片")
                .font(.title3)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text("1.")
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                    Text("點選上方工具欄中的**掃描卡片**。")
                }
                HStack(alignment: .top, spacing: 10) {
                    Text("2.")
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                    Text("在 iPhone 上**雙擊側邊按鈕**打開 Apple Pay，通過**面容 ID** 驗證，然後**輕點卡片**。")
                }
                HStack(alignment: .top, spacing: 10) {
                    Text("3.")
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                    Text("檢測到的卡片將自動顯示在這裡。")
                }
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            .frame(maxWidth: 460)
            .padding(20)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            
            HStack(spacing: 12) {
                Button(action: { vm.startCardScanning() }) {
                    Label("開始掃描", systemImage: "wave.3.forward.circle.fill")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(vm.device?.connected != true)
                
                Button("手動新增卡片雜湊值") {
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
                    Label("選擇 .passthm 檔案…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.regular)
            } else {
                Button(action: { openPosterPicker() }) {
                    Label(vm.creatorPosterImage == nil ? "選擇海報…" : "更換海報…", systemImage: "photo")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.regular)
                
                Button(action: { openSavePasscodeThemePanel() }) {
                    Label("匯出 .passthm…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(vm.effectiveCreatorKeys.isEmpty)
            }
            
            Spacer()
            
            // Target Version Picker
            HStack(spacing: 6) {
                Text("目標版本：")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $vm.targetTelephonyVersion) {
                    Text("TelephonyUI-10 (iOS 18+)").tag("TelephonyUI-10")
                    Text("TelephonyUI-9 (iOS 16–17)").tag("TelephonyUI-9")
                    Text("TelephonyUI-8 (iOS 14–15)").tag("TelephonyUI-8")
                    Text("通用（8、9、10）").tag("all")
                }
                .pickerStyle(.menu)
                .controlSize(.regular)
                .frame(width: 205)
            }
            
            Text("·")
                .foregroundColor(.secondary)
            
            if vm.passcodeTabMode == .applyTheme {
                Button("清除主題") {
                    vm.loadedPasscodeTheme = nil
                }
                .buttonStyle(.link)
                .font(.caption)
                .foregroundColor(.red)
                .disabled(vm.loadedPasscodeTheme == nil)
            } else {
                Button("全部清空") {
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
                    Text("鎖定畫面密碼鍵盤預覽")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Spacer()
                    if vm.loadedPasscodeTheme != nil {
                        Text("已載入自訂主題")
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
            Text("密碼主題檔案")
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
                    
                    Text("已載入 \(theme.fileCount) 個圖片資源 · 可以寫入 iPhone")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 8) {
                        Button(action: { vm.editLoadedThemeInCreator() }) {
                            Label("在編輯器中修改", systemImage: "pencil.and.outline")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .controlSize(.regular)
                        
                        Button("更換…") {
                            openPasscodeThemePicker()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        
                        Button("清空") {
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
                    
                    Text("將 .passthm 檔案拖到此處")
                        .font(.caption)
                        .fontWeight(.semibold)
                    
                    Text("支持 Cowabunga 或 Nugget 的 .passthm、.passtheme 和 .zip 主題包")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                    
                    Button("選擇檔案…") {
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
                    Text("iPhone 鎖定畫面交互預覽")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Spacer()
                    if vm.creatorSubMode == .posterSlice && vm.creatorPosterImage != nil {
                        Text("拖動鍵盤調整位置 · 使用滑塊縮放")
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
                    Text("海報圖片")
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
                                Text("已載入圖片")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                HStack(spacing: 8) {
                                    Button("更換…") {
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
                            
                            Text("將海報或桌布拖到此處")
                                .font(.caption)
                                .fontWeight(.medium)
                            
                            Button("選擇圖片…") {
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
                    Text("切片樣式")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    Picker("", selection: $vm.creatorMaskToCircles) {
                        Text("無縫海報").tag(false)
                        Text("圓形按鍵").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: vm.creatorMaskToCircles) { _, _ in
                        vm.updatePosterSlicing()
                    }
                    
                    Text(vm.creatorMaskToCircles ? "將圖片裁剪為獨立的圓形按鍵圖示。" : "圖片在鍵盤按鍵間連續顯示，不進行圓形裁剪（Adobe Dog 風格）。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Divider()
                
                // 3. Framing & Zoom Section
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("縮放與取景")
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
                            Text("縮放")
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
                        Text("在鍵盤預覽中拖動以調整位置")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                // Individual Keys Mode Controls
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("獨立按鍵")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Spacer()
                        if let sel = vm.selectedKeyDigit {
                            Button("取消選擇按鍵 \(sel)") {
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
                                Label("按鍵 \(selDigit) 取景", systemImage: "crop")
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
                                Text("在預覽中拖動按鍵 \(selDigit) 以調整位置")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            HStack(spacing: 8) {
                                Button("更換圖片…") {
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
                    
                    Text("點選任意按鍵以選中，然後平移圖片、調整縮放或拖曳加入檔案。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                        Text("已設定 \(vm.creatorCustomKeys.count) / 10 個按鍵")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    
                    HStack(spacing: 8) {
                        if !vm.creatorSlicedKeys.isEmpty {
                            Button("使用海報填充") {
                                vm.adoptPosterSlicesToIndividualKeys()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        }
                        
                        Button("清空所有按鍵") {
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
                Button("更換按鍵 \(btn.digit)…") {
                    openIndividualKeyPicker(for: btn.digit)
                }
                if customIndividualImage != nil {
                    Button("重置位置與縮放") {
                        vm.creatorIndividualOffsets[btn.digit] = .zero
                        vm.creatorIndividualZooms[btn.digit] = 1.0
                        dragKeyStartOffsets[btn.digit] = .zero
                        vm.updateIndividualKey(digit: btn.digit)
                    }
                    Button("清除按鍵 \(btn.digit)") {
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
                    
                    Text("輸入密碼")
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
                    Text("緊急情況")
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
                Text("寫入與語言設定")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Spacer()
            }
            
            Button("使用已連線 iPhone 的語言與字型") { vm.resetPasscodeTargetsToDevice() }
                .font(.caption2)
                .disabled(vm.device?.connected != true)

            // 1. Language Target Selector
            VStack(alignment: .leading, spacing: 4) {
                Text("手機系統語言：")
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
                Text("字型粗細 / 樣式：")
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
                    Text("通用模式會寫入約 600 個檔案，覆蓋所有語言和粗體樣式。選擇手機使用的具體語言可顯著縮短寫入時間。")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("快速模式：僅寫入\(vm.passcodeLanguageTarget.rawValue)，字型為\(vm.passcodeBoldTarget.rawValue)。")
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
                Text("執行紀錄")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(vm.logs.joined(separator: "\n"), forType: .string)
                } label: {
                    Label("複製全部", systemImage: "doc.on.doc")
                }
                .buttonStyle(.link)
                .font(.caption2)
                .disabled(vm.logs.isEmpty)
                .help("複製完整執行紀錄")
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
                                .textSelection(.enabled)
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
                                Text("主題編輯器 · 已設定 \(count) / 10 個按鍵 · 目標：\(targetInfo)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            } else {
                                Text("主題編輯器 · 匯入海報或將圖示拖到按鍵上")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        } else if let theme = vm.loadedPasscodeTheme {
                            let targetInfo = "\(vm.targetTelephonyVersion) · \(vm.passcodeLanguageTarget.code.uppercased()) · \(vm.passcodeBoldTarget.code)"
                            Text("已載入 \(theme.fileCount) 個源資源 · 目標：\(targetInfo)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        } else {
                            Text("尚未載入 .passthm · 請選擇要寫入的主題包")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    } else if !vm.cards.isEmpty {
                        Text("已選擇 \(vm.cards.filter { $0.isSelected }.count) / \(vm.cards.count) 張卡片 · \(readyToFlashCount) 張可以寫入")
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
                        Text("紀錄")
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
                                Text(vm.isFlashing ? "正在寫入密碼主題…" : "寫入 iPhone")
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
                                Text(vm.isFlashing ? "正在寫入密碼主題…" : "寫入密碼主題")
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
                            Text(vm.isFlashing ? "正在寫入卡片…" : (readyToFlashCount > 0 ? "更新卡片（\(readyToFlashCount) 張）" : "更新卡片"))
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.regular)
                    .disabled(readyToFlashCount == 0 || vm.isFlashing || vm.isCheckingDevice || vm.device?.connected != true)
                }
            }
            
            // Subtle Footer Credits
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Text("作者")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Link("@mak5er", destination: URL(string: "https://github.com/mak5er")!)
                        .font(.system(size: 10))
                    Text("&")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Link("@Lumid-Off", destination: URL(string: "https://github.com/Lumid-Off")!)
                        .font(.system(size: 10))
                    Text("&")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Link("wizzer", destination: URL(string: "https://wizzer.cn")!)
                        .font(.system(size: 10))
                    Text("&").font(.system(size: 10)).foregroundColor(.secondary)
                    Link("XiaoSha", destination: URL(string: "https://github.com/XiaoSha-0711/AirCard")!).font(.system(size: 10))
                }
            }
        }
    }
    
    // MARK: - Sheets & Pickers
    
    private var creditsSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "creditcard.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)
            
            Text("Aircard")
                .font(.title2)
                .fontWeight(.bold)
            Text("v1.2.4.114514").font(.caption).foregroundColor(.secondary)
            
            Text("適用於 iOS 18+ 的錢包卡片外觀與密碼主題")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundColor(.blue)
                    Text("開發者：")
                        .fontWeight(.medium)
                    Link("@mak5er", destination: URL(string: "https://github.com/mak5er")!)
                    Text("·")
                        .foregroundColor(.secondary)
                    Link("Twitter / X", destination: URL(string: "https://x.com/mak5er")!)
                }
                
                HStack {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundColor(.blue)
                    Text("開發者：")
                        .fontWeight(.medium)
                    Link("@Lumid-Off", destination: URL(string: "https://github.com/Lumid-Off")!)
                    Text("·")
                        .foregroundColor(.secondary)
                    Link("Twitter / X", destination: URL(string: "https://x.com/LumidOff")!)
                }
                
                HStack {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundColor(.blue)
                    Text("開發者：")
                        .fontWeight(.medium)
                    Link("wizzer", destination: URL(string: "https://wizzer.cn")!)
                }

                HStack {
                    Image(systemName: "person.crop.circle.fill").foregroundColor(.blue)
                    Text("開發者：").fontWeight(.medium)
                    Link("XiaoSha", destination: URL(string: "https://github.com/XiaoSha-0711/AirCard")!)
                }

                HStack {
                    Image(systemName: "bolt.shield.fill")
                        .foregroundColor(.orange)
                    Text("核心技術：")
                        .fontWeight(.medium)
                    Text("airlift（AirTraffic 同步沙盒逃逸）")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(.purple)
                    Text("密碼主題：")
                        .fontWeight(.medium)
                    Text(".passthm 標準（Cowabunga / Nugget）")
                        .foregroundColor(.secondary)
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            
            Divider()
            
            Button("關閉") {
                showCredits = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(24)
        .frame(width: 420)
    }
    
    private var addCardSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("手動新增卡片雜湊值")
                .font(.headline)
            Text("貼上一個或多個卡片雜湊值（使用空格、逗號或換行分隔）：")
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
                
                Button("新增到清單") {
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
        panel.message = "為卡片 \(cardId.prefix(12)) 選擇自訂外觀…"
        if panel.runModal() == .OK, let url = panel.url {
            vm.setCardImage(for: cardId, url: url)
        }
    }
    
    private func openBulkImagePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "為所有選中卡片選擇外觀…"
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
        panel.message = "選擇 .passthm 密碼主題包…"
        if panel.runModal() == .OK, let url = panel.url {
            vm.inspectPasscodeTheme(url: url)
        }
    }
    
    private func openPosterPicker() {
        let panel = NSOpenPanel()
        panel.title = "選擇海報圖片"
        panel.message = "選擇桌布或照片，用於生成密碼鍵盤切片…"
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
        panel.title = "選擇按鍵 \(digit) 的圖示"
        panel.message = "為按鍵 \(digit) 選擇圖示或圖片…"
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
            vm.errorMessage = "請先設定至少一個按鍵再匯出。"
            return
        }
        
        let panel = NSSavePanel()
        panel.title = "儲存密碼主題"
        panel.prompt = "匯出"
        panel.nameFieldStringValue = "CustomTheme.passthm"
        panel.allowedContentTypes = [UTType(filenameExtension: "passthm") ?? .data]
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try PasscodeThemeExporter.exportTheme(keys: keys, targetURL: url)
                vm.statusText = "主題已匯出至 \(url.lastPathComponent)"
                vm.log("已匯出 .passthm 至 \(url.path)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                vm.errorMessage = "主題匯出失敗：\(error.localizedDescription)"
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

struct StartupDisclaimerGate: View {
    @State private var accepted = false

    var body: some View {
        if accepted {
            ContentView()
        } else {
            VStack(alignment: .leading, spacing: 18) {
                Text("免責聲明").font(.title.bold())
                Text("使用 Aircard 前，請閱讀以下說明。")
                    .foregroundColor(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Aircard 是非官方第三方工具，與 Apple、Apple Wallet、發卡銀行及支付服務提供者沒有隸屬、合作或背書關係。本自訂版本保留原作者署名與 MIT 授權。")
                        Text("本工具會修改 Wallet 外觀及相關資料庫。即使只是準備或讀取資料，也可能暫時搬移檔案並嘗試還原。連線中斷、系統差異或程式錯誤，可能導致卡片無法顯示、資料遺失或需要重新設定卡片。請事先備份，僅在你擁有或已取得授權的裝置上使用。")
                        Text("變更外觀、文字顏色或顯示末四碼，不會變更銀行的實際卡號、帳戶、餘額或付款權限。請勿用於冒充、詐欺或其他未經授權的用途。")
                        Text("修改文字顏色或顯示末四碼後需重新啟動 iPhone。若更新或還原失敗，請停止重試並保留紀錄與復原檔。重新啟動手機或 Wallet 不保證恢復所有資料。")
                        Text("紀錄與復原檔可能包含裝置、卡片及帳戶敏感資訊，請勿公開上傳完整資料。")
                        Text("本軟體依 MIT 授權以「現狀」提供，不保證相容性、更新成功或資料恢復。責任限制以原授權及適用法律為準，不排除依法不得排除的責任。")
                    }
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.trailing, 8)
                }
                Divider()
                HStack {
                    Button("離開") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("我已閱讀並了解，繼續") { accepted = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(28)
            .frame(width: 620, height: 560)
        }
    }
}

@main
struct AirCardApp: App {
    var body: some Scene {
        WindowGroup {
            StartupDisclaimerGate()
                .environment(\.locale, Locale(identifier: "zh-Hant-TW"))
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
