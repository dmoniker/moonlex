import AVKit
import SwiftUI

/// Podcast-style output picker: shows the current device name and opens the system route sheet on tap.
struct AudioRoutePickerControl: View {
    @StateObject private var routeMonitor = AudioOutputRouteMonitor()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: routeMonitor.iconName)
            Text(routeMonitor.outputName)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .overlay {
            AudioRoutePickerRepresentable()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio output")
        .accessibilityValue(routeMonitor.outputName)
        .accessibilityHint("Opens audio output options")
        .onAppear { routeMonitor.start() }
        .onDisappear { routeMonitor.stop() }
    }
}

private struct AudioRoutePickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = .clear
        picker.activeTintColor = .clear
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
