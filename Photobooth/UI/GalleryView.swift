import SwiftUI
import AVKit

extension SessionResult: Identifiable {
    var id: String { store.root.path }
}

/// Full-screen overlay listing every past session as a grid of strip thumbnails.
/// Tapping one opens a read-only detail with the looping video strip.
struct GalleryView: View {
    var onClose: () -> Void

    @State private var sessions: [SessionResult] = []
    @State private var selected: SessionResult?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 20)]

    var body: some View {
        ZStack {
            Color.black.opacity(0.96).ignoresSafeArea()

            if let selected {
                SessionDetailView(
                    session: selected,
                    onBack: { self.selected = nil },
                    onDelete: { delete(selected) }
                )
            } else {
                grid
            }
        }
        .onAppear { sessions = SessionLibrary.load() }
    }

    private var grid: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Past sessions").font(.largeTitle.weight(.bold)).foregroundStyle(.white)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Label("Close", systemImage: "xmark").labelStyle(.titleAndIcon)
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 40).padding(.top, 30)

            if sessions.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "photo.stack").font(.system(size: 54))
                    Text("No sessions yet").font(.title2)
                    Text("Press Space on the booth screen to make your first strip.")
                        .foregroundStyle(.white.opacity(0.6))
                }
                .foregroundStyle(.white.opacity(0.8))
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(sessions) { session in
                            Button { selected = session } label: { card(session) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(40)
                }
            }
        }
    }

    private func card(_ session: SessionResult) -> some View {
        VStack(spacing: 8) {
            Group {
                if let img = thumbnail(session) {
                    Image(nsImage: img).resizable().scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.1))
                }
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(Self.dateText(session.store.startedAt))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    private func thumbnail(_ session: SessionResult) -> NSImage? {
        if let png = session.stripPNG, let img = NSImage(contentsOf: png) { return img }
        if let first = session.photos.first { return NSImage(contentsOf: first) }
        return nil
    }

    private func delete(_ session: SessionResult) {
        try? SessionLibrary.delete(session)
        sessions.removeAll { $0.id == session.id }
        selected = nil
    }

    static func dateText(_ date: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        return df.string(from: date)
    }
}

/// Read-only view of one past session: the looping video strip next to the
/// printable strip, with reveal / open / delete / back actions.
private struct SessionDetailView: View {
    let session: SessionResult
    var onBack: () -> Void
    var onDelete: () -> Void

    @State private var confirmingDelete = false
    private let stripHeight: CGFloat = 520

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Button { onBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(GalleryView.dateText(session.store.startedAt))
                    .font(.headline).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 40).padding(.top, 30)

            HStack(alignment: .top, spacing: 40) {
                VStack(spacing: 8) {
                    Text("Digital strip (video)").font(.headline).foregroundStyle(.white.opacity(0.8))
                    DigitalStripView(result: session, frameURL: session.frameURL, height: stripHeight)
                }
                VStack(spacing: 8) {
                    Text("Printable strip").font(.headline).foregroundStyle(.white.opacity(0.8))
                    if let png = session.stripPNG, let img = NSImage(contentsOf: png) {
                        Image(nsImage: img).resizable().scaledToFit().frame(height: stripHeight)
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08))
                            .frame(width: 180, height: stripHeight)
                            .overlay(Text("No strip").foregroundStyle(.white.opacity(0.6)))
                    }
                }
            }

            HStack(spacing: 16) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([session.store.root])
                } label: { Label("Reveal in Finder", systemImage: "folder") }

                if let pdf = session.stripPDF {
                    Button { NSWorkspace.shared.open(pdf) } label: {
                        Label("Open strip PDF", systemImage: "printer")
                    }
                }
                if let montage = session.montage {
                    Button { NSWorkspace.shared.open(montage) } label: {
                        Label("Open montage", systemImage: "play.rectangle")
                    }
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .alert("Delete this session?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the photos, videos, and strips for this session.")
        }
    }
}
