import Foundation

@main struct CertificateImportTests {
    static func main() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        try PassExporter.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem", "-out", "original.pem", "-days", "1", "-subj", "/CN=Import Test"], at: folder)
        try PassExporter.run("/usr/bin/openssl", ["x509", "-in", "original.pem", "-outform", "DER", "-out", "original.cer"], at: folder)
        let original = try Data(contentsOf: folder.appendingPathComponent("original.cer"))
        let target = folder.appendingPathComponent("imports")
        let fromDER = try PassCertificateImporter.importCertificate(folder.appendingPathComponent("original.cer"), into: target)
        let fromPEM = try PassCertificateImporter.importCertificate(folder.appendingPathComponent("original.pem"), into: target)
        let derData = try Data(contentsOf: fromDER)
        let pemData = try Data(contentsOf: fromPEM)
        precondition(derData == pemData)
        let after = try Data(contentsOf: folder.appendingPathComponent("original.cer"))
        precondition(after == original)
        let again = try PassCertificateImporter.importCertificate(folder.appendingPathComponent("original.cer"), into: target)
        precondition(again != fromDER && fm.fileExists(atPath: fromDER.path))
        let count = try fm.contentsOfDirectory(atPath: target.path).count
        do {
            _ = try PassCertificateImporter.importCertificate(folder.appendingPathComponent("key.pem"), into: target)
            fatalError("Private key accepted as certificate")
        } catch {}
        let countAfter = try fm.contentsOfDirectory(atPath: target.path).count
        precondition(count == countAfter)
        print("PASS: CER/PEM conversion, original preserved, repeated imports, invalid file rejection and cleanup")
    }
}
