# Photobooth

A macOS photobooth app built with SwiftUI. It shows a live camera feed full-screen,
and on a single hotkey press runs an automatic **4-shot** sequence — each shot pairs
a photo with a video recorded immediately before and after it. At the end you get a
stitched **MP4 montage** (the "digital strip with videos"), a print-ready
**PDF/PNG photo strip**, a QR code to share to a phone, and a one-tap **print** of
two strips on a 4×6" sheet. Runs from a USB webcam or a tethered **Nikon DSLR**, and
has a **kiosk lock** for unattended events.

## What it does

Press **Space** and the booth runs four shots back-to-back, hands-free:

```
per shot ×4:
  3s countdown on screen  ── while recording the "before" clip
  ↓
  📸 photo + screen flash
  ↓
  3s "after" clip recording
  ↓
  "Get ready!"  ── brief pause, then the next shot
```

After the fourth shot it builds the outputs and shows a results screen with the
montage playing and the printable strip previewed.

**Result of one session:** 4 photos, each with a before and after video clip, plus
a montage video and a photo strip.

## Requirements

- macOS 14 or later
- Xcode 16+ (developed against Xcode 26.5 / Swift 6.3)
- [XcodeGen](https://github.com/yonyz/XcodeGen) — `brew install xcodegen` (the
  `.xcodeproj` is generated from `project.yml`, not checked in)
- [ffmpeg](https://ffmpeg.org/) — `brew install ffmpeg` (used to stitch the montage;
  `ffprobe` ships with it)
