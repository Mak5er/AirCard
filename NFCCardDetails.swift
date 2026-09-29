import SwiftUI
import UniformTypeIdentifiers

struct NFCCardDetails: View {
    @Binding var draft: PassDraft
    let artwork: NSImage?
    @Environment(\.dismiss) private var dismiss
    @State private var certificate: URL?
    @State private var key: URL?
    @State private var intermediate: URL?
    @State private var password = ""
    @State private var authorized = false
    @State private var status = ""
    @State private var showExportError = false
    @State private var errorTitle = "Export failed"
    @State private var isExporting = false
    @State private var feedbackIsError = false
    @State private var exportedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("NFC Card Details").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("* Required for Apple Wallet export. Drafts can be incomplete.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox("Cardholder") {
                        VStack(alignment: .leading, spacing: 14) {
                            input("Organization", text: $draft.organization, placeholder: "Example Company")
                            input("Full name", text: $draft.name, placeholder: "Max Mustermann")
                            input("Employee / member ID", text: $draft.employeeID, placeholder: "EMP-000001", technical: true)
                            input("Pass serial number", text: $draft.serial, placeholder: "Unique identifier", technical: true)
                        }.padding(10)
                    }
                    GroupBox("Apple Wallet & NFC") {
                        VStack(alignment: .leading, spacing: 14) {
                            input("Pass Type ID", text: $draft.passType, placeholder: "pass.com.example.access", technical: true)
                            input("Apple Team ID", text: $draft.teamID, placeholder: "10 characters, e.g. ABCDE12345", technical: true)
                            input("NFC message", text: $draft.message, placeholder: "Access identifier sent to the reader", technical: true)
                            Text("\(draft.message.utf8.count) / 64 UTF-8 bytes")
                                .font(.caption)
                                .foregroundStyle(draft.message.utf8.count > 64 ? Color.red : Color.secondary)
                            VStack(alignment: .leading, spacing: 6) {
                                requiredLabel("VAS reader public key")
                                TextEditor(text: $draft.publicKey)
                                    .font(.system(.body, design: .monospaced))
                                    .scrollContentBackground(.hidden)
                                    .padding(8)
                                    .frame(height: 88)
                                    .background(Color(nsColor: .textBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                                    .accessibilityLabel("VAS reader public key, required")
                                Text("Base64-encoded P-256 key in SPKI format.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Toggle("Require authentication (optional)", isOn: $draft.authentication)
                        }.padding(10)
                    }
                    GroupBox("Signing certificate") {
                        VStack(alignment: .leading, spacing: 14) {
                            file("Apple NFC pass certificate", value: $certificate, isCertificate: true)
                            VStack(alignment: .leading, spacing: 4) {
                                Link("Apple: request an NFC pass certificate ↗", destination: URL(string: "https://developer.apple.com/wallet/resources/")!)
                                Link("Create your Pass Type ID certificate ↗", destination: URL(string: "https://developer.apple.com/help/account/capabilities/create-wallet-identifiers-and-certificates/")!)
                                Text("After approval, upload the generated certificate request to Apple. Select the issued .cer or .pem file here; conversion is automatic.").foregroundStyle(.secondary)
                            }.font(.caption)
                            file("Private signing key (PEM)", value: $key)
                            Button("Generate private key & Apple request…", action: generateKey)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Creates a new key and matching CSR on this Mac. Enter a password below first to encrypt the key. Existing files are kept.").foregroundStyle(.secondary)
                                Link("Apple: certificate requests explained ↗", destination: URL(string: "https://developer.apple.com/help/account/certificates/create-a-certificate-signing-request/")!)
                            }.font(.caption)
                            file("Apple WWDR intermediate", value: $intermediate, isCertificate: true)
                            VStack(alignment: .leading, spacing: 4) {
                                Link("Download Apple WWDR G4 ↗", destination: URL(string: "https://www.apple.com/certificateauthority/")!)
                                Text("Choose Worldwide Developer Relations – G4 and select the downloaded .cer file here. Conversion is automatic.").foregroundStyle(.secondary)
                            }.font(.caption)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Private key password (if encrypted)").font(.callout.weight(.medium))
                                SecureField("Only required for an encrypted key", text: $password)
                                    .textFieldStyle(.roundedBorder).controlSize(.large)
                                    .accessibilityLabel("Private key password")
                            }
                            Toggle(isOn: $authorized) {
                                requiredLabel("Apple has enabled NFC for this certificate")
                            }
                        }.padding(10)
                    }
                    Text("Wallet displays the design in the image area of a membership pass; its layout differs from this full-card preview. NFC requires an Apple-enabled certificate and a compatible VAS reader.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("The exporter checks the signature and matching IDs, not Apple trust or NFC approval.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(4)
            }
            Divider()
            if !status.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    if isExporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: feedbackIsError ? "exclamationmark.triangle.fill" : (exportedURL == nil ? "info.circle.fill" : "checkmark.circle.fill"))
                            .foregroundStyle(feedbackIsError ? Color.red : (exportedURL == nil ? Color.secondary : Color.green))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(status).font(.callout).textSelection(.enabled)
                        if let url = exportedURL {
                            Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(12)
                    .background((feedbackIsError ? Color.red : Color.accentColor).opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Export draft…") { export(signed: false) }
                Spacer()
                Button("Export for Apple Wallet…") { export(signed: true) }
                    .buttonStyle(.borderedProminent)

            }
        }.padding(24).frame(width: 600, height: 700)
        .disabled(isExporting)
        .interactiveDismissDisabled(isExporting)
        .alert(errorTitle, isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(status)
        }
    }
    private func requiredLabel(_ title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
            Text("*").foregroundStyle(.red)
        }
        .font(.callout.weight(.medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + ", required")
    }
    private func input(_ label: String, text: Binding<String>, placeholder: String, technical: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            requiredLabel(label)
            TextField(placeholder, text: text)
                .font(technical ? .system(.body, design: .monospaced) : .body)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .accessibilityLabel(label + ", required")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func file(_ title: String, value: Binding<URL?>, isCertificate: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            requiredLabel(title)
            HStack {
                Text(value.wrappedValue?.lastPathComponent ?? "No file selected")
                    .foregroundStyle(value.wrappedValue == nil ? Color.secondary : Color.primary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(value.wrappedValue?.path ?? title)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if isCertificate {
                        panel.allowedContentTypes = ["cer", "crt", "der", "pem"].compactMap { UTType(filenameExtension: $0) }
                        panel.message = "Select a certificate. CER / DER files are converted to PEM automatically."
                    }
                    if panel.runModal() == .OK, let source = panel.url {
                        if isCertificate {
                            do {
                                let storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                                    .appendingPathComponent("AirCard/ImportedCertificates")
                                let imported = try PassCertificateImporter.importCertificate(source, into: storage)
                                value.wrappedValue = imported
                                exportedURL = nil
                                feedbackIsError = false
                                status = "\(title): \(source.lastPathComponent) imported as PEM. The original file was preserved."
                            } catch {
                                reportExportError(error.localizedDescription)
                                errorTitle = "Certificate import failed"
                            }
                        } else {
                            value.wrappedValue = source
                        }
                    }
                }.accessibilityLabel("Choose " + title + ", required")
            }.padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
        }
    }
    private func generateKey() {
        exportedURL = nil
        feedbackIsError = false
        let panel = NSOpenPanel()
        panel.title = "Save private key and Apple certificate request"
        panel.message = "Choose a folder. A new Wallet-Signing subfolder will contain your key and CSR."
        panel.prompt = "Generate"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let generated = try PassSigningKeyGenerator.generate(in: directory, password: password)
            key = generated.key
            // A new key cannot be paired with a previously selected certificate.
            certificate = nil
            authorized = false
            status = "Key created and selected. Upload wallet-pass.certSigningRequest to Apple when creating your pass certificate. Keep signing-key.pem on your Mac."
            NSWorkspace.shared.activateFileViewerSelecting([generated.request])
        } catch { status = error.localizedDescription }
    }
    private func reportExportError(_ message: String) {
        errorTitle = "Export failed"
        status = message
        feedbackIsError = true
        exportedURL = nil
        showExportError = true
    }
    private func export(signed: Bool) {
        exportedURL = nil
        feedbackIsError = false
        var signing: PassSigning?
        var exportDraft = draft
        exportDraft.artwork = artwork
        if signed {
            var missing: [String] = []
            if certificate == nil { missing.append("Apple NFC pass certificate (PEM)") }
            if key == nil { missing.append("Private signing key (PEM)") }
            if intermediate == nil { missing.append("Apple WWDR intermediate (PEM)") }
            if !authorized { missing.append("Confirmation of Apple's NFC approval") }
            guard missing.isEmpty else {
                reportExportError("Before exporting, complete:\n• " + missing.joined(separator: "\n• "))
                return
            }
            guard let cert = certificate, let key = key, let wwdr = intermediate else { return }
            do {
                // Check file type before showing Save, including the common CSR/DER mix-up.
                for (file, label) in [(cert, "Apple NFC pass certificate"), (wwdr, "Apple WWDR intermediate")] {
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    let header = String(decoding: try handle.read(upToCount: 8192) ?? Data(), as: UTF8.self)
                    guard header.contains("-----BEGIN CERTIFICATE-----") else {
                        throw PassError(message: "\(label): choose a PEM certificate. A .certSigningRequest is only an application to Apple, not a certificate. Select the certificate again using Choose to import and convert it automatically.")
                    }
                }
                _ = try exportDraft.json()
            } catch {
                reportExportError(error.localizedDescription)
                return
            }
            signing = PassSigning(certificate: cert, privateKey: key, intermediate: wwdr, password: password)
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = signed ? "Sample-Access.pkpass" : "Sample-draft.zip"
        panel.allowedContentTypes = signed ? [UTType(filenameExtension: "pkpass") ?? .data] : [.zip]
        guard panel.runModal() == .OK, let url = panel.url else {
            status = "Export canceled. No file was created."
            return
        }
        isExporting = true
        status = signed ? "Creating and signing Wallet pass…" : "Creating draft…"
        let readyDraft = exportDraft
        let readySigning = signing
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try PassExporter.export(readyDraft, to: url, signing: readySigning) }
            DispatchQueue.main.async {
                isExporting = false
                password = ""
                switch result {
                case .success:
                    exportedURL = url
                    status = signed ? "Wallet pass saved successfully. Send the file to your iPhone and add it in Wallet." : "Draft saved successfully. This ZIP cannot be installed in Wallet."
                case .failure(let error):
                    reportExportError("Export failed; no new file was saved.\n" + error.localizedDescription)
                }
            }
        }
    }
}
