# NFC Wallet pass export

## Create an NFC Wallet pass

1. Open **NFC Cards**.
2. Click a card or drag an image onto it. **Upload Design** supports multiple images; **Add Card** creates another empty card.
3. Click **Card details & Wallet export…** under the card.
4. Enter the organization, name, employee/member ID and unique pass serial number.
5. Enter the registered Pass Type ID, Apple Team ID, NFC message and VAS reader public key.
6. Select the signing certificate and Apple WWDR intermediate as CER, CRT, DER or PEM; they are automatically imported as PEM. Select the matching private key in PEM format.
7. Confirm NFC authorization only after Apple has enabled NFC for your certificate.
8. Choose **Export for Apple Wallet…**, then transfer the `.pkpass` file to the iPhone using AirDrop, Mail or a website and open it in Wallet.

The prefilled organization (`Example Company`), name (`Max Mustermann`), employee ID (`EMP-000001`) and Pass Type ID (`pass.com.example.access`) are sample data. Replace them with your own values. Team ID, reader key and signing credentials must be supplied by the user.

Fields marked with a red **\*** are required for signed export. **Export draft…** creates a ZIP without a signature and permits incomplete fields. Draft ZIPs cannot be installed in Wallet.

The uploaded design is fitted into the image strip of a membership-style Wallet pass. Wallet controls the final layout, so it will differ from the full-card artwork preview. Card data and artwork remain available when switching tabs, but are not saved across app restarts. There is no draft-import interface.

### Where to get the required values

| Field | Source |
| --- | --- |
| **Pass Type ID** | Register an identifier such as `pass.com.example.access` in your Apple Developer account. The app's example value is not a registration. |
| **Apple Team ID** | Your Apple Developer account → **Membership details**. |
| **NFC message** | The identifier/payload your reader system expects, between 1 and 64 UTF-8 bytes. |
| **VAS reader public key** | Your VAS reader integration: Base64-encoded P-256 public key in X.509 SubjectPublicKeyInfo format. The corresponding private key remains with that reader system. |
| **Apple NFC pass certificate** | Issued through your Apple Developer account following the required NFC approval. A normal pass certificate alone is insufficient. |
| **Private signing key** | Generate locally with the button described below, or select the key matching an existing certificate. |
| **Apple WWDR intermediate** | Download **Worldwide Developer Relations – G4** from [Apple PKI](https://www.apple.com/certificateauthority/) ; the app converts it automatically. |
| **Private key password** | Required only if the selected private key is encrypted. |

Useful Apple resources, also linked directly below the app's certificate fields:

- [Wallet resources and NFC PassKit certificate request](https://developer.apple.com/wallet/resources/)
- [Create Wallet identifiers and certificates](https://developer.apple.com/help/account/capabilities/create-wallet-identifiers-and-certificates/)
- [Find your Team ID](https://developer.apple.com/help/glossary/team-id/)
- [Create a certificate signing request](https://developer.apple.com/help/account/certificates/create-a-certificate-signing-request/)
- [WWDR intermediate certificates](https://developer.apple.com/help/account/certificates/wwdr-intermediate-certificates/)

### Generate a private key and Apple certificate request

1. If you want an encrypted key, enter its password in **Private key password** first. An empty password produces an unencrypted key.
2. Click **Generate private key & Apple request…** and choose a destination folder.
3. The app creates a fresh `Wallet-Signing-…` folder containing:
   - `signing-key.pem`: your RSA-2048 private signing key, automatically selected in the app.
   - `wallet-pass.certSigningRequest`: the matching certificate request (CSR), shown in Finder.
4. Upload **only the CSR** to Apple when creating your pass certificate. Keep the private key on your Mac.
5. Download the issued certificate and select it in the app; CER/DER conversion to PEM is automatic.

Generation runs locally and does not upload files. Existing files are not overwritten. The generated folder has owner-only permissions (`0700`), and the key file has permissions `0600`. A newly generated key clears any previously selected pass certificate and NFC confirmation because it requires a matching certificate. Certificate selections last for the detail sheet session; the password is cleared after export.

The signing key is separate from the VAS reader key. Generating it does not grant Apple NFC authorization or make a reader VAS-compatible.

### Import downloaded certificates

The certificate Choose buttons accept `.cer`, `.crt`, `.der` and `.pem`. The app validates X.509 content and imports a PEM copy into `~/Library/Application Support/AirCard/ImportedCertificates/` without modifying the original. CSR, private-key and P12 files are rejected in certificate fields. This format check does not establish Apple trust or NFC authorization.

### Manual conversion (optional)

Run these commands in the folder containing the downloaded files, adjusting filenames as necessary:

```sh
openssl x509 -inform DER -in pass.cer -out pass.pem
openssl x509 -inform DER -in AppleWWDRCAG4.cer -out wwdr-g4.pem
```

If you already exported a signing identity from Keychain Access as `pass.p12`, extract its private key with:

```sh
openssl pkcs12 -in pass.p12 -nocerts -out signing-key.pem
```

OpenSSL prompts for the P12 import password and a password to protect the output key. This extraction is unnecessary when the key was generated directly in AirCard.

### Export validation and current limits

Signed export checks required values, the NFC message byte limit, the reader public key, certificate UID/OU against the pass/team IDs, and certificate expiry. It creates a SHA-1 manifest and detached PKCS#7 signature, includes the intermediate certificate, and verifies the detached signature before writing the archive.

It does **not** validate Apple certificate-chain trust or independently verify NFC approval. The NFC checkbox records your confirmation. Actual installation requires an appropriate Apple-issued certificate; contactless use also requires a compatible Apple VAS reader and the access-system integration. This app does not provision a Secure Element access applet, emulate an arbitrary card UID, or implement an ESP32 reader.

Local signing tests use disposable test certificates. End-to-end installation and NFC access with an Apple-authorized certificate and physical reader have not been validated for this extension.

## Build and tests

Build from the repository root with `bash build.sh`, then open `build/AirCard.app`.

```sh
mkdir -p .tmp
swiftc WalletPassExporter.swift tests/WalletPassTests.swift -o .tmp/wallet-pass-tests
.tmp/wallet-pass-tests
swiftc WalletPassExporter.swift tests/SigningKeyTests.swift -o .tmp/signing-key-tests
.tmp/signing-key-tests
swiftc WalletPassExporter.swift tests/CertificateImportTests.swift -o .tmp/certificate-import-tests
.tmp/certificate-import-tests
```

The tests use temporary files and disposable certificates. They do not access an
iPhone or test Apple NFC approval. Contactless Pass Provisioning for employee
access credentials is a separate integration and is not implemented here.
