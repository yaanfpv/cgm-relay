import Testing
import CoreImage
import Compression
import Foundation
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

@Suite("FollowerQRPlanner")
struct FollowerQRPlannerTests {
    static let token = "tok_ABC-123_defGHI456jklMNO789pqrSTU0vwx-yz"
    static let address = "https://relay-mac.example-tailnet.ts.net"

    /// xdripDecode is xDrip+'s own decode path, ported: QRcodeUtils.decodeString
    /// (marker check, then JoH.uncompressString, a zlib Inflater over the
    /// base64 of the rest) into the string-to-string map that
    /// Preferences.installxDripPlusPreferencesFromQRCode writes into its
    /// preferences (NightscoutFoundation/xDrip 9898cb8). The zlib header and
    /// Adler-32 trailer are checked here directly, not through the encoder's helper.
    private func xdripDecode(_ scan: String) -> [String: String]? {
        guard scan.hasPrefix("xdpref:") else { return nil }
        var text = String(scan.dropFirst("xdpref:".count))
        while text.count % 4 != 0 { text += "=" }
        guard let stream = Data(base64Encoded: text), stream.count > 6 else { return nil }
        let bytes = [UInt8](stream)
        guard bytes[0] & 0x0F == 8, (Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0 else { return nil }
        let deflated = Array(bytes[2..<(bytes.count - 4)])
        var out = [UInt8](repeating: 0, count: 10_000)
        let n = compression_decode_buffer(&out, out.count, deflated, deflated.count, nil, COMPRESSION_ZLIB)
        guard n > 0 else { return nil }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in out[0..<n] { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let trailer = bytes.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard b << 16 | a == trailer else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(out[0..<n]))) as? [String: String]
    }

    @Test("xDrip+'s own decoder reads the QR back as exactly the Nightscout Follower source and the follow URL")
    func xDripPlusDecodes() throws {
        let rows = [
            (Self.address, "https://\(Self.token)@relay-mac.example-tailnet.ts.net"),
            ("https://192.168.1.42:1337", "https://\(Self.token)@192.168.1.42:1337"),
        ]
        for (address, followURL) in rows {
            let qr = try #require(FollowerQRPlanner.qr(for: .xDripPlus, address: address, token: Self.token, pairingCode: nil))
            let scanned = QRCodeGenerator.decode(try QRCodeGenerator.cgImage(for: qr.payload))
            #expect(scanned == qr.payload)
            let prefs = try #require(xdripDecode(qr.payload))
            #expect(prefs == ["dex_collection_method": "NSFollower", "nsfollow_url": followURL], "\(address)")
            #expect(qr.carriesToken)
        }
    }

    @Test("the xDrip+ code decodes a zlib stream made by another implementation, so the container is standard")
    func zlibInterop() throws {
        // zlib.compress of the same two-key object with a short follow URL, made by Python.
        let independent = "eJyrVkpJrYhPzs/JSU0uyczPi89NLcnIT1GyUvILdgOK5penFinpKOUVp4E58aVFOUC5jJKSgmIrff0KhwylWgBSuxhR"
        let decoded = try #require(ZlibStream.decompress(Data(base64Encoded: independent)!))
        let map = try #require(try JSONSerialization.jsonObject(with: decoded) as? [String: String])
        #expect(map["nsfollow_url"] == "https://x@h")
        let packed = try #require(ZlibStream.compress(Data("hello relay hello relay".utf8)))
        let round = try #require(ZlibStream.decompress(packed))
        #expect(String(data: round, encoding: .utf8) == "hello relay hello relay")
    }

    /// The pieces of LoopFollow's CombinedSettingsExport and
    /// NightscoutSettingsExport its import decodes (loopandlearn/LoopFollow
    /// 4a74b78, ExportableSettings.swift): same required keys, the rest optional.
    private struct LoopFollowNightscout: Decodable {
        let version: String
        let url: String
        let token: String
    }

