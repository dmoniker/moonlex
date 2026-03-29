import SwiftUI

// MARK: - Profile (system-style glyph; Contacts “My Card” photo API is not available on iOS)

struct ProfileToolbarAvatarView: View {
    var diameter: CGFloat = 30

    var body: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary, .quaternary)
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

struct ProfileSettingsToolbarButton: View {
    @Binding var showSettings: Bool
    var diameter: CGFloat = 30

    var body: some View {
        Button {
            showSettings = true
        } label: {
            ProfileToolbarAvatarView(diameter: diameter)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }
}

// MARK: - Settings sheet

struct AppSettingsSheetView: View {
    @ObservedObject var playback: EpisodePlaybackController

    @AppStorage(EpisodePlaybackController.autoplayNextDefaultsKey) private var autoplayNextInFeed = false
    @AppStorage(EpisodePlaybackController.playbackRateSlowDefaultsKey) private var slowRateStored = Double(EpisodePlaybackController.defaultSlowPlaybackRate)
    @AppStorage(EpisodePlaybackController.playbackRateFastDefaultsKey) private var fastRateStored = Double(EpisodePlaybackController.defaultFastPlaybackRate)

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Autoplay next episode", isOn: $autoplayNextInFeed)
                    Text("When an episode finishes, starts the next one with audio in your feed (newest-first order).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Playback speed") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Slow")
                            Spacer()
                            Text(String(format: "%.2f×", Float(slowRateStored)))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: $slowRateStored,
                            in: Double(EpisodePlaybackController.slowRateRange.lowerBound)...Double(EpisodePlaybackController.slowRateRange.upperBound),
                            step: 0.05
                        ) {
                            Text("Slow")
                        } minimumValueLabel: {
                            Text(String(format: "%.1f×", EpisodePlaybackController.slowRateRange.lowerBound))
                                .font(.caption2)
                        } maximumValueLabel: {
                            Text(String(format: "%.1f×", EpisodePlaybackController.slowRateRange.upperBound))
                                .font(.caption2)
                        }
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Fast")
                            Spacer()
                            Text(String(format: "%.2f×", Float(fastRateStored)))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: $fastRateStored,
                            in: Double(EpisodePlaybackController.fastRateRange.lowerBound)...Double(EpisodePlaybackController.fastRateRange.upperBound),
                            step: 0.05
                        ) {
                            Text("Fast")
                        } minimumValueLabel: {
                            Text(String(format: "%.1f×", EpisodePlaybackController.fastRateRange.lowerBound))
                                .font(.caption2)
                        } maximumValueLabel: {
                            Text(String(format: "%.1f×", EpisodePlaybackController.fastRateRange.upperBound))
                                .font(.caption2)
                        }
                    }
                    .padding(.vertical, 4)

                    Text("The player uses three speeds: slow, normal (1×), and fast.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: slowRateStored) { _, _ in
                playback.refreshPlaybackRateTiersFromUserDefaults()
            }
            .onChange(of: fastRateStored) { _, _ in
                playback.refreshPlaybackRateTiersFromUserDefaults()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
