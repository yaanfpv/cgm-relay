import CoreImage
#if canImport(AppKit)
import AppKit
#endif

/// QRCodeError names why QRCodeGenerator.cgImage could not produce an
/// image.
public enum QRCodeError: Error, Sendable, Equatable {
    case encodingFailed
    case renderingFailed
}

/// QRCodeGenerator renders a plain string as a QR code, using only
/// CoreImage's own built-in filter and detector -- no third-party
/// dependency for something the platform already does.
public enum QRCodeGenerator {
    /// cgImage renders string as a QR code, scaled up by scale
    /// (nearest-neighbor, so the result stays crisp rather than blurred):
    /// CIQRCodeGenerator's own raw output is only a handful of pixels per
    /// module, far too small to display or scan directly. A fresh
    /// CIContext is built on every call rather than shared from a static,
    /// since CIContext is not Sendable and a QR code is rendered rarely
    /// enough that the cost of building one is never worth the
    /// concurrency risk of sharing it.
    ///
    /// correctionLevel is CIQRCodeGenerator's own L, M, Q or H: a code shown
    /// on a screen and scanned close up needs little error correction, and
    /// each level down leaves the modules larger for the same payload.
    public static func cgImage(for string: String, scale: CGFloat = 10, correctionLevel: String = "M") throws -> CGImage {
        let raw = try rawImage(for: string, correctionLevel: correctionLevel)
        return try render(raw, scale: scale)
    }

    /// standardTileSide and compactTileSide are the sides, in points, of the
    /// square the Connect pane draws every follower app's code into.
    public static let standardTileSide: CGFloat = 208
    public static let compactTileSide: CGFloat = 160

    /// codeFraction is how much of the tile's side the code itself fills; the
    /// rest is the white margin a scanner needs.
    public static let codeFraction = 0.9

    /// cgImage(for:sidePixels:) renders string into a square exactly
    /// sidePixels wide with the code centred on white at one fixed size for
    /// every payload. Modules are drawn as whole pixels, nearest-neighbor, at
    /// the smallest scale that makes the code at least as large as its fixed
    /// size, then scaled down smoothly to exactly that size, so a sparse
    /// payload and a dense one fill the same square.
    public static func cgImage(for string: String, sidePixels: Int, correctionLevel: String = "L") throws -> CGImage {
        let raw = try darkModulesOnly(try rawImage(for: string, correctionLevel: correctionLevel))
        let modules = Int(raw.extent.width)
        let target = Int((Double(sidePixels) * codeFraction).rounded())
        guard modules > 0, target >= modules else { throw QRCodeError.renderingFailed }
        let pixelsPerModule = (target + modules - 1) / modules
        let code = try render(raw, scale: CGFloat(pixelsPerModule))
        guard
            let context = CGContext(
                data: nil, width: sidePixels, height: sidePixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw QRCodeError.renderingFailed }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: sidePixels, height: sidePixels))
        context.interpolationQuality = .high
        let offset = (sidePixels - target) / 2
        context.draw(code, in: CGRect(x: offset, y: offset, width: target, height: target))
        guard let image = context.makeImage() else { throw QRCodeError.renderingFailed }
        return image
    }

    /// darkModulesOnly crops the filter's output to the bounding box of its
    /// dark modules, since the filter adds a margin whose width in modules is
    /// the same for every payload and so would make a denser code's drawn
    /// size differ from a sparser one's.
    private static func darkModulesOnly(_ raw: CIImage) throws -> CIImage {
        let side = Int(raw.extent.width)
        let bitmap = try render(raw, scale: 1)
        guard
            side > 0, bitmap.width == side, bitmap.height == side,
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let data = context.data
        else { throw QRCodeError.renderingFailed }
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<side {
            for x in 0..<side where pixels[(y * side + x) * 4] < 128 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0, maxX - minX == maxY - minY else { throw QRCodeError.renderingFailed }
        // The bitmap is top-down and CIImage is bottom-up; the box is square
        // and the code symmetric in extent, so flip the origin for the crop.
        let rect = CGRect(x: minX, y: side - 1 - maxY, width: maxX - minX + 1, height: maxX - minX + 1)
        return raw.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    private static func rawImage(for string: String, correctionLevel: String) throws -> CIImage {
        guard let data = string.data(using: .utf8) else {
            throw QRCodeError.encodingFailed
        }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw QRCodeError.encodingFailed
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue(correctionLevel, forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else {
            throw QRCodeError.encodingFailed
        }
        return outputImage
    }

    private static func render(_ raw: CIImage, scale: CGFloat) throws -> CGImage {
        let scaled = raw.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            throw QRCodeError.renderingFailed
        }
        return cgImage
    }

    #if canImport(AppKit)
    /// renderScale is how many pixels per point a tile's code is rendered at,
    /// enough that the smooth scale-down to the code's fixed size stays sharp.
    public static let renderScale = 4

    /// nsImage is the Connect pane's own display convenience: the code
    /// rendered for a tile of side points at renderScale, wrapped for
    /// SwiftUI's Image(nsImage:).
    public static func nsImage(for string: String, tileSide: CGFloat, correctionLevel: String = "L") throws -> NSImage {
        let cgImage = try cgImage(for: string, sidePixels: Int(tileSide) * renderScale, correctionLevel: correctionLevel)
        return NSImage(cgImage: cgImage, size: NSSize(width: tileSide, height: tileSide))
    }
    #endif

    /// decode reads back the string cgImage encodes, or nil if the image
    /// carries no QR code CIDetector can find. Used only by a test, to
    /// prove cgImage(for:) round-trips exactly back to its input, never
    /// by production code, which only ever renders a code it just built
    /// from a known string.
    public static func decode(_ cgImage: CGImage) -> String? {
        guard let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ) else {
            return nil
        }
        let ciImage = CIImage(cgImage: cgImage)
        for feature in detector.features(in: ciImage) {
            if let qrFeature = feature as? CIQRCodeFeature, let message = qrFeature.messageString {
                return message
            }
        }
        return nil
    }
}
