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
    @ObservedObject var downloads: EpisodeDownloadStore
    @ObservedObject var catalog: FeedCatalog

    var onFeedsReset: () -> Void

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
    @AppStorage(EpisodeDownloadStore.storageLimitMegabytesDefaultsKey) private var storageLimitMB = 0

    @Environment(\.dismiss) private var dismiss
    @State private var showClearDownloadsConfirm = false
    @State private var showResetFeedsConfirm = false

    private var storageLimitByteFormatter: ByteCountFormatter {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f
    }

    private var downloadsUsedLabel: String {
        ByteCountFormatter.string(fromByteCount: downloads.totalStoredByteCount(), countStyle: .file)
    }

    private var storageLimitSummary: String {
        if storageLimitMB <= 0 { return "No limit — \(downloadsUsedLabel) stored" }
        let cap = Int64(storageLimitMB) * 1_048_576
        return "\(downloadsUsedLabel) of \(storageLimitByteFormatter.string(fromByteCount: cap))"
    }

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

                Section {
                    Picker("Download storage limit", selection: $storageLimitMB) {
                        Text("Unlimited").tag(0)
                        Text("250 MB").tag(250)
                        Text("500 MB").tag(500)
                        Text("1 GB").tag(1024)
                        Text("2 GB").tag(2048)
                        Text("5 GB").tag(5120)
                        Text("10 GB").tag(10240)
                    }
                    Text(storageLimitSummary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(
                        "When total downloads exceed this limit, older files are removed automatically (by date modified on disk)."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Button {
                        showClearDownloadsConfirm = true
                    } label: {
                        Text("Clear all downloads")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                } header: {
                    Text("Downloads")
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

                Section {
                    Button {
                        showResetFeedsConfirm = true
                    } label: {
                        Text("Reset feeds to defaults")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                } header: {
                    Text("Feeds")
                } footer: {
                    Text(
                        "Removes every feed you added and restores all built-in podcasts and newsletters (Moonshots, Lex Fridman, Innermost Loop, and the Innermost Loop newsletter)."
                    )
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
            .onChange(of: storageLimitMB) { _, _ in
                downloads.enforceStorageLimit()
            }
            .confirmationDialog(
                "Clear all downloads?",
                isPresented: $showClearDownloadsConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear all downloads", role: .destructive) {
                    downloads.clearAllDownloads()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Downloaded episode audio will be removed from this device. You can stream or download again anytime.")
            }
            .confirmationDialog(
                "Reset feeds to defaults?",
                isPresented: $showResetFeedsConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset feeds", role: .destructive) {
                    let removedCustomIDs = catalog.customFeeds.map(\.id)
                    catalog.resetFeedsToFactoryDefaults()
                    for id in removedCustomIDs {
                        downloads.removeAllDownloads(forFeedID: id)
                    }
                    onFeedsReset()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your added shows will be removed and every built-in feed will appear again.")
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
