import SwiftUI

struct AddPodcastView: View {
    @ObservedObject var catalog: FeedCatalog
    @ObservedObject var downloads: EpisodeDownloadStore
    var onFeedsChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var searchResults: [ITunesPodcastMatch] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?

    @State private var title = ""
    @State private var urlString = ""
    @State private var manualError: String?
    @State private var searchAddError: String?

    var body: some View {
        Form {
            Section {
                if catalog.allFeeds.isEmpty {
                    Text("No shows yet. Search above, add an RSS link manually, or use Settings → Reset feeds to defaults to restore the built-in list.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(catalog.allFeeds) { feed in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(feed.title)
                                .font(.headline)
                            if feed.isBuiltin {
                                Text("Built-in")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(feed.rssURLString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .onDelete(perform: deleteFeed)
                }
            } header: {
                Text("Your feeds")
            } footer: {
                Text("Swipe left to remove any show—including built-ins. To bring back every default show and clear those you added, use Settings.")
            }

            Section {
                TextField("Search Apple Podcasts", text: $searchText)
                    .textInputAutocapitalization(.words)

                if isSearching {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if let searchError {
                    Text(searchError)
                        .foregroundStyle(.red)
                        .font(.footnote)
                } else if let searchAddError {
                    Text(searchAddError)
                        .foregroundStyle(.red)
                        .font(.footnote)
                } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
                          searchResults.isEmpty
                {
                    Text("No matches.")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }

                ForEach(searchResults) { match in
                    Button {
                        addFromSearch(match)
                    } label: {
                        HStack(spacing: 12) {
                            PodcastArtworkView(url: match.artworkURL, size: 48, cornerRadius: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.title)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                if let artist = match.artistName {
                                    Text(artist)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Search Apple Podcasts")
            } footer: {
                Text("Search content courtesy of Apple Podcasts. Shows not listed here can be added below with a direct RSS URL.")
                    .font(.footnote)
            }

            Section("Add manually") {
                TextField("Show title", text: $title)
                TextField("RSS URL", text: $urlString)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                if let manualError {
                    Text(manualError)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
                Button("Add") { addManual() }
                    .disabled(isManualAddDisabled)
            }
        }
        .navigationTitle("Add feeds")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onChange(of: searchText) { _, _ in
            scheduleSearch()
        }
        .onDisappear {
            searchTask?.cancel()
            searchTask = nil
        }
    }

    private var isManualAddDisabled: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count < 2 {
                searchResults = []
                isSearching = false
                searchError = nil
                searchAddError = nil
                return
            }

            isSearching = true
            searchError = nil
            searchAddError = nil
            do {
                let matches = try await ITunesPodcastSearchService.search(term: query)
                guard !Task.isCancelled else { return }
                searchResults = matches
            } catch {
                guard !Task.isCancelled else { return }
                searchResults = []
                searchError = error.localizedDescription
            }
            isSearching = false
        }
    }

    private func addFromSearch(_ match: ITunesPodcastMatch) {
        manualError = nil
        searchAddError = nil
        do {
            try catalog.addCustom(title: match.title, rssURL: match.rssURL)
            searchText = ""
            searchResults = []
            searchError = nil
            onFeedsChanged()
        } catch {
            searchAddError = error.localizedDescription
        }
    }

    private func addManual() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        searchAddError = nil
        guard let url = URL(string: u) else {
            manualError = FeedCatalogError.invalidURL.localizedDescription
            return
        }
        do {
            try catalog.addCustom(title: t, rssURL: url)
            title = ""
            urlString = ""
            manualError = nil
            onFeedsChanged()
        } catch {
            manualError = error.localizedDescription
        }
    }

    private func deleteFeed(at offsets: IndexSet) {
        let feeds = catalog.allFeeds
        for i in offsets {
            let feed = feeds[i]
            downloads.removeAllDownloads(forFeedID: feed.id)
            catalog.removeFeed(feed)
        }
        onFeedsChanged()
    }
}
