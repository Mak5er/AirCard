import AppKit
import CryptoKit

struct PassError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PassDraft {
    var organization = "Example Company"
    var name = "Max Mustermann"
    var employeeID = "EMP-000001"
    var serial = UUID().uuidString
    var passType = "pass.com.example.access"
    var teamID = ""
    var message = "EMP-000001"
    var publicKey = ""
    var authentication = true
    var background = NSColor(red: 0.06, green: 0.10, blue: 0.18, alpha: 1)
    var foreground = NSColor.white
    var logo: NSImage?
    var artwork: NSImage?

    func json(validate: Bool = true) throws -> Data {
        let key = publicKey.filter { !$0.isWhitespace }
        if validate {
            guard [organization, name, employeeID, serial].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw PassError(message: "Please complete the card details.")
            }
            guard passType.range(of: "^pass\\.[A-Za-z0-9.-]+$", options: .regularExpression) != nil,
                  teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
                throw PassError(message: "Enter a Pass Type ID starting with pass. and a 10-character uppercase Team ID.")
            }
            guard (1...64).contains(message.utf8.count) else {
                throw PassError(message: "NFC message must contain 1–64 UTF-8 bytes.")
            }
            let prefix: [UInt8] = [0x30,0x59,0x30,0x13,0x06,0x07,0x2a,0x86,0x48,0xce,0x3d,0x02,0x01,0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07,0x03,0x42,0x00]
            guard let der = Data(base64Encoded: key), der.count == 91, der.starts(with: prefix),
                  (try? P256.KeyAgreement.PublicKey(x963Representation: Data(der.suffix(65)))) != nil else {
                throw PassError(message: "Enter your reader's Base64 P-256 public key in X.509 SubjectPublicKeyInfo format.")
            }
        }
        let object: [String: Any] = [
            "formatVersion": 1, "passTypeIdentifier": passType, "teamIdentifier": teamID,
            "serialNumber": serial, "organizationName": organization,
            "description": "\(organization) employee access pass", "logoText": organization,
            "backgroundColor": Self.rgb(background), "foregroundColor": Self.rgb(foreground),
            "labelColor": Self.rgb(foreground), "sharingProhibited": true,
            (artwork == nil ? "generic" : "storeCard"): [
                "primaryFields": [["key": "employee", "label": "EMPLOYEE", "value": name]],
                "secondaryFields": [["key": "employeeID", "label": "EMPLOYEE ID", "value": employeeID]]
            ],
            "nfc": ["message": message, "encryptionPublicKey": key, "requiresAuthentication": authentication]
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
    static func rgb(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? .black
        return "rgb(\(Int((c.redComponent * 255).rounded())), \(Int((c.greenComponent * 255).rounded())), \(Int((c.blueComponent * 255).rounded())))"
    }
}

struct PassSigning {
    var certificate: URL
    var privateKey: URL
    var intermediate: URL
    var password: String
}

