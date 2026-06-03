import SwiftUI
import AVFoundation
import AppKit

/// The "digital strip": the same vertical 4-cell photo-strip layout as the
/// printable version, but every cell is a looping video of that shot's
/// before + after clips. Sits next to the printable strip and matches its style.
struct DigitalStripView: View {
    let result: SessionResult
    /// Total height; the strip computes its own width from this + the cell aspect.
    var height: CGFloat = 540

    // Screen-point styling, mirroring PhotoStripRenderer's proportions.
    private let margin: CGFloat = 16
    private let gap: CGFloat = 10
    private let footerHeight: CGFloat = 38
    private let corner: CGFloat = 8

    /// Cell aspect (width / height), taken from the captured photo so the digital
    /// and printable strips line up.
    private var aspect: CGFloat {
        guard let first = result.photos.first,
              let img = NSImage(contentsOf: first), img.size.height > 0 else { return 4.0 / 3.0 }
        return img.size.width / img.size.height
    }

    private var count: Int { result.photos.count }

    private var cellHeight: CGFloat {
        let available = height - margin * 2 - footerHeight - CGFloat(count - 1) * gap
        return max(0, available / CGFloat(count))
    }
    private var cellWidth: CGFloat { cellHeight * aspect }
    private var stripWidth: CGFloat { cellWidth + margin * 2 }

    var body: some View {
        VStack(spacing: gap) {
            ForEach(0..<count, id: \.self) { i in
                LoopingVideoCell(urls: clipURLs(for: i))
                    .frame(width: cellWidth, height: cellHeight)
                    .clipShape(RoundedRectangle(cornerRadius: corner))
            }
            Spacer(minLength: 0)
            Text(footerText)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black)
        }
        .padding(margin)
        .frame(width: stripWidth, height: height)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: corner + 4))
    }

    private func clipURLs(for index: Int) -> [URL] {
        var urls: [URL] = []
        if result.befores.indices.contains(index) { urls.append(result.befores[index]) }
        if result.afters.indices.contains(index) { urls.append(result.afters[index]) }
        return urls
    }

    private var footerText: String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        return "Photobooth · \(df.string(from: result.store.startedAt))"
    }
}

/// One cell: loops a composition of the shot's before+after clips, muted.
private struct LoopingVideoCell: View {
    let urls: [URL]
    @StateObject private var clip = LoopingClip()

    var body: some View {
        PlayerLayerView(player: clip.player)
            .background(.black)
            .onAppear { clip.load(urls) }
            .onDisappear { clip.stop() }
    }
}

/// Builds a single looping player from before+after, concatenated.
@MainActor
private final class LoopingClip: ObservableObject {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    func load(_ urls: [URL]) {
        guard looper == nil, !urls.isEmpty else { return }
        player.isMuted = true
        Task { await build(urls) }
    }

    func stop() {
        player.pause()
        looper = nil
        player.removeAllItems()
    }

    private func build(_ urls: [URL]) async {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }

        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let src = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration) else { continue }
            let range = CMTimeRange(start: .zero, duration: duration)
            try? track.insertTimeRange(range, of: src, at: cursor)
            cursor = cursor + duration
        }
        guard cursor > .zero else { return }

        // Play back at 1.25× by compressing the timeline (survives looping).
        let speed = 1.25
        let scaled = CMTimeMultiplyByFloat64(cursor, multiplier: 1.0 / speed)
        track.scaleTimeRange(CMTimeRange(start: .zero, duration: cursor), toDuration: scaled)

        let item = AVPlayerItem(asset: composition)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.play()
    }
}

/// AVPlayerLayer host with no playback controls, aspect-fill.
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer as? AVPlayerLayer)?.player = player
    }
}
