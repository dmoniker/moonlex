import SwiftUI

struct FeedFilterBar: View {
    let feeds: [PodcastFeed]
    let scope: FeedFilterBarScope
    @ObservedObject var filters: FeedFilters
    let onChange: () -> Void

    private var exclusiveID: String? { filters.exclusiveFeedID(for: scope) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                chipButton(
                    label: "All",
                    selected: exclusiveID == nil,
                    accessibilityBase: scope == .newsletter ? "All newsletters" : "All podcasts"
                ) {
                    filters.selectExclusive(nil, scope: scope)
                    onChange()
                }
                ForEach(feeds) { feed in
                    let on = filters.isOn(feed.id, scope: scope)
                    chipButton(
                        label: feed.filterChipLabel,
                        selected: on,
                        accessibilityBase: "\(feed.filterChipLabel) filter"
                    ) {
                        filters.selectExclusive(feed.id, scope: scope)
                        onChange()
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func chipButton(
        label: String,
        selected: Bool,
        accessibilityBase: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityBase)
        .accessibilityValue(selected ? "selected" : "not selected")
    }
}
