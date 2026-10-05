import Foundation

@MainActor
final class FailingArtworkProbeModel: AppViewModel {
    var probeRuns = 0
    override func refreshRemoteArtworkAvailability() {
        probeRuns += 1
        finishRemoteArtworkProbe(failed: true)
    }
}

@main
struct WalletViewModelTests {
    @MainActor
    static func main() async throws {
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
        precondition(vm.currentVerifiedCardIDs == [a, b])
        precondition(vm.cards.count == 2)
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
        precondition(relaunched.currentVerifiedCardIDs.isEmpty)
        precondition(relaunched.hasArtworkCardEvidence(b)) // A saved confirmed card can download after relaunch.
        precondition(!relaunched.hasArtworkCardEvidence(a)) // Other-device cards stay ineligible.
        relaunched.cards.append(CardItem(id: a))
        precondition(!relaunched.hasArtworkCardEvidence(a)) // An unconfirmed saved ID is insufficient.
        let countBeforePreload = relaunched.cards.count
        relaunched.recordPreloadedCard(c)
        relaunched.recordPreloadedCard(c)
        precondition(relaunched.cards.count == countBeforePreload + 1)
        precondition(relaunched.cards.first(where: { $0.id == c })?.confirmed == true)
        precondition(relaunched.currentVerifiedCards.map(\.id) == [c])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = directory.appendingPathComponent("card.png")
        let pdf = directory.appendingPathComponent("card.pdf")
        let conflict = directory.appendingPathComponent("card (1).pdf")
        try Data("download".utf8).write(to: png)
        try Data("existing".utf8).write(to: pdf)
        try Data("another existing".utf8).write(to: conflict)
        let saved = vm.matchExtension(of: png, to: ".pdf")
        precondition(saved.lastPathComponent == "card (2).pdf")
        let originalPDF = try Data(contentsOf: pdf)
        let originalConflict = try Data(contentsOf: conflict)
        let downloaded = try Data(contentsOf: saved)
        precondition(originalPDF == Data("existing".utf8))
        precondition(originalConflict == Data("another existing".utf8))
        precondition(downloaded == Data("download".utf8))

        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        parent.arguments = ["-c", """
        import signal, subprocess
        signal.signal(signal.SIGTERM, lambda *args: print('cancel requested', flush=True))
        child = subprocess.run(['/usr/bin/python3', '-c', "import time; print('ready', flush=True); time.sleep(0.5); print('restored', flush=True)"])
        print('child exit', child.returncode, flush=True)
        """]
        let output = Pipe()
        parent.standardOutput = output
        try parent.run()
        let ready = try output.fileHandleForReading.read(upToCount: 6)
        precondition(ready == Data("ready\n".utf8))
        AppViewModel.sendArtworkCancelSignal(parent)
        let finished = output.fileHandleForReading.readDataToEndOfFile()
        parent.waitUntilExit()
        let cancellationLog = String(data: finished, encoding: .utf8)!
        precondition(cancellationLog.contains("cancel requested"))
        precondition(cancellationLog.contains("restored"))
        precondition(cancellationLog.contains("child exit 0"))

        let failing = FailingArtworkProbeModel(cardDefaults: defaults, connectOnLaunch: false)
        failing.scheduleRemoteArtworkProbe(after: 0)
        try await Task.sleep(nanoseconds: 7_000_000_000)
        precondition(failing.probeRuns == 3) // Initial attempt and two retries.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        precondition(failing.probeRuns == 3) // No endless retry.
        print("Wallet view model migration, device isolation, repeat scans, skin identity and clear/relaunch passed")
    }
}