enum PassExporter {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], at directory: URL, input: String = "") throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let outputURL = directory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
        process.standardOutput = output
        process.standardError = output
        let pipe = Pipe()
        process.standardInput = pipe
        try process.run()
        pipe.fileHandleForWriting.write(Data((input + "\n").utf8))
        try? pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        let result = try Data(contentsOf: outputURL)
        guard process.terminationStatus == 0 else {
            throw PassError(message: "\(URL(fileURLWithPath: executable).lastPathComponent): \(String(decoding: result, as: UTF8.self))")
        }
        return result
    }
    static func png(image: NSImage?, size: NSSize, draft: PassDraft) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw PassError(message: "Could not render pass artwork.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        let bounds = NSRect(origin: .zero, size: size)
        NSColor.clear.setFill(); bounds.fill()
        if let image = image, image.size.width > 0, image.size.height > 0 {
            let scale = min(size.width / image.size.width, size.height / image.size.height)
            let scaled = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: (size.width - scaled.width) / 2, y: (size.height - scaled.height) / 2, width: scaled.width, height: scaled.height))
        } else {
            draft.background.setFill(); bounds.fill()
            let text = String(draft.organization.prefix(1)) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: size.height * 0.65), .foregroundColor: draft.foreground]
            let measured = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: (size.width - measured.width) / 2, y: (size.height - measured.height) / 2), withAttributes: attributes)
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw PassError(message: "PNG encoding failed.") }
        return data
    }
    static func export(_ draft: PassDraft, to destination: URL, signing: PassSigning?) throws {
        let json = try draft.json(validate: signing != nil)
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        let bundle = temp.appendingPathComponent("pass")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try json.write(to: bundle.appendingPathComponent("pass.json"))
        for scale in 1...3 {
            let suffix = scale == 1 ? "" : "@\(scale)x"
            try png(image: draft.logo, size: NSSize(width: 29 * scale, height: 29 * scale), draft: draft).write(to: bundle.appendingPathComponent("icon\(suffix).png"))
            if let artwork = draft.artwork {
                try png(image: artwork, size: NSSize(width: 375 * scale, height: 123 * scale), draft: draft).write(to: bundle.appendingPathComponent("strip\(suffix).png"))
            }
            if let logo = draft.logo {
                try png(image: logo, size: NSSize(width: 160 * scale, height: 50 * scale), draft: draft).write(to: bundle.appendingPathComponent("logo\(suffix).png"))
            }
        }
        var manifest: [String: String] = [:]
        for file in try fm.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil) {
            manifest[file.lastPathComponent] = Insecure.SHA1.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: bundle.appendingPathComponent("manifest.json"))
        if let signing = signing {
            let subject = try run("/usr/bin/openssl", ["x509", "-in", signing.certificate.path, "-noout", "-subject", "-nameopt", "sep_multiline"], at: temp)
            let fields = String(decoding: subject, as: UTF8.self).components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.contains("UID=\(draft.passType)"), fields.contains("OU=\(draft.teamID)") else {
                throw PassError(message: "Certificate UID / OU must match the Pass Type ID / Team ID.")
            }
            try run("/usr/bin/openssl", ["x509", "-in", signing.certificate.path, "-checkend", "0", "-noout"], at: temp)
            try run("/usr/bin/openssl", ["smime", "-binary", "-sign", "-signer", signing.certificate.path, "-inkey", signing.privateKey.path, "-certfile", signing.intermediate.path, "-in", bundle.appendingPathComponent("manifest.json").path, "-out", bundle.appendingPathComponent("signature").path, "-outform", "DER", "-passin", "stdin"], at: temp, input: signing.password)
            try run("/usr/bin/openssl", ["smime", "-verify", "-inform", "DER", "-in", bundle.appendingPathComponent("signature").path, "-content", bundle.appendingPathComponent("manifest.json").path, "-noverify", "-out", temp.appendingPathComponent("verified").path], at: temp)
        } else {
            try Data("Unsigned NFC draft. Not installable in Wallet. Apple NFC-enabled signing certificate required.\n".utf8).write(to: bundle.appendingPathComponent("DRAFT.txt"))
        }
        let archive = temp.appendingPathComponent("export.zip")
        let files = try fm.contentsOfDirectory(atPath: bundle.path).sorted()
        try run("/usr/bin/zip", ["-q", "-X", archive.path] + files, at: bundle)
        try Data(contentsOf: archive).write(to: destination, options: .atomic)
    }
}

// Each request owns a fresh directory; existing signing identities are never overwritten.
enum PassSigningKeyGenerator {
    static func generate(in parent: URL, password: String) throws -> (key: URL, request: URL) {
        guard !password.contains("\n"), !password.contains("\r") else {
            throw PassError(message: "The key password cannot contain line breaks.")
        }
        let fm = FileManager.default
        let folder = parent.appendingPathComponent("Wallet-Signing-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? fm.removeItem(at: folder) } }
        let key = folder.appendingPathComponent("signing-key.pem")
        let request = folder.appendingPathComponent("wallet-pass.certSigningRequest")
        // Pre-create with owner-only permissions, before OpenSSL writes key material.
        guard fm.createFile(atPath: key.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw PassError(message: "Could not create the private key file.")
        }
        var arguments = ["genrsa"]
        if !password.isEmpty { arguments += ["-aes256", "-passout", "stdin"] }
        arguments += ["-out", key.path, "2048"]
        try PassExporter.run("/usr/bin/openssl", arguments, at: folder, input: password)
        try PassExporter.run("/usr/bin/openssl", ["req", "-new", "-sha256", "-key", key.path, "-passin", "stdin", "-subj", "/CN=Wallet Pass Signing", "-out", request.path], at: folder, input: password)
        try PassExporter.run("/usr/bin/openssl", ["req", "-in", request.path, "-verify", "-noout"], at: folder)
        completed = true
        return (key, request)
    }
}

enum PassCertificateImporter {
    /// Parse the certificate by content, not its filename. Preserve the original.
    static func importCertificate(_ source: URL, into parent: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = parent.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? fm.removeItem(at: folder) } }
        let destination = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".pem")
        for format in ["PEM", "DER"] {
            do {
                try PassExporter.run("/usr/bin/openssl", ["x509", "-inform", format, "-in", source.path, "-outform", "PEM", "-out", destination.path], at: folder)
                completed = true
                return destination
            } catch {
                // Try the other certificate encoding before reporting a user-facing error.
            }
        }
        throw PassError(message: "This file is not a readable X.509 certificate. Choose an Apple-issued .cer, .crt, .der or .pem certificate. A .certSigningRequest, private key or .p12 identity cannot be used in this certificate field.")
    }
}
