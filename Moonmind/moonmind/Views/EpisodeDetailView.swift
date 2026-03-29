import SwiftData
import SwiftUI

struct EpisodeDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var saved: [SavedItem]

    let episode: Episode
    @ObservedObject var playback: EpisodePlaybackController
    @ObservedObject var sleepTimer: SleepTimerStore
    @ObservedObject var downloads: EpisodeDownloadStore
    @StateObject private var notesReader = NotesSelectionReader()

    @State private var highlightDraft = ""
    @State private var noteDraft = ""
    @State private var showManualHighlight = false
    @State private var toast: String?
    @State private var newsletterAttributedBody: NSAttributedString?

    private var existingFavorite: SavedItem? {
        saved.first { $0.episodeKey == episode.stableKey && $0.isEpisodeFavorite }
    }

    private var episodePlaybackURL: URL? { downloads.playbackURL(for: episode) }

    /// Remote or downloaded file URLs for this episode (player may hold either while it’s the same show).
    private var episodeAudioURLs: [URL] {
        var urls: [URL] = []
        if let remote = episode.audioURL { urls.append(remote) }
        if let local = downloads.localFileURL(forEpisodeKey: episode.stableKey) { urls.append(local) }
        return urls
    }

    /// True when the global player is playing this episode’s stream or its local file.
    private var isPlaybackBoundToThisEpisode: Bool {
        guard let loaded = playback.loadedMediaURL else { return false }
        return episodeAudioURLs.contains(loaded)
    }

    private var episodeNowPlayingMeta: EpisodeNowPlayingMetadata {
        EpisodeNowPlayingMetadata(
            title: episode.title,
            showTitle: episode.showTitle,
            artworkURL: episode.artworkURL
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(episode.showTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(episode.title)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        if let d = episode.pubDate {
                            Text(d.formatted(date: .long, time: .omitted))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if episode.audioURL != nil {
                        EpisodeDownloadAccessory(episode: episode, downloads: downloads, interactive: true)
                    }
                }

                if episode.audioURL != nil {
                    episodePlayerCard(artworkURL: episode.artworkURL, sleepTimer: sleepTimer)
                } else if episode.feedContentKind == .newsletter, let url = episode.linkURL {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("AI voiceover and full layout are on Substack; this feed only includes the article text in RSS.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Link(destination: url) {
                            Label("Open on Substack", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Label("No audio enclosure in this feed item", systemImage: "waveform.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !episode.descriptionPlain.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(episode.feedContentKind == .newsletter ? "Article" : "Show notes")
                            .font(.headline)
                        SelectableNotesView(
                            text: episode.descriptionPlain,
                            attributedFallback: newsletterAttributedBody,
                            reader: notesReader
                        )
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                        HStack {
                            Button("Save selected text") {
                                if let sel = notesReader.selectedExcerpt {
                                    highlightDraft = sel
                                }
                                showManualHighlight = true
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Paste quote") {
                                showManualHighlight = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                if showManualHighlight {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Highlight")
                            .font(.headline)
                        TextField("Quoted text", text: $highlightDraft, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3 ... 8)
                        TextField("Optional note", text: $noteDraft, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1 ... 4)
                        Button("Save highlight") { saveHighlight() }
                            .buttonStyle(.borderedProminent)
                            .disabled(highlightDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.top, 8)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if existingFavorite != nil {
                    Label("Favorited", systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                } else {
                    Button {
                        saveFavorite()
                    } label: {
                        Label("Favorite episode", systemImage: "star")
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t)
                    .font(.subheadline.weight(.semibold))
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: toast)
        .task(id: episode.stableKey) {
            playback.sleepTimerStore = sleepTimer
            applyPlaybackSource()
            if episode.feedContentKind == .newsletter {
                newsletterAttributedBody = episode.descriptionRaw.attributedArticleFromHTML()
            } else {
                newsletterAttributedBody = nil
            }
        }
        .onChange(of: downloads.changeToken) { _, _ in
            applyPlaybackSource()
        }
    }

    /// Keeps the current player when browsing other episodes or non-audio posts; only syncs metadata when this episode is already loaded.
    private func applyPlaybackSource() {
        guard let url = episodePlaybackURL else { return }
        guard playback.loadedMediaURL == url else { return }
        if playback.load(url: url, nowPlaying: episodeNowPlayingMeta, episodeKey: episode.stableKey) {
            sleepTimer.onNewEpisodeLoaded()
        }
    }

    private func loadThisEpisodeIfNeeded() -> Bool {
        guard let url = episodePlaybackURL else { return false }
        if playback.load(url: url, nowPlaying: episodeNowPlayingMeta, episodeKey: episode.stableKey) {
            sleepTimer.onNewEpisodeLoaded()
        }
        return true
    }

    private func startThisEpisodePlayback() {
        guard loadThisEpisodeIfNeeded() else { return }
        playback.play()
    }

    /// Switches the global player to this episode, starts playback, then runs `body` (e.g. skip or seek).
    private func takeOverThisEpisodeThen(_ body: () -> Void) {
        guard loadThisEpisodeIfNeeded() else { return }
        playback.play()
        body()
    }

    private var detailScrubberCurrentTime: TimeInterval {
        isPlaybackBoundToThisEpisode ? playback.currentTime : 0
    }

    private var detailScrubberSpan: TimeInterval {
        if isPlaybackBoundToThisEpisode {
            playback.duration > 0 ? playback.duration : max(playback.currentTime, 1)
        } else {
            1
        }
    }

    private var detailTransportShowsPause: Bool {
        isPlaybackBoundToThisEpisode && playback.isPlaying
    }

    @ViewBuilder
    private func episodePlayerCard(artworkURL: URL?, sleepTimer: SleepTimerStore) -> some View {
        let span = detailScrubberSpan
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer(minLength: 0)
                PodcastArtworkView(url: artworkURL, size: 220, cornerRadius: 14)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 12) {
                Slider(
                    value: Binding(
                        get: { min(max(detailScrubberCurrentTime, 0), span) },
                        set: { newTime in
                            if isPlaybackBoundToThisEpisode {
                                playback.seek(to: newTime)
                            } else {
                                guard loadThisEpisodeIfNeeded() else { return }
                                playback.seek(to: newTime)
                                playback.play()
                            }
                        }
                    ),
                    in: 0 ... span
                )
                .tint(.accentColor)

                HStack {
                    Text(formatPlaybackTime(detailScrubberCurrentTime))
                    Spacer(minLength: 8)
                    Text(
                        isPlaybackBoundToThisEpisode && playback.duration > 0
                            ? formatPlaybackTime(playback.duration)
                            : "–:–"
                    )
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                HStack(alignment: .center) {
                    HStack(spacing: 4) {
                        skipBackButton(seconds: 15, systemName: "gobackward.15")
                        skipBackButton(seconds: 30, systemName: "gobackward.30")
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        if isPlaybackBoundToThisEpisode {
                            playback.togglePlayback()
                        } else {
                            startThisEpisodePlayback()
                        }
                    } label: {
                        Image(systemName: detailTransportShowsPause ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 52))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(detailTransportShowsPause ? "Pause" : "Play")

                    HStack(spacing: 4) {
                        skipForwardButton(seconds: 30, systemName: "goforward.30")
                        skipForwardButton(seconds: 60, systemName: "goforward.60")
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            HStack(spacing: 12) {
                Menu {
                    ForEach(SleepTimerPreset.allCases) { preset in
                        Button {
                            if isPlaybackBoundToThisEpisode {
                                sleepTimer.applyPreset(preset)
                            } else {
                                takeOverThisEpisodeThen {
                                    sleepTimer.applyPreset(preset)
                                }
                            }
                        } label: {
                            HStack {
                                Text(preset.label)
                                Spacer(minLength: 12)
                                if sleepTimer.preset == preset {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Label(sleepTimerMenuTitle(sleepTimer), systemImage: "moon.zzz.fill")
                            .font(.subheadline.weight(.medium))
                    }
                }
                Spacer(minLength: 8)
                Picker("Speed", selection: Binding(
                    get: { playback.playbackRate },
                    set: { newRate in
                        if isPlaybackBoundToThisEpisode {
                            playback.setPlaybackRate(newRate)
                        } else {
                            guard loadThisEpisodeIfNeeded() else { return }
                            playback.setPlaybackRate(newRate)
                            playback.play()
                        }
                    }
                )) {
                    ForEach(EpisodePlaybackController.playbackRateOptions, id: \.self) { rate in
                        Text(speedSegmentLabel(rate)).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func skipBackButton(seconds: Int, systemName: String) -> some View {
        Button {
            if isPlaybackBoundToThisEpisode {
                playback.skipBackward(by: TimeInterval(seconds))
            } else {
                takeOverThisEpisodeThen {
                    playback.skipBackward(by: TimeInterval(seconds))
                }
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 32))
                .symbolRenderingMode(.hierarchical)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rewind \(seconds) seconds")
    }

    @ViewBuilder
    private func skipForwardButton(seconds: Int, systemName: String) -> some View {
        Button {
            if isPlaybackBoundToThisEpisode {
                playback.skipForward(by: TimeInterval(seconds))
            } else {
                takeOverThisEpisodeThen {
                    playback.skipForward(by: TimeInterval(seconds))
                }
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 32))
                .symbolRenderingMode(.hierarchical)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fast forward \(seconds) seconds")
    }

    private func speedSegmentLabel(_ rate: Float) -> String {
        if abs(rate - 1.0) < 0.001 { return "1×" }
        return String(format: "%.1f×", rate)
    }

    private func sleepTimerMenuTitle(_ store: SleepTimerStore) -> String {
        if store.preset == .off { return "Sleep timer" }
        if store.preset == .endOfEpisode { return "Sleep · End of episode" }
        if let r = store.remainingUntilFire(), r > 0 {
            return "Sleep · \(formatPlaybackTime(r)) left"
        }
        return "Sleep · \(store.preset == .fifteenMinutes ? "15 min" : "30 min")"
    }

    private func formatPlaybackTime(_ t: TimeInterval) -> String {
        guard t.isFinite, !t.isNaN, t >= 0 else { return "0:00" }
        let total = Int(t.rounded(.down))
        let m = total / 60
        let s = total % 60
        if m >= 60 {
            let h = m / 60
            let rm = m % 60
            return String(format: "%d:%02d:%02d", h, rm, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private func flash(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            toast = nil
        }
    }

    private func saveFavorite() {
        if existingFavorite != nil {
            flash("Already in favorites")
            return
        }
        let item = SavedItem(
            episodeKey: episode.stableKey,
            episodeTitle: episode.title,
            showTitle: episode.showTitle,
            feedID: episode.feedID,
            feedURLString: episode.feedURLString,
            audioURLString: episode.audioURL?.absoluteString,
            episodePubDate: episode.pubDate,
            linkURLString: episode.linkURL?.absoluteString,
            excerpt: "",
            note: nil
        )
        modelContext.insert(item)
        flash("Saved to favorites")
    }

    private func saveHighlight() {
        let excerpt = highlightDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty else { return }

        let note = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = SavedItem(
            episodeKey: episode.stableKey,
            episodeTitle: episode.title,
            showTitle: episode.showTitle,
            feedID: episode.feedID,
            feedURLString: episode.feedURLString,
            audioURLString: episode.audioURL?.absoluteString,
            episodePubDate: episode.pubDate,
            linkURLString: episode.linkURL?.absoluteString,
            excerpt: excerpt,
            note: note.isEmpty ? nil : note
        )
        modelContext.insert(item)
        highlightDraft = ""
        noteDraft = ""
        showManualHighlight = false
        flash("Highlight saved")
    }
}
