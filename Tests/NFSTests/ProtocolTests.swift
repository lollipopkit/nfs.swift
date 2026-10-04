import Foundation
import NIOCore
import NIOEmbedded
import Testing

@testable import NFS

@Test func xdrRoundTripsWithPadding() throws {
    var encoder = XDREncoder()
    encoder.encode(UInt32(7))
    encoder.encode(UInt64(0x0102_0304_0506_0708))
    encoder.encode(true)
    encoder.encode("abcde")
    encoder.encodeFixedOpaque([1, 2, 3])
    // 4 + 8 + 4 + (4 + 5 + 3 padding) + (3 + 1 padding)
    #expect(encoder.bytes.count == 32)

    var decoder = XDRDecoder(encoder.bytes)
    #expect(try decoder.decodeUInt32() == 7)
    #expect(try decoder.decodeUInt64() == 0x0102_0304_0506_0708)
    #expect(try decoder.decodeBool())
    #expect(try decoder.decodeOpaque() == Array("abcde".utf8))
    #expect(try decoder.decodeFixedOpaque(length: 3) == [1, 2, 3])
    #expect(decoder.isAtEnd)
}

@Test func xdrRefusesToReadPastTheEnd() {
    var truncated = XDRDecoder([0, 0, 0, 9, 1, 2])
    #expect(throws: XDRError.truncated) { try truncated.decodeOpaque() }

    var oversized = XDRDecoder([0, 0, 1, 0])
    #expect(throws: XDRError.tooLong(256)) { try oversized.decodeOpaque(maxLength: 64) }
}

@Test func recordDecoderJoinsFragments() throws {
    let channel = EmbeddedChannel(handler: ByteToMessageHandler(RPCRecordDecoder()))
    var buffer = channel.allocator.buffer(capacity: 16)
    buffer.writeInteger(UInt32(2))                     // not last
    buffer.writeBytes([1, 2])
    buffer.writeInteger(UInt32(0x8000_0003))           // last
    buffer.writeBytes([3, 4])
    try channel.writeInbound(buffer)
    #expect(try channel.readInbound(as: [UInt8].self) == nil)

    var rest = channel.allocator.buffer(capacity: 1)
    rest.writeBytes([5])
    try channel.writeInbound(rest)
    #expect(try channel.readInbound(as: [UInt8].self) == [1, 2, 3, 4, 5])
    _ = try channel.finish()
}

@Test func recordDecoderRefusesOversizedRecords() throws {
    let channel = EmbeddedChannel(handler: ByteToMessageHandler(RPCRecordDecoder()))
    var buffer = channel.allocator.buffer(capacity: 4)
    buffer.writeInteger(UInt32(0x8000_0000) | UInt32(RPCRecordDecoder.maxRecordSize + 1))
    #expect(throws: RPCError.self) { try channel.writeInbound(buffer) }
}

private func reply(_ words: [UInt32]) -> [UInt8] {
    var encoder = XDREncoder()
    encoder.encode(UInt32(42))                          // xid
    encoder.encode(UInt32(1))                           // REPLY
    words.forEach { encoder.encode($0) }
    return encoder.bytes
}

@Test func acceptedReplyYieldsTheResults() throws {
    var results = try RPCClient.acceptedResults(of: reply([0, 0, 0, 0, 99]))
    #expect(try results.decodeUInt32() == 99)
}

@Test func rejectedRepliesAreReported() {
    #expect(throws: RPCError.programMismatch(low: 2, high: 4)) {
        try RPCClient.acceptedResults(of: reply([0, 0, 0, 2, 2, 4]))
    }
    #expect(throws: RPCError.authenticationRejected(authStat: 5)) {
        try RPCClient.acceptedResults(of: reply([1, 1, 5]))
    }
}

@Test func statusesBecomeClientErrors() {
    #expect(NFSClientError(status: NFSStatusError(status: NFSStatusError.noEntry), path: "/a") == .notFound(path: "/a"))
    #expect(NFSClientError(status: NFSStatusError(status: NFSStatusError.exists), path: "/a") == .alreadyExists(path: "/a"))
    #expect(NFSClientError(status: NFSStatusError(status: NFSStatusError.access), path: "/a") == .permissionDenied(path: "/a"))
    #expect(NFSClientError(status: NFSStatusError(status: 5), path: "/a") == .server(NFSStatusError(status: 5), path: "/a"))
}

@Test func refusedMountMentionsTheInsecureOption() {
    let error = NFSClientError.mountRefused(MountStatusError(status: 13))
    #expect(error.mayNeedInsecureExport)
    #expect(error.localizedDescription.contains("insecure"))
}

@Test func pathsSplitIntoParentAndName() throws {
    #expect(try NFSClient.split("/a/b/c").parent == "a/b")
    #expect(try NFSClient.split("a").name == "a")
    #expect(throws: NFSClientError.self) { try NFSClient.split("/") }
    #expect(throws: NFSClientError.self) { try NFSClient.split("/a/..") }
}

@Test func namesRoundTripLosslessly() {
    let samples: [[UInt8]] = [
        Array("plain.txt".utf8),
        Array("测试 文件 ✓.txt".utf8),
        [0x63, 0x61, 0x66, 0xE9],                       // "café" in Latin-1
        [0xC4, 0xE3, 0xBA, 0xC3],                       // "你好" in GBK
        [0xC0, 0xAF],                                   // overlong "/"
        [0xED, 0xA0, 0x80],                             // a UTF-16 surrogate
        [0xF4, 0x90, 0x80, 0x80],                       // above U+10FFFF
        [0xE2, 0x82],                                   // truncated sequence
        Array("\u{10FE41}".utf8)                        // a code point from the escape range
    ]
    for bytes in samples {
        #expect(NFSName.bytes(from: NFSName.string(from: bytes)) == bytes)
    }
    #expect(NFSName.string(from: Array("测试.txt".utf8)) == "测试.txt")
    #expect(NFSName.string(from: [0x61, 0xFF]) == "a\u{10FEFF}")
}
