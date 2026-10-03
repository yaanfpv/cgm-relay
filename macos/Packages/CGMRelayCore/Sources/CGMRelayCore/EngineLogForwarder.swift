import Foundation
import os

/// EngineLogSink receives one engine log line at a time, without its newline.
public typealias EngineLogSink = @Sendable (String) -> Void

/// EngineLineSplitter turns the engine's stderr byte stream into whole
/// lines. A line longer than maxLineBytes keeps only its first maxLineBytes
/// bytes, so a runaway writer can never grow memory or flood the log.
struct EngineLineSplitter {
    static let maxLineBytes = 4096

    private var pending = Data()

    /// append returns every line the new bytes completed.
    mutating func append(_ chunk: Data) -> [String] {
        var lines: [String] = []
        for byte in chunk {
            if byte == UInt8(ascii: "\n") {
                if let line = takeLine() { lines.append(line) }
            } else if pending.count < Self.maxLineBytes {
                pending.append(byte)
            }
        }
        return lines
    }

    /// finish returns the unterminated final line, if the stream ended on one.
    mutating func finish() -> String? {
        takeLine()
    }

    private mutating func takeLine() -> String? {
        defer { pending.removeAll(keepingCapacity: true) }
        if pending.last == UInt8(ascii: "\r") { pending.removeLast() }
        guard !pending.isEmpty else { return nil }
        return String(decoding: pending, as: UTF8.self)
    }
}

public enum EngineLogForwarder {
    /// unifiedLog keeps each line in the system log under this app's
    /// subsystem, at a level the system persists. The engine's lines never
    /// carry a secret or a glucose value, so they are marked public;
    /// without that the system redacts them to "<private>".
    public static let unifiedLog: EngineLogSink = {
        let logger = Logger(subsystem: "com.yaanfpv.cgmrelay", category: "engine")
        return { line in logger.notice("\(line, privacy: .public)") }
    }()

    /// forward reads handle until its writer closes it or a read fails,
    /// handing every complete line to sink on a background queue as soon as
    /// its newline arrives. It always drains the pipe, so a slow sink can
    /// never leave the engine blocked on a full one.
    static func forward(from handle: FileHandle, to sink: @escaping EngineLogSink) {
        DispatchQueue.global(qos: .utility).async {
            var splitter = EngineLineSplitter()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                // read(2) returns whatever is available, where
                // FileHandle.read(upToCount:) waits for the full count or
                // EOF. A failed read ends the stream like EOF instead of
                // raising an exception the app cannot catch.
                let count = read(handle.fileDescriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                for line in splitter.append(Data(buffer[..<count])) { sink(line) }
            }
            if let line = splitter.finish() { sink(line) }
            try? handle.close()
        }
    }
}