- [cloudflared](https://github.com/cloudflare/cloudflared) — `brew install cloudflared`
  (used for the QR-code sharing tunnel; see [Sharing](#sharing))
- [libgphoto2](http://www.gphoto.org/) — `brew install libgphoto2` (only for the
  Nikon DSLR path; the webcam path doesn't need it). The app links it at the
  Homebrew prefix, so it must be installed to build and to run the Nikon capture.

## Hardware

### USB webcam (works now)

Any UVC-class USB webcam works **with no drivers** — macOS exposes it to AVFoundation
directly. Developed and tested with a **Logitech Brio 100**. The built-in FaceTime
camera and Continuity Camera (iPhone) also show up in the picker.

### Nikon DSLR — tethered over USB (works now)

`NikonSource` drives a Nikon body over USB/PTP with
[`libgphoto2`](http://www.gphoto.org/) (`brew install libgphoto2`), behind the same
`CaptureSource` protocol as the webcam. Developed and tested with a **Nikon D5500**.
It shows a liveview preview, records the before/after clips from that liveview
stream, and captures full-resolution stills (downscaled to 2400 px long-edge before
they hit the strip). It appears in the camera picker automatically when connected.

> **Known constraint:** Nikon bodies do not allow starting/stopping the camera's
> *internal* video recording over USB, so the "before/after videos" are a recording
> of the **liveview stream** (~640×424 JPEG). Stills are captured at full 24 MP. The
> webcam path is unaffected.

**Camera setup for the booth:**

- Set the **lens to manual focus (MF)** — in AF mode the shutter refuses to fire
  ("Out of Focus") over USB. `NikonSource` also sets `autofocus=Off`.
- Set the **mode dial to `P` or `A`** (not `M`) so the camera auto-exposes; exposure
  mode is read-only over USB, so a dark `M` setting can't be fixed from the app.
- On macOS the system `ptpcamerad` daemon grabs the camera on plug-in; the app kills
  it before claiming the device, so no manual step is needed.

## Build & run

```sh
# 1. Generate the Xcode project from project.yml
xcodegen generate

# 2a. Build & run from the command line
xcodebuild -project Photobooth.xcodeproj -scheme Photobooth \
  -configuration Debug -derivedDataPath build build CODE_SIGNING_ALLOWED=NO
open build/Build/Products/Debug/Photobooth.app

# 2b. ...or just open it in Xcode and hit Run
open Photobooth.xcodeproj
```

On first launch macOS prompts for **camera** (and **microphone**, for clip audio)
access — grant both. If you miss the prompt, enable them under
**System Settings ▸ Privacy & Security ▸ Camera / Microphone**.

## Controls

| Key             | Action                                              |
| --------------- | --------------------------------------------------- |
| **Space** / ⏎   | Start the 4-shot sequence                           |
| **Esc**         | Cancel the current sequence                         |
| **↑ / ↓**       | Previous / next strip frame (works while locked)    |
| **⌘L**          | Toggle kiosk lock (PIN to unlock — see below)       |

The camera picker and frame picker (bottom of the idle screen) switch inputs and
frames live; both are hidden while kiosk-locked.

### Kiosk mode

**⌘L** locks the booth for unattended use: it goes fullscreen and hides all operator
controls (camera picker, frame picker, gallery) so guests can only start a session,
change the frame with **↑/↓**, and print. Pressing **⌘L** again prompts for a **PIN**
to unlock (default **`1337`**, override with `defaults write com.mapular.photobooth
kioskPIN <pin>`). The lock state persists across relaunches. While locked, the idle
screen shows the available frames with a "Use ↑ / ↓ to change frame" hint.

### Printing

The results screen has a **Print strip** button. It lays out **two identical strips
side by side on one 4×6" (10×15 cm) sheet** — the classic photobooth layout, cut down
the middle — sized for the **Canon SELPHY CP1500** postcard paper (KP-108IN). It
auto-selects a printer whose name contains "SELPHY"/"CP1500", else the default
printer. Unlocked it shows the print dialog (pick paper/borderless the first time);
kiosk-locked it prints silently so guests just tap once.

## Output

Each session writes to a timestamped folder:

```
~/Pictures/Photobooth/<yyyy-MM-dd_HH-mm-ss>/
  photo_1.jpg … photo_4.jpg     # the four stills
  before_1.mov … before_4.mov   # 3s clip recorded during each countdown
  after_1.mov  … after_4.mov    # 3s clip recorded after each photo
  montage.mp4                   # stitched: before → photo freeze → after, ×4
  strip.pdf                     # print-ready vertical photo strip
  strip.png                     # same strip as an image
  strip.gif                     # animated "video strip" (4 looping cells) for the share page
```

## Sharing

When a session finishes, the results screen shows a **QR code**. A guest scans it
with their phone and lands on a mobile page that shows the **animated video
strip** (a looping GIF of the 4-cell strip), plays the full montage, and offers
**Download** and a native **Share** button (the phone's own share sheet via the
Web Share API). No accounts, no cloud storage, no cost.

How it works (all free):

```
phone ── scans QR ──▶ https://<random>.trycloudflare.com/s/<session>
                                   │  (Cloudflare Quick Tunnel — no account)
                                   ▼
                      cloudflared ──▶ 127.0.0.1:8088   (embedded HTTP server)
                                   ▼
                      ~/Pictures/Photobooth/<session>/  (strip.png + montage.mp4)
```

- **`ShareServer`** (`Sharing/ShareServer.swift`) is a tiny dependency-free
  HTTP/1.1 server bound to **loopback only** (`127.0.0.1`). It serves the mobile
  page plus `strip.png` and `montage.mp4`, with HTTP **range/byte-serving** so
  iOS Safari can stream and seek the video. Loopback-only binding means no macOS
  firewall or local-network permission prompts.
- **`TunnelController`** (`Sharing/TunnelController.swift`) runs
  `cloudflared tunnel --url http://127.0.0.1:8088` and scrapes the public
  `https://*.trycloudflare.com` URL from its output — a Cloudflare **Quick
  Tunnel** needs no Cloudflare account or login.
- **`ShareService`** (`Sharing/ShareService.swift`) starts both at app launch and
  builds each session's public URL; **`QRCode`** renders it locally via CoreImage.

The tunnel and its URL are spun up once per app launch (the public hostname
changes each launch). If `cloudflared` isn't installed, the results screen says
so and the photos remain saved locally — capture is never affected.

> **Same Mac, anywhere phone.** Because delivery goes through Cloudflare's tunnel,
> guests can scan and download over cellular — they don't need to be on the
> booth's WiFi. The Mac just needs an internet connection.

## Architecture

One continuous AVFoundation pipeline drives everything for the webcam, so the photo
and the before/after clips come from the same stream and stay perfectly in sync.

```
Photobooth/
  App/PhotoboothApp.swift            App entry point (SwiftUI WindowGroup)

  Capture/
    CaptureSource.swift              Protocol: any camera input the booth can drive
    WebcamSource.swift               AVFoundation: preview layer + AVAssetWriter
                                     recording + frame-grab still, one session
    NikonSource.swift                Nikon over libgphoto2/PTP: liveview preview +
                                     clips + full-res stills, one camera handle
    DeviceDiscovery.swift            Enumerates webcams + Nikon (gp_camera_autodetect)

  Sequence/
    CaptureCoordinator.swift         @Observable state machine: countdown →
                                     photo+flash → after-clip, ×4, with cancel

  Output/
    SessionStore.swift               Per-session folder + file naming, JPEG writer
    MontageBuilder.swift             Shells out to ffmpeg: normalizes each segment
                                     to identical params, then concat-copies them
    PhotoStripRenderer.swift         Core Graphics → PDF + PNG vertical strip
    StripGifBuilder.swift            ffmpeg → animated GIF of the 4-cell video strip
    StripPrinter.swift               Tiles two strips onto a 4×6" sheet, prints it

  Sharing/
    ShareServer.swift                Loopback HTTP server: mobile page + strip/
                                     montage with HTTP range support
    SharePage.swift                  The mobile share page (HTML + Web Share API)
    TunnelController.swift           Runs cloudflared Quick Tunnel, scrapes URL
    ShareService.swift               @Observable: starts server+tunnel, per-
                                     session public URL
    QRCode.swift                     CoreImage QR generation (local, offline)

  UI/
    CameraController.swift           @Observable owner of the active source, device
                                     + frame selection, kiosk lock, coordinator
    BoothView.swift                  Full-bleed preview + countdown/flash/REC
                                     overlays + Space/Esc/↑↓/⌘L hotkeys + PIN unlock
    CameraPreviewView.swift          NSViewRepresentable hosting the preview layer
    SourcePickerView.swift           Camera picker
    FramePickerView.swift            Frame chooser (full operator + kiosk variants)
    ResultsView.swift                QR-first share screen + Print/Done actions

  Photobooth-Bridging-Header.h       Exposes libgphoto2's C API to Swift

  Resources/
    Info.plist                       Camera/microphone usage descriptions
    Photobooth.entitlements          App Sandbox disabled (see below)
    Frames/                          frame-*.png + Frame_*.png strip overlays
```

### Key design notes

- **Single stream for webcam.** `WebcamSource` runs one `AVCaptureSession`. An
  `AVCaptureVideoPreviewLayer` renders the always-on live feed; an
  `AVCaptureVideoDataOutput` simultaneously keeps the latest frame (for the still)
  and feeds an `AVAssetWriter` while recording. Audio comes from an
  `AVCaptureAudioDataOutput`.
- **Montage in two steps for reliability.** Each clip/photo is first re-encoded to
  identical parameters (1280×720, 30 fps, H.264 + AAC; photos held ~1.5s with silent
  audio), then joined with ffmpeg's concat demuxer using stream copy. Clips missing
  an audio track get a synthesized silent track so concatenation always succeeds.
- **Nikon uses one serialized handle.** libgphoto2 isn't thread-safe, so
  `NikonSource` keeps a single `Camera*` on a private serial queue; the liveview poll
  loop yields between frames so a still capture can interleave. The full-res shutter
  briefly interrupts liveview, which reads as a natural freeze at the flash moment.
- **App Sandbox is off** (`Photobooth.entitlements`). This is a local kiosk app, not
  an App Store build; it launches the external `ffmpeg`/`cloudflared` binaries via
  `Process`, links `libgphoto2`, and writes session files freely.
- **Hotkey is a local key monitor.** The app runs focused/full-screen, so
  `NSEvent.addLocalMonitorForEvents` is enough — no Accessibility permission needed.
  A physical button or foot pedal that maps to Space/Return works as-is.

## Configuration

Capture timing lives in `CaptureCoordinator.Config` (`Sequence/CaptureCoordinator.swift`):

```swift
var shots = 4              // number of photos in a strip
var countdownSeconds = 3   // "before" clip length + countdown
var afterSeconds = 3       // "after" clip length
var getReadySeconds = 2    // pause between shots
```

Montage resolution/fps and the photo-freeze duration are in `MontageBuilder`; strip
layout (photo width, margins, footer) is in `PhotoStripRenderer`; the Nikon still
downscale (`stillMaxLongEdge`) is in `NikonSource`. The kiosk PIN defaults to `1337`
(`kioskPIN` user default). Frames are any `Resources/Frames/frame…png` (2×6", 1:3,
transparent windows — ideal 1200×3600); drop in your own and they appear in the picker.

## Releases (CI/CD)

GitHub Actions builds and publishes releases (`.github/workflows/`):

- **`ci.yml`** — builds the app on every push to `main` and on PRs, as a compile check.
- **`release.yml`** — on a `v*` tag (or a manual *Run workflow*), builds Release,
  packages a `.zip` and a `.dmg`, and publishes a GitHub Release with auto-generated notes.

Cut a release by tagging:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The app version (`CFBundleShortVersionString`) is taken from the tag, and the build
number from the CI run number.

> **Signing:** builds are **unsigned / not notarized** (no Apple Developer account is
> wired in). Recipients right-click ▸ **Open** on first launch, or run
> `xattr -dr com.apple.quarantine /Applications/Photobooth.app`. To ship signed,
> notarized builds later, add Developer ID signing + `xcrun notarytool` steps and set
> `DEVELOPMENT_TEAM` in `project.yml`.

## Roadmap

- [x] Live webcam preview + device picker
- [x] Automatic 4-shot capture sequence with countdown, before/after clips
- [x] Montage MP4 (ffmpeg) + print-ready PDF/PNG photo strip
- [x] QR-code sharing (loopback server + free Cloudflare Quick Tunnel)
- [x] Nikon D5500 via libgphoto2 (full-res stills + liveview-based clips)
- [x] Direct-to-printer output (Canon SELPHY CP1500, two strips on 4×6")
- [x] Kiosk lock with PIN + on-screen frame switching
