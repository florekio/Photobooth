import SwiftUI
import AVFoundation
import AppKit

/// The "digital strip": the same vertical 4-cell photo-strip layout as the
/// printable version, but every cell is a looping video of that shot's
/// before + after clips. Sits next to the printable strip and matches its style.
struct DigitalStripView: View {
    let result: SessionResult
    /// Optional decorative frame PNG overlaid on top (windows over the cells).
    var frameURL: URL?
    /// Total height; width follows the fixed 1:3 strip ratio.
    var height: CGFloat = 600

    private var stripWidth: CGFloat { height * StripLayout.stripAspect }
    private var count: Int { min(result.photos.count, StripLayout.count) }
    private var corner: CGFloat {
        StripLayout.cornerRadius / StripLayout.designSize.width * stripWidth
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white

            ForEach(0..<count, id: \.self) { i in
                let n = StripLayout.normalizedCellRect(i)
                LoopingVideoCell(urls: clipURLs(for: i))
                    .frame(width: n.width * stripWidth, height: n.height * height)
                    .clipShape(RoundedRectangle(cornerRadius: corner))
                    .position(x: (n.minX + n.width / 2) * stripWidth,
                              y: (n.minY + n.height / 2) * height)
            }

            if let frameURL, let img = NSImage(contentsOf: frameURL) {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: stripWidth, height: height)
                    .allowsHitTesting(false)
            } else {
                Text(footerText)
                    .font(.system(size: max(9, stripWidth * 0.05), weight: .semibold))
                    .foregroundStyle(.black)
                    .position(x: stripWidth / 2,
                              y: (1 - StripLayout.footerRect.height / StripLayout.designSize.height / 2) * height)
            }
        }
        .frame(width: stripWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner))
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
