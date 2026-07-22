import Foundation

/// Builds the mobile-facing HTML page a guest lands on after scanning the QR.
/// It plays the montage, shows the strip, and offers Download + native Share
/// (Web Share API) — the share sheet on the phone does the heavy lifting, so no
/// external service or account is involved.
enum SharePage {
    static func html(id: String, folder: URL) -> String {
        let exists: (String) -> Bool = {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        let hasVideo = exists("montage.mp4")
        // Prefer the compressed JPEG (~300 KB) over the lossless PNG (~3.6 MB) for
        // the phone; fall back to PNG for older sessions that predate the JPEG.
        let hasJPG = exists("strip.jpg")
        let hasPNG = exists("strip.png")
        let hasStrip = hasJPG || hasPNG
        let hasGif = exists("strip.gif")

        let base = "/s/\(id)"
        let videoURL = "\(base)/montage.mp4"
        let stripFile = hasJPG ? "strip.jpg" : "strip.png"
        let stripExt = hasJPG ? "jpg" : "png"
        let stripType = hasJPG ? "image/jpeg" : "image/png"
        let stripURL = "\(base)/\(stripFile)"
        let gifURL = "\(base)/strip.gif"

        // The animated video strip leads — it's the signature output.
        let gifBlock = hasGif ? """
            <img class="strip" src="\(gifURL)" alt="Your animated photo strip" />
        """ : ""

        let videoBlock = hasVideo ? """
            <video controls playsinline preload="metadata" poster="\(stripURL)">
              <source src="\(videoURL)" type="video/mp4" />
            </video>
        """ : ""

        // The share button collects both files and hands them to the OS share
        // sheet; if file-sharing isn't supported it shares the page link instead.
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
          <title>Your Photobooth</title>
          <style>
            :root { color-scheme: dark; }
            * { box-sizing: border-box; }
            body {
              margin: 0; font-family: -apple-system, system-ui, sans-serif;
              background: #0c0c0f; color: #fff;
              padding: 20px 16px calc(28px + env(safe-area-inset-bottom));
              text-align: center;
            }
            h1 { font-size: 1.5rem; margin: 8px 0 4px; }
            p.sub { color: #9a9aa2; margin: 0 0 20px; font-size: .95rem; }
            video, .strip {
              width: 100%; max-width: 480px; border-radius: 16px;
              background: #000; display: block; margin: 0 auto 18px;
            }
            .strip { box-shadow: 0 8px 30px rgba(0,0,0,.5); }
            .actions { display: flex; flex-direction: column; gap: 12px;
              max-width: 480px; margin: 8px auto 0; }
            a.btn, button.btn {
              -webkit-appearance: none; appearance: none; border: 0;
              font: inherit; font-weight: 600; font-size: 1.05rem;
              padding: 16px; border-radius: 14px; cursor: pointer;
              text-decoration: none; color: #fff; display: block;
            }
            .primary { background: #2f7bff; }
            .secondary { background: #1d1d22; color: #fff; }
            footer { margin-top: 26px; color: #6a6a72; font-size: .8rem; }
          </style>
        </head>
        <body>
          <h1>Your photos are ready 🎉</h1>
          <p class="sub">Watch, download, and share your photobooth strip.</p>
          \(gifBlock)
          \(videoBlock)
          <div class="actions">
            <button class="btn primary" id="share">Share</button>
            \(hasGif ? "<a class=\"btn secondary\" href=\"\(gifURL)\" download=\"photobooth-\(id).gif\">Download animated strip (GIF)</a>" : "")
            \(hasVideo ? "<a class=\"btn secondary\" href=\"\(videoURL)\" download=\"photobooth-\(id).mp4\">Download video</a>" : "")
            \(hasStrip ? "<a class=\"btn secondary\" href=\"\(stripURL)\" download=\"photobooth-\(id).\(stripExt)\">Download photo strip</a>" : "")
          </div>
          <footer>Made with 📸 Photobooth</footer>

          <script>
            const items = [
              \(hasGif ? "{ url: '\(gifURL)', name: 'photobooth-\(id).gif', type: 'image/gif' }," : "")
              \(hasVideo ? "{ url: '\(videoURL)', name: 'photobooth-\(id).mp4', type: 'video/mp4' }," : "")
              \(hasStrip ? "{ url: '\(stripURL)', name: 'photobooth-\(id).\(stripExt)', type: '\(stripType)' }," : "")
            ];
            const btn = document.getElementById('share');
            btn.addEventListener('click', async () => {
              btn.disabled = true;
              const original = btn.textContent;
              btn.textContent = 'Preparing…';
              try {
                const files = [];
                for (const it of items) {
                  const res = await fetch(it.url);
                  const blob = await res.blob();
                  files.push(new File([blob], it.name, { type: it.type }));
                }
                if (navigator.canShare && navigator.canShare({ files })) {
                  await navigator.share({ files, title: 'My Photobooth' });
                } else if (navigator.share) {
                  await navigator.share({ title: 'My Photobooth', url: location.href });
                } else {
                  alert('Sharing is not supported here — use the download buttons instead.');
                }
              } catch (err) {
                if (err && err.name !== 'AbortError') {
                  alert('Could not share — try the download buttons instead.');
                }
              } finally {
                btn.disabled = false;
                btn.textContent = original;
              }
            });
          </script>
        </body>
        </html>
        """
    }
}
