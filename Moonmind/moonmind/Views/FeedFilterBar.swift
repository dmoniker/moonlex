import SwiftUI

struct FeedFilterBar: View {
    let feeds: [PodcastFeed]
    @ObservedObject var filters: FeedFilters
    let onChange: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(feeds) { feed in
                    let on = filters.isOn(feed.id)
                    Button {
                        filters.setOn(feed.id, !on)
                        onChange()
                    } label: {
                        Text(feed.filterChipLabel)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(on ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
                            .foregroundStyle(on ? Color.accentColor : Color.secondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(feed.filterChipLabel) filter")
                    .accessibilityValue(on ? "on" : "off")
                }
            }
            .padding(.vertical, 6)
        }
    }
}