    private struct LoopFollowCombined: Decodable {
        let version: String
        let appVersion: String
        let nightscout: LoopFollowNightscout?
        let exportType: String
        let timestamp: Date
    }

    @Test("LoopFollow's own decoder reads the QR back with the address as URL and the token as Token")
    func loopFollowDecodes() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for address in ["http://192.168.1.42:10000", "https://relay-mac.local:1337"] {
            let qr = try #require(FollowerQRPlanner.qr(for: .loopFollow, address: address, token: Self.token, pairingCode: nil, now: now))
            let scanned = QRCodeGenerator.decode(try QRCodeGenerator.cgImage(for: qr.payload, correctionLevel: "L"))
            #expect(scanned == qr.payload)
            let decoded = try JSONDecoder().decode(LoopFollowCombined.self, from: Data(qr.payload.utf8))
            #expect(decoded.nightscout?.url == address)
            #expect(decoded.nightscout?.token == Self.token)
            #expect(decoded.timestamp == now)
            #expect(!qr.payload.contains("/?token="))
            #expect(qr.carriesToken)
        }
    }

    @Test("xDrip4iOS and Nightguard get the pairing page address with a code and never the token")
    func pairingPageApps() throws {
        for app in [FollowerApp.xDrip4iOS, .nightguard] {
            #expect(FollowerQRPlanner.qr(for: app, address: Self.address, token: Self.token, pairingCode: nil) == nil)
            for address in [Self.address, "https://relay-mac.local:1337"] {
                let qr = try #require(FollowerQRPlanner.qr(for: app, address: address, token: Self.token, pairingCode: "CODE_abc-123"))
                #expect(qr.payload == "\(address)/connect/CODE_abc-123")
                #expect(!qr.payload.contains(Self.token))
                #expect(!qr.carriesToken)
                #expect(qr.caption == FollowerQRPlanner.caption(for: app))
            }
        }
        for app in [FollowerApp.xDripPlus, .loopFollow] {
            #expect(FollowerQRPlanner.qr(for: app, address: Self.address, token: "", pairingCode: "CODE") == nil)
            let qr = try #require(FollowerQRPlanner.qr(for: app, address: Self.address, token: Self.token, pairingCode: nil))
            #expect(qr.caption == FollowerQRPlanner.caption(for: app))
        }
    }

    /// darkBoxSide is the side of the bounding box of the image's dark pixels.
    private func darkBoxSide(_ image: CGImage) -> Int? {
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let data = context.data
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width where pixels[(y * image.width + x) * 4] < 128 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return max(maxX - minX, maxY - minY) + 1
    }

    @Test("every follower app's code fills the same tile at the same drawn size and decodes back to its exact payload")
    func everyAppsCodeFillsTheTileAndDecodes() throws {
        let addresses = [Self.address, "http://192.168.100.200:10000", "http://10.0.0.5:1337", "https://relay-mac.local:1337", "https://192.168.1.42:1337"]
        let sides = [QRCodeGenerator.standardTileSide, QRCodeGenerator.compactTileSide]
        for side in sides {
            let pixels = Int(side) * QRCodeGenerator.renderScale
            var boxes: [String: Int] = [:]
            for app in FollowerApp.allCases {
                for address in addresses {
                    let qr = try #require(FollowerQRPlanner.qr(for: app, address: address, token: Self.token, pairingCode: "CODE_abc-123"))
                    let image = try QRCodeGenerator.cgImage(for: qr.payload, sidePixels: pixels)
                    #expect(image.width == pixels && image.height == pixels, "\(app) at \(side) is not the tile's size")
                    #expect(QRCodeGenerator.decode(image) == qr.payload, "\(app) at \(side) did not decode back to its payload")
                    let box = try #require(darkBoxSide(image))
                    boxes["\(app) \(address)"] = box
                }
            }
            let largest = Double(boxes.values.max()!), smallest = Double(boxes.values.min()!)
            #expect(smallest / largest >= 0.98, "drawn code sides at \(side) differ by more than 2%: \(boxes)")
        }
    }
}
