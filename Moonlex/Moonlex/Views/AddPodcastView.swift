import SwiftUI

struct AddPodcastView: View {
    @ObservedObject var catalog: FeedCatalog
    var onFeedsChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var urlString = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Your podcasts (RSS)") {
                if catalog.customFeeds.isEmpty {
                    Text("Add any podcast that publishes a public RSS feed.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(catalog.customFeeds) { feed in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(feed.title)
                                .font(.headline)
                            Text(feed.rssURLString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .onDelete(perform: deleteCustom)
                }
            }

            Section("Add feed") {
                TextField("Show title", text: $title)
                TextField("RSS URL", text: $urlString)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
                Button("Add") { add() }
                    .disabled(isAddDisabled)
            }
        }
        .navigationTitle("Podcasts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private var isAddDisabled: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func add() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: u) else {
            errorMessage = FeedCatalogError.invalidURL.localizedDescription
            return
        }
        do {
            try catalog.addCustom(title: t, rssURL: url)
            title = ""
            urlString = ""
            errorMessage = nil
            onFeedsChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteCustom(at offsets: IndexSet) {
        for i in offsets {
            catalog.removeCustom(catalog.customFeeds[i])
        }
        onFeedsChanged()
    }
}
