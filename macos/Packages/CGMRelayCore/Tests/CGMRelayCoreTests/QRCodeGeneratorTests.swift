import Testing
import CoreImage
@testable import CGMRelayCore

@Suite("QRCodeGenerator")
struct QRCodeGeneratorTests {
    @Test("decodes back to the exact string it was generated from")
    func roundTripsExactly() throws {
        let want = "http://192.168.1.42:1337/?token=abcDEF123-_xyz"
        let image = try QRCodeGenerator.cgImage(for: want)
        let got = QRCodeGenerator.decode(image)
        #expect(got == want)
    }

    @Test("round-trips a second, different string, proving the first case was not a fixed fixture")
    func roundTripsADifferentString() throws {
        let want = "http://100.101.102.5:5555/?token=zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
        let image = try QRCodeGenerator.cgImage(for: want)
        let got = QRCodeGenerator.decode(image)
        #expect(got == want)
    }

    @Test("decoding an image with no QR code returns nil rather than crashing")
    func decodingANonQRImageReturnsNil() throws {
        // A 1x1 QR code carries no message at all, but this proves decode
        // fails closed on genuinely unreadable input.
        let context = CIContext()
        let blank = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        guard let cgImage = context.createCGImage(blank, from: blank.extent) else {
            Issue.record("could not build the blank test image")
            return
        }
        #expect(QRCodeGenerator.decode(cgImage) == nil)
    }
}
