import Foundation
import Observation

/// Orchestrates the share pipeline: starts the loopback HTTP server and the
/// Cloudflare quick tunnel at app launch, then hands out a public, QR-able URL
/// for each finished session.
@Observable
@MainActor
final class ShareService {
    enum State: Equatable {
        case idle
        case starting              // server up, tunnel negotiating its URL
        case ready                 // public base URL available
        case unavailable(String)   // cloudflared missing / tunnel failed
    }

    private(set) var state: State = .idle
    /// Public base, e.g. https://random-words.trycloudflare.com
    private(set) var publicBaseURL: URL?

    private let server = ShareServer()
    private let tunnel = TunnelController()

    /// Idempotent: safe to call on every app launch / first result. Never blocks
    /// the main thread — the server binds and the tunnel negotiates its URL
    /// asynchronously, and `state` updates as each step completes.
    func startIfNeeded() {
        guard state == .idle else { return }
        state = .starting
        server.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let port):
                    self.startTunnel(localPort: port)
                case .failure(let error):
                    self.state = .unavailable(error.localizedDescription)
                }
            }
        }
    }

    private func startTunnel(localPort: UInt16) {
        tunnel.start(
            localPort: localPort,
            onURL: { [weak self] url in
                Task { @MainActor in
                    self?.publicBaseURL = url
                    self?.state = .ready
                }
            },
            onFailure: { [weak self] message in
                Task { @MainActor in
                    self?.state = .unavailable(message)
                }
            })
    }

    /// Public share URL for a finished session, once the tunnel is ready.
    func shareURL(for store: SessionStore) -> URL? {
        guard let base = publicBaseURL else { return nil }
        return base.appendingPathComponent("s").appendingPathComponent(store.root.lastPathComponent)
    }

    func shutdown() {
        tunnel.stop()
        server.stop()
        state = .idle
        publicBaseURL = nil
    }
}
