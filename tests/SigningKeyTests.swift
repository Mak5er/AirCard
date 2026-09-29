import Foundation

@main struct SigningKeyTests {
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        var previous: URL?
        for password in ["", "Local test password 123!"] {
            let result = try PassSigningKeyGenerator.generate(in: temp, password: password)
            precondition(result.key != previous)
            if let previous = previous { precondition(fm.fileExists(atPath: previous.path)) }
            previous = result.key
            let attrs = try fm.attributesOfItem(atPath: result.key.path)
            precondition((attrs[.posixPermissions] as! NSNumber).intValue == 0o600)
            let keyPublic = try PassExporter.run("/usr/bin/openssl", ["pkey", "-in", result.key.path, "-passin", "stdin", "-pubout"], at: temp, input: password)
            let csrPublic = try PassExporter.run("/usr/bin/openssl", ["req", "-in", result.request.path, "-pubkey", "-noout"], at: temp)
            precondition(keyPublic == csrPublic, "CSR must match its private key")
            if !password.isEmpty {
                do {
                    try PassExporter.run("/usr/bin/openssl", ["pkey", "-in", result.key.path, "-passin", "stdin", "-noout"], at: temp, input: "wrong")
                    fatalError("Encrypted key accepted wrong password")
                } catch {}
            }
        }
        print("PASS: plain/encrypted key generation, matching CSR, owner-only permissions, wrong-password rejection and no overwrite")
    }
}
