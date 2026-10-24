// [nova] Regression coverage for the RFC 1950 backport from 143d306/c906d84.
#if canImport(Compression)
import Compression
import Foundation
import Testing

@testable import SwiftTerm

struct KittyCompressionTests {
    private final class Delegate: TerminalDelegate {
        var responses: [[UInt8]] = []
        var bitmap: (bytes: [UInt8], width: Int, height: Int)?

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            responses.append(Array(data))
        }

        func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {
            bitmap = (bytes, width, height)
        }
    }

    private func makeTerminal(cacheLimit: Int = TerminalOptions.default.kittyImageCacheLimitBytes) -> (Terminal, Delegate) {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(
            cols: 80, rows: 24, kittyImageCacheLimitBytes: cacheLimit))
        return (terminal, delegate)
    }

    private func sequence(_ control: String, payload: Data = Data()) -> String {
        "\u{1b}_G\(control);\(payload.base64EncodedString())\u{1b}\\"
    }

    private func nodeFixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "kitty-node-rgba-384x384", withExtension: "zlib"))
        return try Data(contentsOf: url)
    }

    // Independent fixture: Node.js v22.14.0 deflateSync(rgba, { level: 1 }),
    // matching dsh-TUI's encoder. Pixels are [40, 80, 120, 255] repeated
    // 384 * 384 times. The zlib fixture is 2,889 bytes; decoded RGBA is 589,824.
    private var expectedNodePixels: [UInt8] {
        Array(repeating: [UInt8](arrayLiteral: 40, 80, 120, 255), count: 384 * 384).flatMap { $0 }
    }

    // Upstream's helper supplies additional sizes/formats without requiring
    // Node at test time. The independent fixture above guards interoperability.
    private func zlibStream(_ bytes: [UInt8]) throws -> Data {
        var deflated = [UInt8](repeating: 0, count: bytes.count + 1024)
        let produced = bytes.withUnsafeBufferPointer { source in
            deflated.withUnsafeMutableBufferPointer { destination in
                compression_encode_buffer(destination.baseAddress!, destination.count,
                                          source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        try #require(produced > 0)
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        let checksum = (b << 16) | a
        return Data([0x78, 0x01] + deflated[..<produced] + [
            UInt8((checksum >> 24) & 0xff), UInt8((checksum >> 16) & 0xff),
            UInt8((checksum >> 8) & 0xff), UInt8(checksum & 0xff)])
    }

    private func expectRgba(_ terminal: Terminal, id: UInt32, bytes: [UInt8], width: Int, height: Int) throws {
        let image = try #require(terminal.kittyGraphicsState.imagesById[id])
        guard case .rgba(let actual, let actualWidth, let actualHeight) = image.payload else {
            Issue.record("Expected decoded RGBA pixels")
            return
        }
        #expect(actual == bytes)
        #expect(actualWidth == width)
        #expect(actualHeight == height)
    }

    @Test func nodeCompressedImageReachesDisplayAndTerminalRemainsResponsive() throws {
        let (terminal, delegate) = makeTerminal()
        terminal.feed(text: sequence("a=t,t=d,f=32,s=384,v=384,i=42,o=z,q=2", payload: try nodeFixture()))
        try expectRgba(terminal, id: 42, bytes: expectedNodePixels, width: 384, height: 384)

        // dsh-TUI uploads first, then places the image separately.
        terminal.feed(text: sequence("a=p,i=42,p=1,c=24,r=12,C=1,q=1"))
        let bitmap = try #require(delegate.bitmap)
        #expect(bitmap.bytes == expectedNodePixels)
        #expect(bitmap.width == 384)
        #expect(bitmap.height == 384)
        terminal.feed(text: "ready\u{1b}[6n")
        #expect(String(decoding: delegate.responses.last ?? [], as: UTF8.self) == "\u{1b}[1;6R")
    }

    @Test func chunkedCompressedImageSurvivesTransportFragments() throws {
        let (terminal, delegate) = makeTerminal()
        let encoded = Array(try nodeFixture().base64EncodedString().utf8)
        for offset in stride(from: 0, to: encoded.count, by: 1024) {
            let end = min(offset + 1024, encoded.count)
            let more = end < encoded.count ? 1 : 0
            let control = offset == 0
                ? "a=t,t=d,f=32,s=384,v=384,i=42,o=z,q=2,m=\(more)"
                : "m=\(more),q=2"
            let payload = String(decoding: encoded[offset..<end], as: UTF8.self)
            let bytes = Array("\u{1b}_G\(control);\(payload)\u{1b}\\".utf8)
            for index in stride(from: 0, to: bytes.count, by: 37) {
                terminal.feed(byteArray: Array(bytes[index..<min(index + 37, bytes.count)]))
            }
            if more == 1 {
                #expect(terminal.kittyGraphicsState.imagesById[42] == nil)
            }
        }
        try expectRgba(terminal, id: 42, bytes: expectedNodePixels, width: 384, height: 384)
        #expect(terminal.kittyGraphicsState.pending == nil)
        #expect(delegate.responses.isEmpty)
    }

    @Test func compressedRgbAndExactCacheBoundaryDecode() throws {
        let (terminal, delegate) = makeTerminal(cacheLimit: 4)
        terminal.feed(text: sequence("a=t,f=24,s=1,v=1,i=1,o=z", payload: try zlibStream([1, 2, 3])))
        try expectRgba(terminal, id: 1, bytes: [1, 2, 3, 255], width: 1, height: 1)
        #expect(String(decoding: delegate.responses.last ?? [], as: UTF8.self) == "\u{1b}_Gi=1;OK\u{1b}\\")
    }

    @Test func compressedPngDecodes() throws {
        let (terminal, delegate) = makeTerminal()
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/xcAAwMCAO6V2yEAAAAASUVORK5CYII="))
        terminal.feed(text: sequence("a=t,f=100,i=1,o=z", payload: try zlibStream(Array(png))))
        let image = try #require(terminal.kittyGraphicsState.imagesById[1])
        guard case .png(let actual) = image.payload else {
            Issue.record("Expected PNG payload")
            return
        }
        #expect(actual == png)
        #expect(delegate.responses.count == 1)
    }

    @Test func malformedStreamsAreRejectedAndNextImageStillLoads() throws {
        let valid = try zlibStream([1, 2, 3, 255])
        var badChecksum = valid
        badChecksum[badChecksum.count - 1] ^= 1
        var badHeader = valid
        badHeader[1] ^= 1
        var dictionary = valid
        dictionary[1] = 0x20 // Valid FCHECK, unsupported preset dictionary.
        var invalidWindow = valid
        invalidWindow[0] = 0x88
        invalidWindow[1] = 0x1c // Valid FCHECK, window size exceeds RFC 1950.
        let malformed = [Data(), Data([0x78]), badHeader, dictionary, invalidWindow,
                         badChecksum, Data(valid.dropLast(5)), Data(valid.dropFirst(2).dropLast(4)),
                         Data([0x78, 0x01, 0x07, 0, 0, 0, 1])]
        for payload in malformed {
            let (terminal, delegate) = makeTerminal()
            terminal.feed(text: sequence("a=t,f=32,s=1,v=1,i=1,o=z", payload: payload))
            #expect(terminal.kittyGraphicsState.imagesById[1] == nil)
            #expect(String(decoding: delegate.responses.last ?? [], as: UTF8.self) == "\u{1b}_Gi=1;EINVAL: bad payload\u{1b}\\")
            terminal.feed(text: sequence("a=t,f=32,s=1,v=1,i=2,o=z", payload: valid))
            try expectRgba(terminal, id: 2, bytes: [1, 2, 3, 255], width: 1, height: 1)
        }
    }

    @Test func decompressionCannotExceedDeclaredPixelSize() throws {
        let (terminal, delegate) = makeTerminal()
        let compressed = try zlibStream([UInt8](repeating: 0, count: 2 * 1024 * 1024))
        terminal.feed(text: sequence("a=t,f=32,s=1,v=1,i=1,o=z", payload: compressed))
        #expect(terminal.kittyGraphicsState.imagesById[1] == nil)
        #expect(delegate.responses.count == 1)
    }

    @Test(arguments: [0, 1024])
    func decompressionRespectsCacheBudget(cacheLimit: Int) throws {
        let (terminal, delegate) = makeTerminal(cacheLimit: cacheLimit)
        terminal.feed(text: sequence("a=t,f=32,s=384,v=384,i=1,o=z", payload: try nodeFixture()))
        #expect(terminal.kittyGraphicsState.imagesById[1] == nil)
        #expect(terminal.kittyGraphicsState.totalImageBytes == 0)
        #expect(delegate.responses.count == 1)
    }

    @Test func compressedFileUsesTheSameDecoder() throws {
        let (terminal, delegate) = makeTerminal()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swiftterm-kitty-zlib-\(UUID().uuidString)")
        try nodeFixture().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        terminal.feed(text: sequence("a=t,t=f,f=32,s=384,v=384,i=1,o=z", payload: Data(url.path.utf8)))
        try expectRgba(terminal, id: 1, bytes: expectedNodePixels, width: 384, height: 384)
        #expect(delegate.responses.count == 1)
    }
}
#endif
