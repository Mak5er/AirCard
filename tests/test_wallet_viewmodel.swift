import Foundation

@main
struct WalletViewModelTests {
    @MainActor
    static func main() {
        let suite = "AirCardWalletTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = String(repeating: "A", count: 27) + "="
        let b = String(repeating: "B", count: 27) + "="
        let c = String(repeating: "C", count: 27) + "="
        defaults.set([b, a, b], forKey: "mak5er.aircard.savedCards")
        let vm = AppViewModel(cardDefaults: defaults, connectOnLaunch: false)
        precondition(vm.cards.map(\.id) == [b, a])
        precondition(vm.currentVerifiedCards.isEmpty) // Saved records stay hidden until this scan sees them.
        precondition(vm.confirmedCardIDs.isEmpty) // Legacy IDs have no device provenance.
        vm.activateCardDevice("first-phone")
        vm.isScanningCards = true
        vm.walletCatalog = WalletCatalog(paymentStatus: "matched", payments: [
            .init(id: a, name: "Active A", source: "payment"),
            .init(id: b, name: "Active B", source: "payment")
        ], memberships: [], warnings: [], cacheUpdatedAt: nil)
        vm.reconcileMatchedPaymentCards()
        precondition(vm.currentVerifiedCards.isEmpty) // A cache alone is not enough.
        vm.recordScannedCard(a)
        vm.recordScannedCard(a)
        precondition(vm.currentScanIDs == [a] && vm.confirmedCardIDs == [a, b])
        precondition(vm.currentVerifiedCardIDs == [a]) // Cache-only B is not live-verified (#168).
        precondition(vm.currentCacheImportedIDs == [b])
        precondition(vm.cards.count == 2)
        vm.recordScannedCard(b)
        precondition(vm.currentVerifiedCardIDs == [a, b])
        vm.isScanningCards = false
        let activation = "A00000000310100100000020"
        precondition(!vm.recordActivatedPaymentCard(activation))
        vm.walletCatalog = WalletCatalog(paymentStatus: "matched", payments: [.init(id: b, name: "Active B", source: "payment", activationID: activation)], memberships: [], warnings: [], cacheUpdatedAt: nil)
        vm.reconcilePendingPaymentActivations()
        precondition(vm.cards.first(where: { $0.id == b })?.displayName == "Active B")
        vm.cards[0].customImageURL = URL(fileURLWithPath: "/skin-b.png")
        vm.cards[1].customImageURL = URL(fileURLWithPath: "/skin-a.png")
        vm.cards.reverse()
        vm.activateCardDevice("second-phone")
        precondition(vm.confirmedCardIDs.isEmpty)
        precondition(vm.cards.allSatisfy { $0.customImageURL == nil })
        vm.recordScannedCard(b)
        vm.activateCardDevice("first-phone")
        precondition(vm.cards.map(\.id) == [a, b])
        precondition(vm.confirmedCardIDs == [a, b])
        precondition(vm.cards[0].customImageURL?.path == "/skin-a.png")
        precondition(vm.cards[1].customImageURL?.path == "/skin-b.png")
        vm.clearAllCards()
        vm.activateCardDevice("second-phone")
        precondition(vm.confirmedCardIDs == [b])
        vm.activateCardDevice("first-phone")
        precondition(vm.cards.isEmpty) // Clear must not resurrect legacy JSON/defaults.
        let relaunched = AppViewModel(cardDefaults: defaults, connectOnLaunch: false)
        relaunched.activateCardDevice("first-phone")
        precondition(relaunched.cards.isEmpty)
        relaunched.activateCardDevice("second-phone")
        precondition(relaunched.confirmedCardIDs == [b])
        let countBeforePreload = relaunched.cards.count
        relaunched.recordPreloadedCard(c)
        relaunched.recordPreloadedCard(c)
        precondition(relaunched.cards.count == countBeforePreload + 1)
        precondition(relaunched.cards.first(where: { $0.id == c })?.confirmed == true)
        precondition(relaunched.currentVerifiedCards.map(\.id) == [c])
        print("Wallet view model migration, device isolation, repeat scans, skin identity and clear/relaunch passed")
    }
}
