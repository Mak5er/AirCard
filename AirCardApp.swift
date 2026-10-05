import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit
import Darwin

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
        return "Apple Device"
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
            return shortUDID.isEmpty ? "\(title) (Locked/Unpaired)" : "Device [...\(shortUDID)] (Locked/Unpaired)"
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
    case walletCards = "Apple Wallet"
    case passcodeThemes = "Passcode (.passthm)"
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
    case applyTheme = "Apply .passthm"
    case themeCreator = "Theme Creator"
    var id: String { rawValue }
}

enum CreatorSubMode: String, CaseIterable, Identifiable {
    case posterSlice = "Poster Slice (Puzzle)"
    case individualKeys = "Individual Keys"
    var id: String { rawValue }
}

enum PasscodeLanguageTarget: String, CaseIterable, Identifiable {
    case all = "All Languages (Universal)"
    case uk = "Ukrainian (uk)"
    case ru = "Russian (ru)"
    case en = "English (en)"
    case other = "Other / Fallback"
    case es = "Spanish (es)"
    case de = "German (de)"
    case fr = "French (fr)"
    case pl = "Polish (pl)"
    case it = "Italian (it)"
    case pt = "Portuguese (pt)"
    case tr = "Turkish (tr)"
    case ja = "Japanese (ja)"
    case ko = "Korean (ko)"
    case zh = "Chinese (zh)"
    case ar = "Arabic (ar)"
    case he = "Hebrew (he)"
    
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
    case both = "Universal (Regular + Bold)"
    case boldOnly = "Bold Text Only (Fast)"
    case regularOnly = "Regular Font Only (Fast)"
    
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
                userInfo: [NSLocalizedDescriptionKey: "Failed to create .passthm zip archive (exit code \(process.terminationStatus))"]
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
    @Published var scannerMessage = "Open Wallet and scan cards to verify this iPhone's saved entries."
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
    @Published private(set) var downloadingCardIDs: Set<String> = []
    var isDownloadingCardArtwork: Bool { !downloadingCardIDs.isEmpty }
    @Published private(set) var isCancellingArtworkDownload = false
    private var artworkDownloadProcess: Process?
    /// Cards whose pass bundle names a remote card-artwork asset on the iPhone.
    /// Only these can download their original card artwork, so only they get a button.
    @Published private(set) var remoteArtworkCardIDs: Set<String> = []
    /// Device associated with the cached lookup link.
    private var artworkLookupDeviceID: String?
    private var isProbingRemoteArtwork = false
    private var pendingRemoteArtworkProbe = false
    private var remoteArtworkProbeFailures = 0
    /// Coalesces the probe requests a scan produces (one per detected card).
    private var remoteArtworkProbeDebounce: Task<Void, Never>?
    @Published var progress: Double = 0.0
    @Published var statusText: String = "Ready"
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
        log("Loaded \(cards.count) saved card(s); \(confirmedCardIDs.count) previously scanned on this iPhone.")
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
        remoteArtworkCardIDs = []
        loadSavedCards()
        saveCards()
        if udid != nil { scheduleRemoteArtworkProbe(after: 0) }
    }

    /// Drops the read-only lookup symlink this app keeps in the phone's Media
    /// folder, so switching iPhones does not leave one behind per device.
    private func releaseArtworkLookupLink(udid: String) {
        let scriptDir = self.scriptDir
        Task.detached {
            let result = AppViewModel.runArtworkCommand(["--release-artwork-link", udid], scriptDir: scriptDir)
            if !result.ok {
                await MainActor.run {
                    self.log("Artwork link cleanup failed: \(result.failure)")
                }
            }
        }
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
                catalog.warnings = ["Could not read Wallet metadata. Scanning still works. Use Read Cache to retry."]
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
        scannerMessage = "Detected \(currentScanIDs.count) distinct card(s) this scan. Open any missing card in Wallet to check it."
        if newlySeen { scheduleRemoteArtworkProbe() }
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
        scannerMessage = "Verified \(currentVerifiedCardIDs.count) card(s) from this iPhone's current Wallet activity."
        scheduleRemoteArtworkProbe()
    }

    @discardableResult
    func recordActivatedPaymentCard(_ activationID: String, refreshIfNeeded: Bool = true) -> Bool {
        let normalizedID = activationID.uppercased()
        guard let card = walletCatalog.payment(forActivationID: normalizedID) else {
            pendingActivationIDs.insert(normalizedID)
            scannerMessage = isReadingWalletCache
                ? "Payment card activated. Waiting for Wallet metadata to finish loading…"
                : "A payment card was activated, but its ID is not available in this Mac's Wallet cache. Use Read Cache and try again."
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
        scannerMessage = "Detected active card: \(card.name). Open the next card when ready."
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
            scannerMessage = "Matched \(walletCatalog.payments.count) payment card(s) to this iPhone. Open membership cards individually if any are missing."
            log("Added \(missing.count) payment card(s) from the device-matched Wallet cache.")
        }
    }

    func addCardHash(_ raw: String) {
        guard !isDownloadingCardArtwork else { return }
        let components = raw.components(separatedBy: CharacterSet(charactersIn: " \n\r\t,;"))
        var addedCount = 0
        for comp in components {
            let clean = comp.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if clean.count >= 16 && clean.count <= 64 && !cards.contains(where: { $0.id == clean }) {
                cards.append(CardItem(id: clean, isSelected: true, displayName: walletCatalog.name(for: clean), confirmed: true))
                currentPreloadedIDs.insert(clean)
                addedCount += 1
                log("Added card: \(clean)")
            }
        }
        if addedCount > 0 {
            saveCards()
            scannerMessage = "Added \(addedCount) card ID(s) ready for skinning and flashing."
        }
    }
    
    func deleteCard(id: String) {
        guard !isDownloadingCardArtwork else { return }
        cards.removeAll { $0.id == id }
        saveCards()
        log("Removed card: \(id)")
    }
    
    func clearAllCards() {
        guard !isDownloadingCardArtwork else { return }
        cards.removeAll()
        saveCards()
        log("Cleared all cards.")
    }
    
    func setCardImage(for cardId: String, url: URL) {
        guard !isDownloadingCardArtwork else { return }
        if let idx = cards.firstIndex(where: { $0.id == cardId }) {
            cards[idx].customImageURL = url
            cards[idx].customImage = NSImage(contentsOf: url)
            cards[idx].isSelected = true
            log("Assigned custom skin to card: \(cardId.prefix(12))...")
        }
    }
    
    func clearCardImage(for cardId: String) {
        guard !isDownloadingCardArtwork else { return }
        if let idx = cards.firstIndex(where: { $0.id == cardId }) {
            cards[idx].customImageURL = nil
            cards[idx].customImage = nil
            log("Cleared custom skin for: \(cardId.prefix(12))...")
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
        guard !isDownloadingCardArtwork else { return }
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

        self.statusText = "Selected \(dev.displayName)"
        self.log("Switched active device to: \(dev.displayName) (\(dev.product ?? ""), iOS \(dev.version ?? ""))")
        self.applyDevicePreferences(from: dev)

        if let udid = dev.udid {
            checkDevice(preferredUDID: udid)
        }
    }

    func checkDevice(preferredUDID: String? = nil) {
        guard !isCheckingDevice, !isFlashing, !isDownloadingCardArtwork else { return }
        isCheckingDevice = true
        statusText = "Checking connected devices..."
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
                            self.statusText = "Connected to \(activeDev.name ?? "iPhone")"
                            self.log("Device connected: \(activeDev.name ?? "iPhone") (\(activeDev.product ?? ""), iOS \(activeDev.version ?? "")) [Total: \(allDevs.count)]")
                            self.applyDevicePreferences(from: activeDev)
                        } else if let first = allDevs.first(where: { $0.isPaired }) ?? allDevs.first {
                            self.activateCardDevice(first.udid)
                            self.device = first
                            self.refreshWalletCatalog()
                            self.selectedDeviceUDID = first.udid
                            if let u = first.udid {
                                UserDefaults.standard.set(u, forKey: "mak5er.aircard.selectedUDID")
                            }
                            self.statusText = "Connected to \(first.displayName)"
                            self.log("Device selected: \(first.displayName) [Total: \(allDevs.count)]")
                            self.applyDevicePreferences(from: first)
                        } else {
                            self.activateCardDevice(nil)
                            self.device = nil
                            self.refreshWalletCatalog()
                            if resp.error == "device_helper_missing" {
                                self.scannerMessage = "Device tools are missing. Rebuild or reinstall AirCard, then reconnect."
                                self.statusText = "Device tools are missing from this build."
                                self.log("Bundled device_helper not found — detection cannot run.")
                            } else {
                                self.statusText = "No iPhone found. Please connect via USB."
                                self.scannerMessage = "No iPhone connected. Connect, unlock and trust this Mac, then use Reconnect."
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
                            self.statusText = "Connected to \(dev.name ?? "iPhone")"
                            self.log("Device connected: \(dev.name ?? "iPhone") (\(dev.product ?? ""), iOS \(dev.version ?? ""))")
                            self.applyDevicePreferences(from: dev)
                        } else {
                            self.devices = []
                            self.device = nil
                            if dev.error == "device_helper_missing" {
                                self.scannerMessage = "Device tools are missing. Rebuild or reinstall AirCard, then reconnect."
                                self.statusText = "Device tools are missing from this build."
                                self.log("Bundled device_helper not found — detection cannot run.")
                            } else {
                                self.statusText = "No iPhone found. Please connect via USB."
                                self.scannerMessage = "No iPhone connected. Connect, unlock and trust this Mac, then use Reconnect."
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
                            self.statusText = "Command Line Tools required."
                            self.errorMessage = "AirCard needs Xcode Command Line Tools to communicate with devices.\n\nPlease open Terminal and run:\nxcode-select --install\n\nor open Xcode to accept the license agreement, then restart AirCard."
                            self.scannerMessage = "Developer tools or license agreement required. See log."
                        } else {
                            self.statusText = "Device detection could not run. See the log."
                            self.errorMessage = errRaw.isEmpty
                                ? "AirCard could not run its device tools. Check the Activity Console log for details."
                                : "Device tool error: \(errRaw.prefix(300))"
                            self.scannerMessage = "Device check failed. Reconnect and unlock the iPhone, then retry."
                        }
                        if !errRaw.isEmpty {
                            self.log("Backend stderr: \(errRaw)")
                        }
                        self.log("Device detection returned nothing usable: \(raw.isEmpty ? "(no stdout)" : raw.prefix(400).description)")
                    }
                }
            } catch {
                await MainActor.run {
                    self.devices = []
                    self.device = nil
                    self.activateCardDevice(nil)
                    self.refreshWalletCatalog()
                    self.isCheckingDevice = false
                    self.scannerMessage = "Device check failed. Reconnect and unlock the iPhone, then retry."
                    self.statusText = "Device detection failed: \(error.localizedDescription)"
                    self.log("Process execution failed: \(error.localizedDescription)")
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
        
        self.log("  ⚡ Auto-configured passcode target: \(self.targetTelephonyVersion), language: \(self.passcodeLanguageTarget.rawValue), font: \(self.passcodeBoldTarget.rawValue)")
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
        guard !isScanningCards, !isFlashing, !isCheckingDevice, !isDownloadingCardArtwork else { return }
        guard let deviceHelper = AppViewModel.deviceHelperExecutableURL else {
            errorMessage = "Device tools are missing from this build."
            scannerMessage = "Device tools are missing. Rebuild or reinstall AirCard, then reconnect."
            log("Bundled device_helper not found — cannot scan.")
            return
        }
        guard let udid = device?.udid else {
            errorMessage = "No iPhone connected."
            scannerMessage = "No iPhone connected. Connect, unlock and trust this Mac, then use Reconnect."
            return
        }
        isScanningCards = true
        currentScanIDs = []
        currentPreloadedIDs = []
        pendingActivationIDs = []
        scannerMessage = "Connecting to the iPhone log stream…"
        statusText = "Double-click Side button, pass Face ID, then tap your card..."
        log("Started scanning device logs for cards...")
        
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
            statusText = "Could not start card scanning."
            scannerMessage = "Scanner could not start. Reconnect the iPhone and try again."
            log("Syslog monitor failed to start: \(error.localizedDescription)")
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
                                if line.contains("Connected to the unified") {
                                    self.scannerMessage = "Scanner connected. Open Wallet and tap a card; membership cards may need opening in the Wallet app."
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
                    self.statusText = "Card scanning ended. Check the log and reconnect the iPhone to retry."
                    self.scannerMessage = "Scanner stopped unexpectedly (exit \(proc.terminationStatus)). Reconnect and unlock the iPhone, then scan again. Check Log for details."
                    self.log("Syslog monitor exited (status \(proc.terminationStatus)). Total cards: \(self.cards.count).")
                    self.saveCards()
                }
            } catch {
                if proc.isRunning { proc.terminate() }
                proc.waitUntilExit()
                await MainActor.run {
                    guard self.scanProcess === proc else { return }
                    self.scanProcess = nil
                    self.log("Syslog monitor stopped: \(error.localizedDescription)")
                    self.isScanningCards = false
                    self.statusText = "Card scanning failed. Check the log and retry."
                    self.scannerMessage = "The log connection failed. Reconnect the iPhone and retry scanning."
                }
            }
        }
    }
    
    func stopCardScanning() {
        catalogRefreshTask?.cancel()
        pendingActivationIDs = []
        if isScanningCards {
            if !currentVerifiedCardIDs.isEmpty {
                scannerMessage = "\(currentVerifiedCardIDs.count) card(s) verified."
            } else if !currentScanIDs.isEmpty {
                scannerMessage = "Scan stopped. \(currentScanIDs.count) card(s) detected."
            } else {
                scannerMessage = "No cards detected. Open Wallet and tap a card."
            }
        }
        let process = scanProcess
        scanProcess = nil
        if let process, process.isRunning { process.terminate() }
        isScanningCards = false
        if statusText.contains("Double-click Side button") {
            statusText = "Ready"
        }
        saveCards()
        log("Scanning stopped. Total cards: \(cards.count).")
        if process != nil { refreshWalletCatalog() }
        scheduleRemoteArtworkProbe()
    }
    
    // MARK: - Skin Application
    
    func applySkin() {
        guard !isDownloadingCardArtwork else { return }
        guard let udid = device?.udid else {
            errorMessage = "No iPhone connected."
            return
        }
        let allSkinned = cards.filter { $0.isSelected && $0.customImageURL != nil }
        guard !allSkinned.isEmpty else {
            errorMessage = "Please assign a skin image to at least one selected card."
            return
        }
        // Only flash changed skins; if nothing changed, re-flash everything selected.
        let changed = cardsNeedingFlash
        let selectedCardsWithSkin = changed.isEmpty ? allSkinned : changed
        
        isFlashing = true
        showLogs = true
        progress = 0.0
        if changed.isEmpty {
            log("No changed skins; re-flashing all \(allSkinned.count) selected card(s)...")
        } else {
            log("Starting skin application for \(changed.count) changed card(s); skipping \(allSkinned.count - changed.count) already flashed.")
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
                    self.statusText = "[\(idx + 1)/\(selectedCardsWithSkin.count)] Preparing skin for \(card.id.prefix(10))..."
                    self.progress = (Double(idx) + 0.05) / totalCards
                    self.log("Flashing card [\(idx + 1)/\(selectedCardsWithSkin.count)]: \(card.id)")
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
                        self.log("Could not prepare artwork from \(name); skipping this card.")
                        self.errorMessage = "AirCard could not read the image you picked for one of the cards. That card was left unchanged."
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
                        self.log("Failed to launch card flasher: \(message)")
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
                        self.log("Card update failed for \(card.id.prefix(12))...")
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
                    self.statusText = "Failed to apply card skins."
                    self.errorMessage = "One or more cards could not be updated. Check the log and try again."
                    self.log("Skin application stopped after a card update failed.")
                } else {
                    self.statusText = "Complete! All cards updated."
                    self.showSuccessAlert = true
                    self.log("Skins successfully applied to all selected cards!")
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
                    self.statusText = "Loaded passcode theme '\(name)' (\(fileCount) assets)"
                    self.log("Loaded .passthm: \(name) [\(detectedVersion)] with \(fileCount) image assets")
                }
            } else {
                await MainActor.run {
                    self.isInspectingTheme = false
                    self.errorMessage = "Failed to inspect .passthm file"
                }
            }
        }
    }
    
    func flashPasscodeTheme() {
        guard !isDownloadingCardArtwork else { return }
        guard let theme = loadedPasscodeTheme else { return }
        guard let dev = device, dev.connected, let udid = dev.udid else {
            errorMessage = "Please connect and trust your iPhone first."
            return
        }
        
        isFlashing = true
        showLogs = true
        progress = 0.0
        statusText = "Starting passcode theme flash..."
        log("Flashing passcode theme '\(theme.name)' to device...")
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
                    self.statusText = "Passcode theme applied successfully!"
                    self.showSuccessAlert = true
                    self.log("Passcode theme '\(theme.name)' successfully flashed!")
                } else {
                    let err = self.errorMessage ?? "Flashing failed (exit code \(exitCode))"
                    self.statusText = err
                    self.log("ERROR: \(err)")
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
        statusText = "Poster image loaded · Ready to frame and slice"
    }
    
    func setIndividualKey(digit: String, image: NSImage) {
        creatorRawIndividualImages[digit] = image
        creatorIndividualOffsets[digit] = .zero
        creatorIndividualZooms[digit] = 1.0
        selectedKeyDigit = digit
        updateIndividualKey(digit: digit)
        statusText = "Updated key \(digit) · Drag on dialer to reposition or use zoom slider"
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
        statusText = "Cleared key \(digit)"
    }
    
    func clearAllIndividualKeys() {
        creatorCustomKeys.removeAll()
        creatorRawIndividualImages.removeAll()
        creatorIndividualOffsets.removeAll()
        creatorIndividualZooms.removeAll()
        selectedKeyDigit = nil
        statusText = "Cleared all custom keys"
    }
    
    func adoptPosterSlicesToIndividualKeys() {
        for (k, v) in creatorSlicedKeys {
            creatorCustomKeys[k] = v
            creatorRawIndividualImages[k] = v
            creatorIndividualOffsets[k] = .zero
            creatorIndividualZooms[k] = 1.0
        }
        statusText = "Adopted poster slices to individual keys"
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
        statusText = "Loaded '\(theme.name)' into Theme Creator (\(theme.keysPreview.count) keys ready to edit)"
        log("Imported theme '\(theme.name)' into Creator for custom editing")
    }
    
    func clearCreator() {
        creatorPosterImage = nil
        creatorPosterZoom = 1.0
        creatorPosterOffset = .zero
        creatorSlicedKeys.removeAll()
        clearAllIndividualKeys()
        statusText = "Theme Creator reset"
    }
    
    func flashCreatedTheme() {
        guard !isDownloadingCardArtwork else { return }
        let keys = effectiveCreatorKeys
        guard !keys.isEmpty else {
            errorMessage = "Please add at least one key icon or import a poster image first."
            return
        }
        guard let dev = device, dev.connected, dev.udid != nil else {
            errorMessage = "Please connect and trust your iPhone first."
            return
        }
        
        guard let stagedURL = PasscodeThemeExporter.stageTemporaryTheme(
            keys: keys,
            language: passcodeLanguageTarget,
            boldMode: passcodeBoldTarget
        ) else {
            errorMessage = "Failed to package theme for flashing."
            return
        }
        
        let themeInfo = PasscodeThemeInfo(
            name: "Created Theme",
            filePath: stagedURL.path,
            detectedVersion: targetTelephonyVersion,
            fileCount: keys.count * 4,
            keysPreview: keys
        )
        self.loadedPasscodeTheme = themeInfo
        self.flashPasscodeTheme()
    }

    /// Coalesce scan events and queue probes behind active transfers.
    func scheduleRemoteArtworkProbe(after delay: TimeInterval = 1.2) {
        if isDownloadingCardArtwork || isProbingRemoteArtwork {
            pendingRemoteArtworkProbe = true
            return
        }
        pendingRemoteArtworkProbe = false
        remoteArtworkProbeDebounce?.cancel()
        remoteArtworkProbeDebounce = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            if self.isProbingRemoteArtwork || !self.downloadingCardIDs.isEmpty {
                self.pendingRemoteArtworkProbe = true
                return
            }
            self.refreshRemoteArtworkAvailability()
        }
    }

    /// Consume a queued request even after failure, with at most two retries.
    func finishRemoteArtworkProbe(failed: Bool) {
        isProbingRemoteArtwork = false
        let pending = pendingRemoteArtworkProbe
        pendingRemoteArtworkProbe = false
        if failed {
            remoteArtworkProbeFailures += 1
            if remoteArtworkProbeFailures <= 2 {
                log("Artwork check failed; retry \(remoteArtworkProbeFailures)/2.")
                scheduleRemoteArtworkProbe(after: Double(remoteArtworkProbeFailures) * 2)
            } else {
                remoteArtworkProbeFailures = 0
                log("Artwork check failed after two retries.")
            }
        } else {
            remoteArtworkProbeFailures = 0
            if pending { scheduleRemoteArtworkProbe() }
        }
    }

    /// Ask the iPhone which cards expose a remote card-artwork manifest.
    /// Those are the only cards that can download their original card artwork.
    func refreshRemoteArtworkAvailability() {
        // Release the cached lookup link when switching devices.
        let currentDevice = device?.udid
        if let previous = artworkLookupDeviceID, previous != currentDevice {
            releaseArtworkLookupLink(udid: previous)
        }
        artworkLookupDeviceID = currentDevice

        guard let udid = device?.udid, !isProbingRemoteArtwork else { return }
        // Saved IDs warm the lookup link up early; only verified cards may show
        // a download button.
        let probeIDs = cards.map(\.id).prefix(100)
        guard !probeIDs.isEmpty else {
            remoteArtworkCardIDs = []
            return
        }

        isProbingRemoteArtwork = true
        let scriptDir = self.scriptDir
        Task.detached {
            let result = AppViewModel.runArtworkCommand(
                ["--probe-card-artwork", udid] + probeIDs, scriptDir: scriptDir)
            let resolved = Set(result.json["available"] as? [String] ?? [])
            let failed = !result.ok
            await MainActor.run {
                guard self.device?.udid == udid, self.activeCardDeviceID == udid else {
                    self.finishRemoteArtworkProbe(failed: false)
                    self.scheduleRemoteArtworkProbe(after: 0)
                    return
                }
                if failed {
                    self.finishRemoteArtworkProbe(failed: true)
                    return
                }
                let previous = self.remoteArtworkCardIDs
                self.remoteArtworkCardIDs = Set(resolved.filter { self.hasArtworkCardEvidence($0) })
                if self.remoteArtworkCardIDs != previous {
                    self.log("Artwork available for \(self.remoteArtworkCardIDs.count) card(s).")
                }
                self.finishRemoteArtworkProbe(failed: false)
            }
        }
    }

    /// Shared subprocess and JSON handling for artwork commands.
    nonisolated private static func runArtworkCommand(
        _ arguments: [String], scriptDir: String, process: Process = Process()
    ) -> (json: [String: Any], ok: Bool, failure: String) {
        process.executableURL = pythonExecutableURL
        process.environment = processEnvironment
        process.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
        process.arguments = ["aircard_backend.py"] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return ([:], false, error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        process.waitUntilExit()
        let last = String(data: data, encoding: .utf8)?.split(whereSeparator: \.isNewline).last
        let json = last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        let failure = (json["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (stderr.isEmpty ? "Card artwork command failed." : stderr)
        return (json, process.terminationStatus == 0 && json["ok"] as? Bool == true, failure)
    }

    nonisolated private static func artworkDetail(_ json: [String: Any]) -> String {
        var parts: [String] = []
        if let width = json["width"] as? Int, let height = json["height"] as? Int,
           width > 0, height > 0 { parts.append("\(width)x\(height)") }
        parts.append((json["extension"] as? String ?? ".png").dropFirst().uppercased())
        if let problems = json["problems"] as? [String], !problems.isEmpty {
            parts.append("manifest mismatch: " + problems.joined(separator: "; "))
        } else {
            parts.append(json["verified"] as? Bool == true ? "verified" : "unverified")
        }
        return parts.joined(separator: " · ")
    }

    /// One backend process reads all manifests and returns per-card results.
    nonisolated private static func runArtworkFetchAll(
        udid: String, cardIDs: [String], directory: String, scriptDir: String, process: Process
    ) -> (saved: Int, results: [(String, Bool, String)], failure: String) {
        let command = runArtworkCommand(
            ["--fetch-card-artworks", udid, directory] + cardIDs,
            scriptDir: scriptDir, process: process)
        let summary = command.json
        let failure = command.failure

        var results: [(String, Bool, String)] = []
        for entry in summary["results"] as? [[String: Any]] ?? [] {
            let cardID = entry["card"] as? String ?? ""
            let ok = entry["ok"] as? Bool ?? false
            let detail: String
            if ok {
                detail = artworkDetail(entry)
            } else {
                detail = entry["error"] as? String ?? failure
            }
            results.append((cardID, ok, detail))
        }
        return (summary["saved"] as? Int ?? 0, results, failure)
    }

    /// Pause log streaming to avoid competing for the device transport.
    private func pauseScanForArtworkTransfer() {
        guard isScanningCards else { return }
        log("Scan paused for download.")
        stopCardScanning()
    }

    /// The asset is saved exactly as Apple served it, so a file the save panel
    /// named ".png" is renamed when the payload turns out to be another format.
    func matchExtension(of url: URL, to extension: String) -> URL {
        let actual = `extension`.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !actual.isEmpty,
              actual != url.pathExtension.lowercased() else { return url }
        let base = url.deletingPathExtension()
        var suffix = 0
        while true {
            let candidate = suffix == 0 ? base : URL(fileURLWithPath: base.path + " (\(suffix))")
            let renamed = candidate.appendingPathExtension(actual)
            do {
                // moveItem refuses an existing destination, including a race
                // after the save panel closed. Preserve it and try a new name.
                try FileManager.default.moveItem(at: url, to: renamed)
                return renamed
            } catch {
                guard FileManager.default.fileExists(atPath: renamed.path),
                      FileManager.default.fileExists(atPath: url.path) else { return url }
                suffix += 1
            }
        }
    }

    func cancelArtworkDownload() {
        guard isDownloadingCardArtwork, !isCancellingArtworkDownload,
              let process = artworkDownloadProcess else { return }
        isCancellingArtworkDownload = true
        statusText = "Cancelling safely; keep the iPhone connected…"
        log("Cancelling download safely…")
        Task { @MainActor in
            // A click can arrive before the detached task starts the backend.
            while self.artworkDownloadProcess === process && !process.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if self.artworkDownloadProcess === process && process.isRunning {
                AppViewModel.sendArtworkCancelSignal(process)
            }
        }
    }

    nonisolated static func sendArtworkCancelSignal(_ process: Process) {
        // Process.terminate() also signals child processes on macOS. Only the
        // Python parent should receive cancellation; device helpers must finish.
        if process.isRunning { kill(process.processIdentifier, SIGTERM) }
    }

    func hasArtworkCardEvidence(_ cardID: String) -> Bool {
        currentVerifiedCardIDs.contains(cardID) || confirmedCardIDs.contains(cardID)
    }

    func downloadOriginalCardArtwork(cardID: String, to destinationURL: URL) {
        guard !isDownloadingCardArtwork, !isFlashing, !isCheckingDevice else { return }
        guard let udid = device?.udid, device?.connected == true,
              activeCardDeviceID == udid, hasArtworkCardEvidence(cardID) else {
            errorMessage = "Reconnect the iPhone and scan this card before downloading its card artwork."
            return
        }
        // Mark the transfer first: stopCardScanning() refreshes the eligibility
        // probe, which must queue behind this download instead of competing.
        downloadingCardIDs.insert(cardID)
        pauseScanForArtworkTransfer()
        showLogs = true
        statusText = "Downloading the original card artwork for \(cardID.prefix(10))..."
        log("Downloading \(cardID.prefix(12))… → \(destinationURL.lastPathComponent)")
        let scriptDir = self.scriptDir
        let outputPath = destinationURL.path
        let process = Process()
        artworkDownloadProcess = process
        isCancellingArtworkDownload = false

        Task.detached {
            let outcome = AppViewModel.runArtworkCommand(
                ["--fetch-card-artwork", udid, cardID, outputPath], scriptDir: scriptDir, process: process)
            await MainActor.run {
                self.downloadingCardIDs.remove(cardID)
                let cancelled = self.isCancellingArtworkDownload
                self.artworkDownloadProcess = nil
                self.isCancellingArtworkDownload = false
                if outcome.ok {
                    let saved = self.matchExtension(of: destinationURL, to: outcome.json["extension"] as? String ?? ".png")
                    self.statusText = "Saved the original card artwork to \(saved.lastPathComponent)"
                    self.log("Saved \(saved.lastPathComponent): \(AppViewModel.artworkDetail(outcome.json))")
                } else if cancelled {
                    self.statusText = "Card artwork download cancelled."
                    self.log(self.statusText)
                } else {
                    self.statusText = "Card artwork download failed."
                    self.errorMessage = outcome.failure
                    self.log("Download failed for \(cardID.prefix(12))…: \(outcome.failure)")
                }
                self.scheduleRemoteArtworkProbe()
            }
        }
    }

    /// Download all eligible cards in one device transfer.
    func downloadAllCardArtwork(into directory: URL) {
        guard !isDownloadingCardArtwork, !isFlashing, !isCheckingDevice else { return }
        guard let udid = device?.udid else {
            errorMessage = "No iPhone connected."
            return
        }
        let cardIDs = remoteArtworkCardIDs.sorted()
        guard !cardIDs.isEmpty else {
            errorMessage = "No card exposes a downloadable card artwork right now."
            return
        }
        // Mark every transfer before pausing, for the same reason as above.
        for cardID in cardIDs { downloadingCardIDs.insert(cardID) }
        pauseScanForArtworkTransfer()

        showLogs = true
        statusText = "Downloading card artwork for \(cardIDs.count) card(s)..."
        log("Downloading \(cardIDs.count) artwork file(s) → \(directory.lastPathComponent)")
        let scriptDir = self.scriptDir

        let process = Process()
        artworkDownloadProcess = process
        isCancellingArtworkDownload = false

        Task.detached {
            let batch = AppViewModel.runArtworkFetchAll(
                udid: udid, cardIDs: cardIDs, directory: directory.path, scriptDir: scriptDir, process: process)
            let results = batch.results
            await MainActor.run {
                for cardID in cardIDs { _ = self.downloadingCardIDs.remove(cardID) }
                let cancelled = self.isCancellingArtworkDownload
                self.artworkDownloadProcess = nil
                self.isCancellingArtworkDownload = false
                for (cardID, ok, detail) in results {
                    if ok {
                        self.log("Saved \(cardID.prefix(12))…: \(detail)")
                    } else if !cancelled {
                        self.log("Download failed for \(cardID.prefix(12))…: \(detail)")
                    }
                }
                self.statusText = "Saved \(batch.saved) of \(cardIDs.count) artwork file(s) to \(directory.lastPathComponent)"
                if cancelled {
                    self.statusText = "Download cancelled. Kept \(batch.saved) saved artwork file(s)."
                    self.log(self.statusText)
                } else if batch.saved == 0 && !batch.failure.isEmpty {
                    self.errorMessage = batch.failure
                    if results.isEmpty { self.log("Download failed: \(batch.failure)") }
                } else if batch.saved < cardIDs.count {
                    self.errorMessage = "\(cardIDs.count - batch.saved) card artwork download(s) failed. See Log."
                }
                self.scheduleRemoteArtworkProbe()
            }
        }
    }

}

// MARK: - Artwork Download Controls

/// Batch download button, separated to keep the main view easy to type-check.
private struct ArtworkDownloadToolbarButton: View {
    let count: Int
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Download Artwork (\(count)", systemImage: "arrow.down.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(!isEnabled)
        .help("Download the original card artwork for every card that exposes one")
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
    let onDownloadImage: () -> Void
    let onDropImage: (URL) -> Void
    var isDownloading = false
    /// Only cards whose pass bundle names a remote artwork asset can be fetched.
    var canDownloadArtwork = false
    
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
                        .help("Remove skin")
                        
                        // Hover overlay: Change Skin
                        if isHovered {
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    Label("Change Skin", systemImage: "photo.badge.arrow.forward")
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
                            
                            Text(isTargeted ? "Drop image here" : "Assign Card Skin")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                            
                            Text("Click to browse or drag image")
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
                Text(card.displayName ?? "Unidentified card")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .help(card.displayName ?? "No matching name in the Mac cache. The card ID is preserved.")
                if isVerified {
                    Text("Matched to this iPhone in current scan")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if card.confirmed {
                    Text("Saved on this iPhone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Manually added · Ready to flash")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if card.customImageURL != nil && card.customImage == nil {
                    Text("Skin file unavailable. Choose the image again.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Bottom Info & Controls
            HStack(spacing: 8) {
                Toggle("", isOn: $card.isSelected)
                    .labelsHidden()
                    .help("Include in flash")
                
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
                    .help(copied ? "Copied!" : "Copy full hash")
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
                        .help(isFlashed ? "Skin already on iPhone" : "Skin changed, will be flashed")
                }

                if canDownloadArtwork {
                    Button(action: onDownloadImage) {
                        Image(systemName: isDownloading ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .disabled(isDownloading)
                    .help(isDownloading ? "Downloading the original card artwork…" : "Download the original card artwork")
                }
                
                // Delete button
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Remove from list")
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
                        Text(isCopied ? "Copied!" : "Copy")
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
                                    onDownloadImage: { downloadOriginalCardArtwork(for: cardID) },
                                    onDropImage: { url in
                                        guard vm.device?.udid == deviceID else { return }
                                        vm.setCardImage(for: cardID, url: url)
                                    },
                                    isDownloading: vm.downloadingCardIDs.contains(cardID),
                                    canDownloadArtwork: vm.remoteArtworkCardIDs.contains(cardID)
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
        .disabled(vm.isDownloadingCardArtwork)
        .overlay {
            if vm.isDownloadingCardArtwork {
                ZStack {
                    Color.black.opacity(0.22)
                        .contentShape(Rectangle())
                        .onTapGesture { }
                    VStack(spacing: 14) {
                        ProgressView()
                        Text(vm.isCancellingArtworkDownload ? "Cancelling safely…" : "Downloading card artwork…")
                            .font(.headline)
                        Text("Please wait. Keep your iPhone connected and unlocked.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Cancel") { vm.cancelArtworkDownload() }
                            .buttonStyle(.bordered)
                            .disabled(vm.isCancellingArtworkDownload)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(radius: 16)
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .alert("Success!", isPresented: $vm.showSuccessAlert) {
            Button("OK") {}
        } message: {
            if vm.selectedTab == .passcodeThemes {
                Text("Passcode theme successfully applied!\n\nLock your iPhone (or restart) to see your new passcode keypad.")
            } else {
                Text("Skins successfully applied to all selected cards!\n\nPlease force-close the Wallet app on your iPhone (or reboot) to see your new designs.\n\nNote: Apple Card renders dynamically and its face color reflects your spending categories rather than static cached skins.")
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
            if vm.statusText.contains("Double-click Side button") {
                vm.statusText = "Ready"
            }
        }
        // Wallet can update its manifests while rendering cards.
        .onChange(of: vm.selectedTab) { _, newTab in
            if newTab == .walletCards { vm.scheduleRemoteArtworkProbe(after: 0) }
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
                Text("Wallet Cards & Passcode Themes")
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
                    Text("No iPhone (USB)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Menu {
                        Section("Connected Devices (\(max(vm.devices.count, 1)))") {
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
                            Label("Refresh Device List", systemImage: "arrow.clockwise")
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
                                Text("Select Device")
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
                    .help("Click to select an active device")
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
                .help("Refresh device connection")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(height: 32)
            .background(Color(NSColor.windowBackgroundColor))
            .cornerRadius(16)
            
            Button(action: { showCredits = true }) {
                Label("Credits & Donate", systemImage: "heart.fill")
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
                    Text(vm.isCheckingDevice ? "Checking iPhone…" : vm.isScanningCards ? "Stop Scanning" : "Scan Cards")
                        .fontWeight(.semibold)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.isScanningCards ? .red : .blue)
            .controlSize(.regular)
            .disabled(vm.device?.connected != true || vm.isCheckingDevice || vm.isFlashing)
            
            Button(action: { vm.showAddCardSheet = true }) {
                Label("Save IDs", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            if !vm.remoteArtworkCardIDs.isEmpty {
                ArtworkDownloadToolbarButton(
                    count: vm.remoteArtworkCardIDs.count,
                    isEnabled: !(vm.isScanningCards || vm.isFlashing || vm.isCheckingDevice),
                    action: downloadAllCardArtwork)
            }
            
            if !vm.cards.isEmpty {
                Button(action: openBulkImagePicker) {
                    Label("Set Skin for All...", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Assign one skin to all selected cards")
            }
            
            Spacer()
            
            if !vm.cards.isEmpty {
                HStack(spacing: 8) {
                    Button("Select All") {
                        for idx in vm.cards.indices {
                            vm.cards[idx].isSelected = true
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    
                    Text("·").foregroundColor(.secondary)
                    
                    Button("Deselect All") {
                        for idx in vm.cards.indices {
                            vm.cards[idx].isSelected = false
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    
                    Text("·").foregroundColor(.secondary)
                    
                    Button("Clear All") {
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
                Text("Live Scanner Active")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
                Text("Double-click Side button (Apple Pay), pass Face ID, then tap your card.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("Done") {
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
            
            Text(vm.isScanningCards ? "Scanning for Cards…" : "No Cards Detected Yet")
                .font(.title3)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text("1.")
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                    Text(vm.isScanningCards ? "Scanner is active. Open Wallet on your iPhone." : "Click **Scan Cards** in the toolbar above.")
                }
                HStack(alignment: .top, spacing: 10) {
                    Text("2.")
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                    Text("On your iPhone, **double-click the Side button** (Apple Pay), authenticate with **Face ID**, and **tap your card**.")
                }
                HStack(alignment: .top, spacing: 10) {
                    Text("3.")
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                    Text(vm.isScanningCards ? "Detected cards will appear here as the iPhone reports them." : "Your card will be detected immediately!")
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
                    Label(vm.isCheckingDevice ? "Checking iPhone…" : vm.isScanningCards ? "Stop Scanning" : "Start Scanning", systemImage: "wave.3.forward.circle.fill")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(vm.device?.connected != true || vm.isCheckingDevice || vm.isFlashing)
                
                Button("Save IDs for Matching") {
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
                    Label("Choose .passthm File...", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.regular)
            } else {
                Button(action: { openPosterPicker() }) {
                    Label(vm.creatorPosterImage == nil ? "Choose Poster..." : "Change Poster...", systemImage: "photo")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.regular)
                
                Button(action: { openSavePasscodeThemePanel() }) {
                    Label("Export .passthm...", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(vm.effectiveCreatorKeys.isEmpty)
            }
            
            Spacer()
            
            // Target Version Picker
            HStack(spacing: 6) {
                Text("Target:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $vm.targetTelephonyVersion) {
                    Text("TelephonyUI-10 (iOS 18+)").tag("TelephonyUI-10")
                    Text("TelephonyUI-9 (iOS 16–17)").tag("TelephonyUI-9")
                    Text("TelephonyUI-8 (iOS 14–15)").tag("TelephonyUI-8")
                    Text("Universal (All 8, 9, 10)").tag("all")
                }
                .pickerStyle(.menu)
                .controlSize(.regular)
                .frame(width: 205)
            }
            
            Text("·")
                .foregroundColor(.secondary)
            
            if vm.passcodeTabMode == .applyTheme {
                Button("Clear Theme") {
                    vm.loadedPasscodeTheme = nil
                }
                .buttonStyle(.link)
                .font(.caption)
                .foregroundColor(.red)
                .disabled(vm.loadedPasscodeTheme == nil)
            } else {
                Button("Clear All") {
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
                    Text("Lock Screen Keypad Preview")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Spacer()
                    if vm.loadedPasscodeTheme != nil {
                        Text("Custom Theme Loaded")
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
            Text("Passcode Theme File")
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
                    
                    Text("\(theme.fileCount) artwork assets loaded · Ready to flash to iPhone")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 8) {
                        Button(action: { vm.editLoadedThemeInCreator() }) {
                            Label("Edit in Creator", systemImage: "pencil.and.outline")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .controlSize(.regular)
                        
                        Button("Change...") {
                            openPasscodeThemePicker()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        
                        Button("Clear") {
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
                    
                    Text("Drop .passthm file here")
                        .font(.caption)
                        .fontWeight(.semibold)
                    
                    Text("Supports .passthm, .passtheme, or .zip packages from Cowabunga or Nugget")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                    
                    Button("Choose File...") {
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
                    Text("Interactive iPhone Lock Screen Preview")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Spacer()
                    if vm.creatorSubMode == .posterSlice && vm.creatorPosterImage != nil {
                        Text("Drag dialer to pan · Use slider to zoom")
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
                    Text("Poster Artwork")
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
                                Text("Artwork Loaded")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                HStack(spacing: 8) {
                                    Button("Change...") {
                                        openPosterPicker()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    
                                    Button("Remove") {
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
                            
                            Text("Drop poster or wallpaper here")
                                .font(.caption)
                                .fontWeight(.medium)
                            
                            Button("Choose Image...") {
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
                    Text("Slicing Style")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    Picker("", selection: $vm.creatorMaskToCircles) {
                        Text("Seamless Poster").tag(false)
                        Text("Circle Buttons").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: vm.creatorMaskToCircles) { _, _ in
                        vm.updatePosterSlicing()
                    }
                    
                    Text(vm.creatorMaskToCircles ? "Artwork is clipped into individual circular button icons." : "Seamless artwork spans across dialer keys without circular cuts (Adobe Dog style).")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Divider()
                
                // 3. Framing & Zoom Section
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Zoom & Framing")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Button("Reset Position") {
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
                            Text("Zoom")
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
                        Text("Drag anywhere on the dialer preview to reposition")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                // Individual Keys Mode Controls
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Individual Keys")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Spacer()
                        if let sel = vm.selectedKeyDigit {
                            Button("Deselect Key \(sel)") {
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
                                Label("Key \(selDigit) Framing", systemImage: "crop")
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                                    .foregroundColor(.purple)
                                Spacer()
                                Button("Reset") {
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
                                Text("Drag Key \(selDigit) on dialer preview to reposition")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            HStack(spacing: 8) {
                                Button("Change Image...") {
                                    openIndividualKeyPicker(for: selDigit)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                
                                Button("Remove") {
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
                    
                    Text("Click any key on the dialer to select it, pan the image, adjust zoom, or drop files.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                        Text("\(vm.creatorCustomKeys.count) of 10 keys configured")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    
                    HStack(spacing: 8) {
                        if !vm.creatorSlicedKeys.isEmpty {
                            Button("Fill from Poster") {
                                vm.adoptPosterSlicesToIndividualKeys()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        }
                        
                        Button("Clear All Keys") {
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
                Button("Change Key \(btn.digit)...") {
                    openIndividualKeyPicker(for: btn.digit)
                }
                if customIndividualImage != nil {
                    Button("Reset Position & Zoom") {
                        vm.creatorIndividualOffsets[btn.digit] = .zero
                        vm.creatorIndividualZooms[btn.digit] = 1.0
                        dragKeyStartOffsets[btn.digit] = .zero
                        vm.updateIndividualKey(digit: btn.digit)
                    }
                    Button("Clear Key \(btn.digit)") {
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
                    
                    Text("Enter Passcode")
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
                    Text("Emergency")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white.opacity(0.9))
                    Spacer()
                    Text("Cancel")
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
                Text("Flash & Language Target")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Spacer()
                if let dev = vm.device, dev.connected {
                    Button(action: { vm.applyDevicePreferences(from: dev) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                            Text("Auto-detect")
                        }
                        .font(.system(size: 9, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to iPhone's detected language and font style")
                }
            }
            
            // 1. Language Target Selector
            VStack(alignment: .leading, spacing: 4) {
                Text("System Language:")
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
                Text("Font Weight / Style:")
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
                    Text("Universal mode flashes ~600 files for all languages & Bold text. Selecting a specific language (e.g. Ukrainian) speeds up flashing dramatically.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Fast mode selected: only targets \(vm.passcodeLanguageTarget.rawValue) with \(vm.passcodeBoldTarget.rawValue).")
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
                Text("Activity Log")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear") {
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
                                Text("Theme Creator · \(count) of 10 keys configured · Target: \(targetInfo)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Theme Creator · Import a poster or drop icons onto keys")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        } else if let theme = vm.loadedPasscodeTheme {
                            let targetInfo = "\(vm.targetTelephonyVersion) · \(vm.passcodeLanguageTarget.code.uppercased()) · \(vm.passcodeBoldTarget.code)"
                            Text("\(theme.fileCount) source assets loaded · Target: \(targetInfo)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        } else {
                            Text("No .passthm loaded · Select a theme package to flash")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    } else if !vm.cards.isEmpty {
                        let selectedCount = vm.cards.filter { $0.isSelected }.count
                        Text("\(selectedCount) of \(vm.cards.count) cards selected · \(changedCount) changed · \(readyToFlashCount - changedCount) already on iPhone")
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
                        Text("Log")
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
                                Text(vm.isFlashing ? "Flashing Passcode..." : "Flash to iPhone")
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
                                Text(vm.isFlashing ? "Flashing Passcode..." : "Flash Passcode Theme")
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
                            Text(vm.isFlashing ? "Flashing Cards..." : (changedCount > 0 ? "Flash Skins (\(changedCount) Changed)" : (readyToFlashCount > 0 ? "Re-flash All (\(readyToFlashCount))" : "Flash Skins")))
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
                    Text("By")
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
                        Text("@mak5er • Lead Developer")
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
                Text("DONATE & SUPPORT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 2)

                // PayPal Button
                Link(destination: URL(string: "https://www.paypal.com/donate/?hosted_button_id=98QRTC2HFRA4Y")!) {
                    HStack(spacing: 8) {
                        Image(systemName: "creditcard.fill")
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Donate with PayPal")
                                .font(.system(size: 12, weight: .bold))
                            Text("Recipient: Maksym Reva")
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

            Text("Thank you for supporting AirCard development! ❤️")
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

                Text("Welcome to AirCard!")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Free & Open Source • Developed by @mak5er")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            macDonateContentView

            Divider()

            VStack(spacing: 8) {
                Button("Continue to AirCard") {
                    showSupportPopup = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .frame(maxWidth: .infinity)

                Toggle("Don't show this popup on startup", isOn: $dontShowSupportOnLaunch)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("You can reopen donation options anytime in Credits & Donate ❤️")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var creditsSheet: some View {
        VStack(spacing: 14) {
            Picker("Category", selection: $creditsSelectedTab) {
                Text("Credits").tag(0)
                Text("Donate ❤️").tag(1)
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
                    
                    Text("Apple Wallet Skins & Passcode Themes for iOS 18+")
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
                            Text("Support @mak5er (Donate ❤️)")
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
                            Text("Developer:")
                                .fontWeight(.medium)
                            Link("@mak5er", destination: URL(string: "https://github.com/mak5er")!)
                            Text("·")
                                .foregroundColor(.secondary)
                            Link("Twitter / X", destination: URL(string: "https://x.com/mak5er")!)
                        }
                        
                        HStack {
                            Image(systemName: "person.crop.circle.fill")
                                .foregroundColor(.blue)
                            Text("Developer:")
                                .fontWeight(.medium)
                            Link("@Lumid-Off", destination: URL(string: "https://github.com/Lumid-Off")!)
                            Text("·")
                                .foregroundColor(.secondary)
                            Link("Twitter / X", destination: URL(string: "https://x.com/LumidOff")!)
                        }
                        
                        HStack {
                            Image(systemName: "bolt.shield.fill")
                                .foregroundColor(.orange)
                            Text("Core Exploit:")
                                .fontWeight(.medium)
                            Text("airlift (AirTraffic sync escape)")
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Image(systemName: "lock.shield.fill")
                                .foregroundColor(.purple)
                            Text("Passcode Themes:")
                                .fontWeight(.medium)
                            Text(".passthm standard (Cowabunga / Nugget)")
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
            
            Button("Close") {
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
            Text("Save Card IDs for Matching")
                .font(.headline)
            Text("Paste one or more card IDs. Saved IDs remain hidden until the connected iPhone exposes them in a scan.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            TextEditor(text: $vm.manualHashInput)
                .font(.system(.body, design: .monospaced))
                .frame(height: 120)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            
            HStack {
                Button("Cancel") {
                    vm.showAddCardSheet = false
                    vm.manualHashInput = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                
                Spacer()
                
                Button("Save IDs") {
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
        panel.message = "Choose a custom skin for card \(cardId.prefix(12))..."
        if panel.runModal() == .OK, let url = panel.url {
            vm.setCardImage(for: cardId, url: url)
        }
    }

    private func downloadAllCardArtwork() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        panel.message = "Choose a folder for the downloaded original card artworks..."
        if panel.runModal() == .OK, let url = panel.url {
            vm.downloadAllCardArtwork(into: url)
        }
    }

    private func downloadOriginalCardArtwork(for cardId: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "AirCard-\(cardId.prefix(12)).png"
        panel.message = "Download the original card artwork for card \(cardId.prefix(12))..."
        panel.prompt = "Download"
        if panel.runModal() == .OK, let url = panel.url {
            vm.downloadOriginalCardArtwork(cardID: cardId, to: url)
        }
    }
    
    private func openBulkImagePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a skin to assign to all selected cards..."
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
        panel.message = "Choose a .passthm passcode theme package..."
        if panel.runModal() == .OK, let url = panel.url {
            vm.inspectPasscodeTheme(url: url)
        }
    }
    
    private func openPosterPicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose Poster Image"
        panel.message = "Select a wallpaper or photo to slice for the passcode keypad..."
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
        panel.title = "Choose Icon for Key \(digit)"
        panel.message = "Select an icon or image for key \(digit)..."
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
            vm.errorMessage = "Please configure at least one key before exporting."
            return
        }
        
        let panel = NSSavePanel()
        panel.title = "Save Passcode Theme"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "CustomTheme.passthm"
        panel.allowedContentTypes = [UTType(filenameExtension: "passthm") ?? .data]
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try PasscodeThemeExporter.exportTheme(keys: keys, targetURL: url)
                vm.statusText = "Theme exported successfully to \(url.lastPathComponent)"
                vm.log("Exported .passthm to \(url.path)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                vm.errorMessage = "Failed to export theme: \(error.localizedDescription)"
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
