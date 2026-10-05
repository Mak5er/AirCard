import SwiftUI

struct WalletDiagnosticsView: View {
    @ObservedObject var vm: AppViewModel
    @State private var expanded = false

    private var pendingCount: Int {
        vm.pendingPaymentCards.count + vm.pendingMembershipCards.count
    }

    private var headerStatusText: String {
        let matched = vm.currentVerifiedCardIDs.count
        let hidden = max(0, vm.cards.count - matched)
        if vm.device?.connected != true {
            return "No iPhone connected. Open Connection help beside the device indicator."
        }
        if vm.isScanningCards {
            return "Scanning iPhone Wallet…"
        }
        if matched > 0 {
            return hidden > 0 ? "\(matched) card(s) verified · \(hidden) hidden" : "\(matched) card(s) verified"
        }
        return "No cards detected. Tap 'Scan Cards' to begin."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center) {
                Text(headerStatusText)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(vm.currentVerifiedCardIDs.isEmpty ? .secondary : .primary)

                if vm.isScanningCards {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }

                Spacer()

                Button(vm.isReadingWalletCache ? "Reading…" : "Read Cache") {
                    vm.refreshWalletCatalog()
                }
                .disabled(vm.isReadingWalletCache || vm.device?.connected != true)
                .help("Read this Mac's Wallet cache")

                Button("Reconnect") {
                    vm.checkDevice()
                }
                .disabled(vm.isCheckingDevice || vm.isFlashing)
            }

            if vm.isScanningCards && !vm.scannerMessage.isEmpty {
                Text(vm.scannerMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            DisclosureGroup(isExpanded: $expanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let date = vm.walletCatalog.cacheUpdatedAt {
                            Text("Cache date: \(date.prefix(10))")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(vm.walletCatalog.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "info.circle")
                        }
                        if vm.walletCatalog.paymentStatus == "matched" && !vm.pendingPaymentCards.isEmpty {
                            Text("Pending Payment Cards (\(vm.pendingPaymentCards.count)):")
                                .fontWeight(.semibold)
                            ForEach(vm.pendingPaymentCards) { card in pendingRow(card) }
                        }
                        if !vm.pendingMembershipCards.isEmpty {
                            Text("Pending Passes / Memberships (\(vm.pendingMembershipCards.count)):")
                                .fontWeight(.semibold)
                            ForEach(vm.pendingMembershipCards) { card in pendingRow(card) }
                        }
                        if vm.pendingPaymentCards.isEmpty && vm.pendingMembershipCards.isEmpty {
                            Text("All cached cards on this Mac have been verified.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .font(.caption)
                }
                .frame(maxHeight: 160)
            } label: {
                Text(pendingCount > 0 ? "Check missing cards (\(pendingCount))" : "Check missing cards")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .controlSize(.small)
    }

    private func pendingRow(_ card: WalletCachedCard) -> some View {
        HStack {
            Image(systemName: "questionmark.circle").foregroundStyle(.orange)
            Text(card.name)
            Text("…" + card.id.suffix(6))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Text("Not verified").foregroundStyle(.secondary)
        }
    }
}
