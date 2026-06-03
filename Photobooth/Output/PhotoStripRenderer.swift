import Foundation
import CoreGraphics
import ImageIO
import AppKit
import UniformTypeIdentifiers

/// Renders the photos into the classic vertical strip (see `StripLayout`), as a
/// print-ready PDF and a PNG. An optional `frame` PNG is composited on top — its
/// transparent windows reveal the photos, its opaque areas decorate the strip.
///
/// Drawing happens in `StripLayout` design coordinates in Core Graphics' native
/// bottom-left space; each output just applies a uniform scale.
struct PhotoStripRenderer {
    /// PNG super-sampling factor over the 600×1800 design (→ 1200×3600).
    var pngScale: CGFloat = 2
    /// Print size for the PDF, in points (2×6" at 72pt/in).
    var pdfSize = CGSize(width: 144, height: 432)

    struct Output { let pdf: URL; let png: URL }

    func render(_ result: SessionResult, frame: URL? = nil) throws -> Output {
        let images = result.photos.compactMap { loadCGImage($0) }
        guard !images.isEmpty else { throw CaptureError.writerFailed("no photos to render") }
        let frameImage = frame.flatMap { loadCGImage($0) }

        let pdf = try renderPDF(images: images, frame: frameImage, footer: footerText(result), to: result.store.stripPDFURL)
        let png = try renderPNG(images: images, frame: frameImage, footer: footerText(result), to: result.store.stripPNGURL)
        return Output(pdf: pdf, png: png)
    }

    // MARK: - Drawing (design coordinates, bottom-left origin)

    /// Convert a top-left `StripLayout` rect into bottom-left design space.
    private func bl(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: StripLayout.designSize.height - r.maxY, width: r.width, height: r.height)
    }

    private func draw(in ctx: CGContext, images: [CGImage], frame: CGImage?, footer: String) {
        let canvas = CGRect(origin: .zero, size: StripLayout.designSize)

        // White base (shows through any non-photo transparent areas of a frame).
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(canvas)

        for (i, image) in images.prefix(StripLayout.count).enumerated() {
            let rect = bl(StripLayout.cellRect(i))
            ctx.saveGState()
            let path = CGPath(roundedRect: rect, cornerWidth: StripLayout.cornerRadius,
                              cornerHeight: StripLayout.cornerRadius, transform: nil)
            ctx.addPath(path)
            ctx.clip()
            ctx.draw(image, in: aspectFill(image: image, into: rect))
            ctx.restoreGState()
        }

        if let frame {
            // Scales to fill the strip; 1:3 frames map 1:1.
            ctx.draw(frame, in: canvas)
        } else {
            drawFooter(in: ctx, text: footer)
        }
    }

    /// Aspect-fill `image` into `rect` (centered, cropped).
    private func aspectFill(image: CGImage, into rect: CGRect) -> CGRect {
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        if aspect > rect.width / rect.height {
            let w = rect.height * aspect
            return CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: rect.height)
        } else {
            let h = rect.width / aspect
            return CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)
        }
    }

    private func drawFooter(in ctx: CGContext, text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 30, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let bounds = CTLineGetImageBounds(line, ctx)
        let footer = bl(StripLayout.footerRect)
        ctx.textPosition = CGPoint(x: (StripLayout.designSize.width - bounds.width) / 2,
                                   y: footer.midY - bounds.height / 2)
        CTLineDraw(line, ctx)
    }

    // MARK: - Outputs

    private func renderPDF(images: [CGImage], frame: CGImage?, footer: String, to url: URL) throws -> URL {
        var mediaBox = CGRect(origin: .zero, size: pdfSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CaptureError.writerFailed("could not create PDF context")
        }
        ctx.beginPDFPage(nil)
        ctx.scaleBy(x: pdfSize.width / StripLayout.designSize.width,
                    y: pdfSize.height / StripLayout.designSize.height)
        draw(in: ctx, images: images, frame: frame, footer: footer)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private func renderPNG(images: [CGImage], frame: CGImage?, footer: String, to url: URL) throws -> URL {
        let pxW = Int(StripLayout.designSize.width * pngScale)
        let pxH = Int(StripLayout.designSize.height * pngScale)
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.writerFailed("could not create bitmap context")
        }
        ctx.scaleBy(x: pngScale, y: pngScale)
        draw(in: ctx, images: images, frame: frame, footer: footer)
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.writerFailed("could not finalize PNG")
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return url
    }

    private func footerText(_ result: SessionResult) -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        return "Photobooth · \(df.string(from: result.store.startedAt))"
    }

    private func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
