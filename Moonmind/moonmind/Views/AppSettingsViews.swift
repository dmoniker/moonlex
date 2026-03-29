import SwiftUI

// MARK: - Settings toolbar

struct SettingsToolbarButton: View {
    @Binding var showSettings: Bool

    var body: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }
}

// MARK: - Settings sheet

struct AppSettingsSheetView: View {
    @ObservedObject var playback: EpisodePlaybackController

    @AppStorage(EpisodePlaybackController.autoplayNextDefaultsKey) private var autoplayNextInFeed = false
    @AppStorage(EpisodePlaybackController.autoplayScopeDefaultsKey) private var autoplayScopeRaw =
        EpisodePlaybackController.AutoplayScope.feed.rawValue
    @AppStorage(EpisodePlaybackController.playbackRateSlowDefaultsKey) private var slowRateStored = Double(EpisodePlaybackController.defaultSlowPlaybackRate)
    @AppStorage(EpisodePlaybackController.playbackRateFastDefaultsKey) private var fastRateStored = Double(EpisodePlaybackController.defaultFastPlaybackRate)
    @AppStorage(EpisodePlaybackController.skipBackLeftDefaultsKey) private var skipBackLeft =
        Double(EpisodePlaybackController.defaultSkipBackLeft)
    @AppStorage(EpisodePlaybackController.skipBackRightDefaultsKey) private var skipBackRight =
        Double(EpisodePlaybackController.defaultSkipBackRight)
    @AppStorage(EpisodePlaybackController.skipForwardLeftDefaultsKey) private var skipForwardLeft =
        Double(EpisodePlaybackController.defaultSkipForwardLeft)
    @AppStorage(EpisodePlaybackController.skipForwardRightDefaultsKey) private var skipForwardRight =
        Double(EpisodePlaybackController.defaultSkipForwardRight)

    @Environment(\.dismiss) private var dismiss

    private var skipSecondsBounds: ClosedRange<Double> {
        Double(EpisodePlaybackController.skipSecondsMin)...Double(EpisodePlaybackController.skipSecondsMax)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Autoplay next episode", isOn: $autoplayNextInFeed)
                    if autoplayNextInFeed {
                        Picker("Autoplay from", selection: $autoplayScopeRaw) {
                            Text("Entire feed").tag(EpisodePlaybackController.AutoplayScope.feed.rawValue)
                            Text("Same show").tag(EpisodePlaybackController.AutoplayScope.sameShow.rawValue)
                        }
                    }
                    Text(
                        "When an episode finishes, plays the next not-fully-played episode with audio (newest-first order). Choose the whole feed or only the same podcast or newsletter. Stops if there isn’t a match."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section("Skip buttons") {
                    Stepper(
                        "Rewind, inner: \(Int(skipBackLeft.rounded())) s",
                        value: $skipBackLeft,
                        in: skipSecondsBounds,
                        step: 5
                    )
                    Stepper(
                        "Rewind, outer: \(Int(skipBackRight.rounded())) s",
                        value: $skipBackRight,
                        in: skipSecondsBounds,
                        step: 5
                    )
                    Stepper(
                        "Fast-forward, inner: \(Int(skipForwardLeft.rounded())) s",
                        value: $skipForwardLeft,
                        in: skipSecondsBounds,
                        step: 5
                    )
                    Stepper(
                        "Fast-forward, outer: \(Int(skipForwardRight.rounded())) s",
                        value: $skipForwardRight,
                        in: skipSecondsBounds,
                        step: 5
                    )
                    Button {
                        resetSkipIntervalsToDefaults()
                    } label: {
                        Text("Reset")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
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
            .onChange(of: skipBackLeft) { _, _ in
                playback.refreshSkipIntervalsFromUserDefaults()
            }
            .onChange(of: skipBackRight) { _, _ in
                playback.refreshSkipIntervalsFromUserDefaults()
            }
            .onChange(of: skipForwardLeft) { _, _ in
                playback.refreshSkipIntervalsFromUserDefaults()
            }
            .onChange(of: skipForwardRight) { _, _ in
                playback.refreshSkipIntervalsFromUserDefaults()
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func resetSkipIntervalsToDefaults() {
        let c = EpisodePlaybackController.self
        let ud = UserDefaults.standard
        ud.set(c.defaultSkipBackLeft, forKey: c.skipBackLeftDefaultsKey)
        ud.set(c.defaultSkipBackRight, forKey: c.skipBackRightDefaultsKey)
        ud.set(c.defaultSkipForwardLeft, forKey: c.skipForwardLeftDefaultsKey)
        ud.set(c.defaultSkipForwardRight, forKey: c.skipForwardRightDefaultsKey)
        skipBackLeft = c.defaultSkipBackLeft
        skipBackRight = c.defaultSkipBackRight
        skipForwardLeft = c.defaultSkipForwardLeft
        skipForwardRight = c.defaultSkipForwardRight
        playback.refreshSkipIntervalsFromUserDefaults()
    }
}
