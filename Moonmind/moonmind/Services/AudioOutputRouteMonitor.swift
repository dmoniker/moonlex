import AVFoundation
import Combine
import Foundation

/// Tracks the active playback output (iPhone speaker, AirPods, AirPlay, etc.) via `AVAudioSession`.
@MainActor
final class AudioOutputRouteMonitor: ObservableObject {
    @Published private(set) var outputName = "iPhone"
    @Published private(set) var iconName = "iphone"

    private var routeChangeObserver: NSObjectProtocol?

    func start() {
        refresh()
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stop() {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
        }
    }

    private func refresh() {
        let output = Self.preferredOutput(from: AVAudioSession.sharedInstance().currentRoute)
        outputName = Self.friendlyName(for: output)
        iconName = Self.iconName(for: output)
    }

    private static func preferredOutput(from route: AVAudioSessionRouteDescription) -> AVAudioSessionPortDescription? {
        route.outputs.first
    }

    private static func friendlyName(for output: AVAudioSessionPortDescription?) -> String {
        guard let output else { return "iPhone" }
        switch output.portType {
        case .builtInSpeaker, .builtInReceiver:
            return "iPhone"
        default:
            let name = output.portName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Speaker" : name
        }
    }

    private static func iconName(for output: AVAudioSessionPortDescription?) -> String {
        guard let output else { return "iphone" }
        switch output.portType {
        case .builtInSpeaker, .builtInReceiver:
            return "iphone"
        case .headphones, .headsetMic:
            return "headphones"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            let lower = output.portName.lowercased()
            if lower.contains("airpod") { return "airpodspro" }
            return "headphones"
        case .airPlay:
            return "airplayaudio"
        case .carAudio:
            return "car.fill"
        default:
            return "speaker.wave.2.fill"
        }
    }
}
