import Foundation

/// Runs a free Cloudflare **Quick Tunnel** (`cloudflared tunnel --url …`) that
/// exposes the loopback share server at a public `https://*.trycloudflare.com`
/// URL — no Cloudflare account or login required. The public URL is scraped
/// from cloudflared's startup output.
final class TunnelController {
    private var process: Process?
    private let lock = NSLock()
    private var reported = false

    /// Locations Homebrew / manual installs drop the binary. A GUI app doesn't
    /// inherit the shell `PATH`, so we probe explicit paths.
    static func findBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/cloudflared",  // Apple-silicon Homebrew
            "/usr/local/bin/cloudflared",     // Intel Homebrew
            "/usr/bin/cloudflared",
            "/opt/local/bin/cloudflared",     // MacPorts
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Launch the tunnel pointing at `localhost:port`. `onURL` fires once with
    /// the public base URL; `onFailure` fires if the binary is missing or the
    /// tunnel never produced a URL.
    func start(localPort: UInt16,
               onURL: @escaping (URL) -> Void,
               onFailure: @escaping (String) -> Void) {
        guard let binary = Self.findBinary() else {
            onFailure("cloudflared is not installed. Run: brew install cloudflared")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "tunnel", "--no-autoupdate",
            "--url", "http://127.0.0.1:\(localPort)",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let pattern = try! NSRegularExpression(
            pattern: "https://[a-z0-9-]+\\.trycloudflare\\.com")

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = pattern.firstMatch(in: text, range: range),
                  let r = Range(match.range, in: text),
                  let url = URL(string: String(text[r])) else { return }

            guard let self else { return }
            self.lock.lock()
            let alreadyReported = self.reported
            self.reported = true
            self.lock.unlock()
            if !alreadyReported { onURL(url) }
        }

        process.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.lock.lock()
            let gotURL = self.reported
            self.lock.unlock()
            if !gotURL {
                onFailure("The Cloudflare tunnel exited (code \(proc.terminationStatus)).")
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            onFailure("Could not start cloudflared: \(error.localizedDescription)")
        }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }
}
