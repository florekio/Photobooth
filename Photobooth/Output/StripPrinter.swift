import AppKit
import CoreGraphics
import ImageIO

/// Prints the photo strip on 4×6" (10×15 cm) postcard paper as two identical
/// strips side by side — the classic photobooth layout, cut down the middle.
///
/// The strip design is a 2×6" (1:3) strip, so two of them tile exactly into a
/// 4×6" (2:3) sheet with no distortion. Each strip carries its own white margin,
/// which forms the centre cut gutter. Sized for the Canon SELPHY CP1500 postcard
/// paper (KP-108IN).
enum StripPrinter {
    enum PrintError: LocalizedError {
        case noStrip
        case sheetFailed
        case noPrinter
        var errorDescription: String? {
            switch self {
            case .noStrip: return "The photo strip isn't ready yet."
            case .sheetFailed: return "Could not build the print sheet."
            case .noPrinter: return "No printer found. Add the Canon SELPHY CP1500 in System Settings ▸ Printers."
            }
        }
    }

    /// Build the 4×6 sheet (two strips) from the already-rendered strip PNG and
    /// print it. When `showPanel` is false (kiosk lock) it prints straight to the
    /// SELPHY — or the default printer — with no on-screen UI, so guests just
    /// tap once and collect the print.
    @MainActor
    static func printDoubleStrip(stripPNG: URL, showPanel: Bool) throws {
        guard let src = CGImageSourceCreateWithURL(stripPNG as CFURL, nil),
              let strip = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw PrintError.noStrip
        }
        guard let sheet = doubleUp(strip) else { throw PrintError.sheetFailed }
        guard !NSPrinter.printerNames.isEmpty else { throw PrintError.noPrinter }

        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 288, height: 432)   // 4×6" postcard, portrait
        info.orientation = .portrait
        info.leftMargin = 0; info.rightMargin = 0
        info.topMargin = 0; info.bottomMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        if let selphy = selphyPrinter() { info.printer = selphy }

        let view = NSImageView(frame: NSRect(origin: .zero, size: info.paperSize))
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = NSImage(cgImage: sheet, size: info.paperSize)

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = showPanel
        op.showsProgressPanel = showPanel
        op.run()
    }

    /// Tile the strip twice, left and right, into one 4×6 sheet image.
    private static func doubleUp(_ strip: CGImage) -> CGImage? {
        let w = strip.width, h = strip.height
        guard let ctx = CGContext(
            data: nil, width: w * 2, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w * 2, height: h))
        ctx.draw(strip, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(strip, in: CGRect(x: w, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// The Canon SELPHY, matched by name, if it's installed.
    private static func selphyPrinter() -> NSPrinter? {
        NSPrinter.printerNames
            .first { $0.localizedCaseInsensitiveContains("selphy") || $0.localizedCaseInsensitiveContains("cp1500") }
            .flatMap(NSPrinter.init(name:))
    }
}
