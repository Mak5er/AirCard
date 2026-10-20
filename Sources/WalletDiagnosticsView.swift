import SwiftUI

struct WalletDiagnosticsView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject private var l10nManager = LocalizationManager.shared
    @State private var expanded = false

    private var pendingCount: Int {
        vm.pendingPaymentCards.count + vm.pendingMembershipCards.count
    }

    private var headerStatusText: String {
        let matched = vm.currentVerifiedCardIDs.count
        let hidden = max(0, vm.cards.count - matched)
        if vm.isScanningCards {
            return l10n("Scanning iPhone Wallet…", "正在扫描 iPhone 钱包…")
        }
        if matched > 0 {
            return hidden > 0
                ? l10n("\(matched) card(s) verified · \(hidden) hidden", "\(matched) 张卡片已验证 · \(hidden) 张隐藏")
                : l10n("\(matched) card(s) verified", "\(matched) 张卡片已验证")
        }
        return l10n("No cards detected. Tap 'Scan Cards' to begin.", "未检测到卡片。点击“扫描卡片”开始。")
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

                Button(vm.isReadingWalletCache ? l10n("Reading…", "正在读取…") : l10n("Read Cache", "读取缓存")) {
                    vm.refreshWalletCatalog()
                }
                .disabled(vm.isReadingWalletCache || vm.device?.connected != true)
                .help(l10n("Read this Mac's Wallet cache", "读取此 Mac 的钱包缓存"))

                Button(l10n("Reconnect", "重新连接")) {
                    vm.checkDevice()
                }
                .disabled(vm.isCheckingDevice || vm.isFlashing)
            }

            if vm.isScanningCards && !vm.scannerMessage.isEmpty {
                Text(vm.scannerMessage.localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            DisclosureGroup(isExpanded: $expanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let date = vm.walletCatalog.cacheUpdatedAt {
                            Text(l10n("Cache date: \(date.prefix(10))", "缓存日期: \(date.prefix(10))"))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(vm.walletCatalog.warnings, id: \.self) { warning in
                            Label(warning.localized, systemImage: "info.circle")
                        }
                        if vm.walletCatalog.paymentStatus == "matched" && !vm.pendingPaymentCards.isEmpty {
                            Text(l10n("Pending Payment Cards (\(vm.pendingPaymentCards.count)):", "待验证支付卡 (\(vm.pendingPaymentCards.count)):"))
                                .fontWeight(.semibold)
                            ForEach(vm.pendingPaymentCards) { card in pendingRow(card) }
                        }
                        if !vm.pendingMembershipCards.isEmpty {
                            Text(l10n("Pending Passes / Memberships (\(vm.pendingMembershipCards.count)):", "待验证凭证 / 会员卡 (\(vm.pendingMembershipCards.count)):"))
                                .fontWeight(.semibold)
                            ForEach(vm.pendingMembershipCards) { card in pendingRow(card) }
                        }
                        if vm.pendingPaymentCards.isEmpty && vm.pendingMembershipCards.isEmpty {
                            Text(l10n("All cached cards on this Mac have been verified.", "此 Mac 上的所有缓存卡片均已验证。"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .font(.caption)
                }
                .frame(maxHeight: 160)
            } label: {
                Text(pendingCount > 0 ? l10n("Check missing cards (\(pendingCount))", "查看未检测到的卡片 (\(pendingCount))") : l10n("Check missing cards", "查看未检测到的卡片"))
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
            Text(l10n("Not verified", "未验证")).foregroundStyle(.secondary)
        }
    }
}
