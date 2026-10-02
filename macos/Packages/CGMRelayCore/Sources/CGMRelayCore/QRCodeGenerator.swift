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

        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            throw QRCodeError.renderingFailed
        }
        return cgImage
    }

    #if canImport(AppKit)
    /// nsImage is the Connect pane's own display convenience: the same
    /// image as cgImage(for:), wrapped for SwiftUI's Image(nsImage:).
    public static func nsImage(for string: String, scale: CGFloat = 10, correctionLevel: String = "M") throws -> NSImage {
        let cgImage = try cgImage(for: string, scale: scale, correctionLevel: correctionLevel)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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
