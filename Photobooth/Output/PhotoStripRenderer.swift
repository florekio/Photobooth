import Foundation
import CoreGraphics
import ImageIO
import AppKit
import UniformTypeIdentifiers

/// Renders the 4 photos into a classic vertical photo-strip, as both a
/// print-ready PDF and a PNG. Pure Core Graphics — no external tools.
struct PhotoStripRenderer {
    var photoWidth: CGFloat = 620
    var margin: CGFloat = 28
    var gap: CGFloat = 18
    var footerHeight: CGFloat = 90
    var cornerRadius: CGFloat = 10

    struct Output { let pdf: URL; let png: URL }

    func render(_ result: SessionResult) throws -> Output {
        let images = result.photos.compactMap { loadCGImage($0) }
        guard !images.isEmpty else { throw CaptureError.writerFailed("no photos to render") }

        // Uniform cell height from the tallest aspect ratio, so the strip is tidy.
        let cellHeights: [CGFloat] = images.map { photoWidth * CGFloat($0.height) / CGFloat($0.width) }
        let cellHeight: CGFloat = cellHeights.max() ?? (photoWidth * 9.0 / 16.0)

        let count = CGFloat(images.count)
        let totalWidth: CGFloat = photoWidth + margin * 2
        let photosHeight: CGFloat = count * cellHeight
        let gapsHeight: CGFloat = (count - 1) * gap
        let totalHeight: CGFloat = margin + photosHeight + gapsHeight + footerHeight + margin
        let size = CGSize(width: totalWidth, height: totalHeight)

        let pdf = try renderPDF(images: images, size: size, cellHeight: cellHeight, to: result.store.stripPDFURL)
        let png = try renderPNG(images: images, size: size, cellHeight: cellHeight, to: result.store.stripPNGURL)
        return Output(pdf: pdf, png: png)
    }

    // MARK: - Drawing (CG origin is bottom-left)

    private func draw(in ctx: CGContext, images: [CGImage], size: CGSize, cellHeight: CGFloat) {
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        var y = size.height - margin - cellHeight
        for image in images {
            let rect = CGRect(x: margin, y: y, width: photoWidth, height: cellHeight)
            ctx.saveGState()
            let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            ctx.addPath(path)
            ctx.clip()
            // Aspect-fill the cell.
            let aspect = CGFloat(image.width) / CGFloat(image.height)
            var drawRect = rect
            if aspect > rect.width / rect.height {
                let w = rect.height * aspect
                drawRect = CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: rect.height)
            } else {
                let h = rect.width / aspect
                drawRect = CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)
            }
            ctx.draw(image, in: drawRect)
            ctx.restoreGState()
            y -= (cellHeight + gap)
        }

        drawFooter(in: ctx, size: size)
    }

    private func drawFooter(in ctx: CGContext, size: CGSize) {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let text = "Photobooth · \(df.string(from: Date()))"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetImageBounds(line, ctx)
        ctx.textPosition = CGPoint(x: (size.width - bounds.width) / 2, y: margin + footerHeight / 2 - bounds.height / 2)
        CTLineDraw(line, ctx)
    }

    private func renderPDF(images: [CGImage], size: CGSize, cellHeight: CGFloat, to url: URL) throws -> URL {
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CaptureError.writerFailed("could not create PDF context")
        }
        ctx.beginPDFPage(nil)
        draw(in: ctx, images: images, size: size, cellHeight: cellHeight)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private func renderPNG(images: [CGImage], size: CGSize, cellHeight: CGFloat, to url: URL) throws -> URL {
        let scale: CGFloat = 2 // crisp for printing
        let pxW = Int(size.width * scale), pxH = Int(size.height * scale)
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.writerFailed("could not create bitmap context")
        }
        ctx.scaleBy(x: scale, y: scale)
        draw(in: ctx, images: images, size: size, cellHeight: cellHeight)
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.writerFailed("could not finalize PNG")
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return url
    }

    private func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
