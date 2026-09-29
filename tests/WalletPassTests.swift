import Foundation
import CryptoKit
import AppKit

@main struct WalletPassTests {
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        var draft = PassDraft()
        try PassExporter.export(draft, to: temp.appendingPathComponent("draft.zip"), signing: nil)
        let listing = try PassExporter.run("/usr/bin/unzip", ["-Z1", "draft.zip"], at: temp)
        precondition(String(decoding: listing, as: UTF8.self).contains("DRAFT.txt"))
        draft.teamID = "ABCDE12345"
        draft.publicKey = P256.KeyAgreement.PrivateKey().publicKey.derRepresentation.base64EncodedString()
        _ = try draft.json()
        func rejected(_ candidate: PassDraft) {
            do { _ = try candidate.json(); fatalError("Invalid input accepted") } catch {}
        }
        var invalid = draft; invalid.message = String(repeating: "ä", count: 33); rejected(invalid)
        invalid = draft; invalid.publicKey = Data(repeating: 0, count: 91).base64EncodedString(); rejected(invalid)
        invalid = draft; invalid.teamID = "bad"; rejected(invalid)
        invalid = draft; invalid.message = ""; rejected(invalid)
        draft.message = String(repeating: "ä", count: 32); _ = try draft.json()
        try PassExporter.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem", "-out", "cert.pem", "-days", "1", "-subj", "/UID=pass.com.example.access/OU=ABCDE12345/CN=Local Test Only"], at: temp)
        let signing = PassSigning(certificate: temp.appendingPathComponent("cert.pem"), privateKey: temp.appendingPathComponent("key.pem"), intermediate: temp.appendingPathComponent("cert.pem"), password: "")
        draft.artwork = NSImage(size: NSSize(width: 290, height: 182))
        try PassExporter.export(draft, to: temp.appendingPathComponent("test.pkpass"), signing: signing)
        try PassExporter.run("/usr/bin/unzip", ["-q", "test.pkpass", "-d", "unpacked"], at: temp)
        let unpacked = temp.appendingPathComponent("unpacked")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: unpacked.appendingPathComponent("manifest.json"))) as! [String: String]
        for (name, hash) in manifest {
            let actual = Insecure.SHA1.hash(data: try Data(contentsOf: unpacked.appendingPathComponent(name))).map { String(format: "%02x", $0) }.joined()
            precondition(actual == hash)
        }
        precondition(!fm.fileExists(atPath: unpacked.appendingPathComponent("DRAFT.txt").path))
        precondition(!fm.fileExists(atPath: unpacked.appendingPathComponent("key.pem").path))
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: unpacked.appendingPathComponent("icon@3x.png")))!
        precondition(bitmap.pixelsWide == 87 && bitmap.pixelsHigh == 87)
        let strip = NSBitmapImageRep(data: try Data(contentsOf: unpacked.appendingPathComponent("strip@3x.png")))!
        precondition(strip.pixelsWide == 1125 && strip.pixelsHigh == 369)
        let pass = try JSONSerialization.jsonObject(with: Data(contentsOf: unpacked.appendingPathComponent("pass.json"))) as! [String: Any]
        precondition(pass["storeCard"] != nil && pass["generic"] == nil)

        draft.teamID = "ZZZZZ12345"
        do { try PassExporter.export(draft, to: temp.appendingPathComponent("bad.pkpass"), signing: signing); fatalError("Certificate mismatch accepted") } catch {}
        precondition(!fm.fileExists(atPath: temp.appendingPathComponent("bad.pkpass").path))
        print("PASS: draft export, UTF-8 limits, key/ID validation, signed archive, manifest hashes, PNG sizes, certificate mismatch. Test certificate only; no Apple/NFC authorization tested.")
    }
}
