import SwiftUI
import SwiftData

struct FavoritesView: View {
    @Query(sort: \SavedItem.createdAt, order: .reverse)
    private var items: [SavedItem]

    @Environment(\.modelContext) private var modelContext
    @Binding var showAppSettings: Bool

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "Nothing saved yet",
                    systemImage: "star",
                    description: Text("Favorite an episode or save a highlight from show notes.")
                )
            } else {
                List {
                    Section("Favorites & highlights") {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(item.showTitle)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if item.isEpisodeFavorite {
                                        Label("Episode", systemImage: "star.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.yellow)
                                    } else {
                                        Label("Highlight", systemImage: "quote.opening")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(item.displayTitle)
                                    .font(.headline)
                                if !item.isEpisodeFavorite {
                                    Text(item.episodeTitle)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                if let note = item.note, !note.isEmpty {
                                    Text(note)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                if let d = item.episodePubDate {
                                    Text(d.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete(perform: delete)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Saved")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ProfileSettingsToolbarButton(showSettings: $showAppSettings)
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets {
            modelContext.delete(items[i])
        }
    }
}
