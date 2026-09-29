import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NFCCardItem: Identifiable {
    var draft = PassDraft()
    var card = CardItem(id: UUID().uuidString)
    var id: String { card.id }
    init(url: URL? = nil, image: NSImage? = nil) {
        card.customImageURL = url
        card.customImage = image
    }
}

struct NFCCardsView: View {
    @Binding var items: [NFCCardItem]
    @State private var isDropTargeted = false
    @State private var errorMessage = ""
    @State private var editingCard: NFCCardItem?

    private var selectedURLs: [URL] {
        items.filter { $0.card.isSelected }.compactMap { $0.card.customImageURL }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { chooseImages() } label: {
                    Label("Upload Design", systemImage: "photo.badge.plus")
                }.buttonStyle(.borderedProminent)
                Button { items.append(NFCCardItem()) } label: {
                    Label("Add Card", systemImage: "plus")
                }.buttonStyle(.bordered)
                Spacer()
                if !items.isEmpty {
                    Button("Select All") { for i in items.indices { items[i].card.isSelected = true } }.buttonStyle(.link)
                    Button("Deselect All") { for i in items.indices { items[i].card.isSelected = false } }.buttonStyle(.link)
                    Button("Clear All") { items.removeAll() }.buttonStyle(.link).foregroundStyle(.red)
                }
            }.padding(.horizontal, 20).frame(height: 48)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 310, maximum: 360), spacing: 20)], spacing: 20) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        VStack(spacing: 8) {
                            WalletCardView(
                                card: cardBinding(for: item),
                                cardIndex: index,
                                onPickImage: { chooseImages(replacing: item.id) },
                                onClearImage: {
                                    guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
                                    items[i].card.customImage = nil
                                    items[i].card.customImageURL = nil
                                },
                                onDelete: { items.removeAll { $0.id == item.id } },
                                showsCardHash: false
                            )
                            .help(item.card.customImageURL?.lastPathComponent ?? "Assign a card skin")
                            Button("Card details & Wallet export…") {
                                editingCard = item
                            }.buttonStyle(.link).disabled(item.card.customImage == nil)
                        }
                    }
                }.padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isDropTargeted ? Color.accentColor.opacity(0.04) : .clear)
            .dropDestination(for: URL.self) { urls, _ in
                importImages(urls)
                return !urls.isEmpty
            } isTargeted: { isDropTargeted = $0 }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(items.count) NFC cards · \(selectedURLs.count) designs selected")
                    Text(errorMessage.isEmpty ? "Click a card or drop an image to assign a skin." : errorMessage)
                        .font(.caption).foregroundStyle(errorMessage.isEmpty ? Color.secondary : .red)
                }
                Spacer()
                Button("Show Selected Files") {
                    NSWorkspace.shared.activateFileViewerSelecting(selectedURLs)
                }.disabled(selectedURLs.isEmpty)
            }.padding(.horizontal, 20).padding(.vertical, 12)
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .sheet(item: $editingCard) { item in
            NFCCardDetails(
                draft: Binding(
                    get: { items.first(where: { $0.id == item.id })?.draft ?? item.draft },
                    set: { draft in
                        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
                        items[index].draft = draft
                    }
                ),
                artwork: item.card.customImage
            )
        }
    }

    // ID-based lookup remains safe if a delayed drop finishes after a card was removed.
    private func cardBinding(for item: NFCCardItem) -> Binding<CardItem> {
        Binding(get: { items.first(where: { $0.id == item.id })?.card ?? item.card }, set: { card in
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            items[index].card = card
        })
    }
    private func chooseImages(replacing id: String? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = id == nil
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { importImages(panel.urls, replacing: id) }
    }
    private func importImages(_ urls: [URL], replacing id: String? = nil) {
        var failures: [String] = []
        for url in urls {
            guard url.isFileURL, let image = NSImage(contentsOf: url), image.isValid else {
                failures.append(url.lastPathComponent)
                continue
            }
            if let index = items.firstIndex(where: { id != nil ? $0.id == id : $0.card.customImage == nil }) {
                items[index].card.customImageURL = url
                items[index].card.customImage = image
                items[index].card.isSelected = true
            } else if !items.contains(where: { $0.card.customImageURL?.standardizedFileURL == url.standardizedFileURL }) {
                items.append(NFCCardItem(url: url, image: image))
            }
        }
        errorMessage = failures.isEmpty ? "" : "Could not load: " + failures.joined(separator: ", ")
    }
}
