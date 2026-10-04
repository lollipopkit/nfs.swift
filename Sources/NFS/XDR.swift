import Foundation

/// XDR encoding (RFC 4506): big-endian, every item padded to a multiple of four bytes.
struct XDREncoder {
    private(set) var bytes: [UInt8] = []

    mutating func encode(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func encode(_ value: UInt64) {
        encode(UInt32(truncatingIfNeeded: value >> 32))
        encode(UInt32(truncatingIfNeeded: value))
    }

    mutating func encode(_ value: Bool) {
        encode(UInt32(value ? 1 : 0))
    }

    /// Variable-length opaque data: a length, then the bytes, then padding.
    mutating func encodeOpaque<Bytes: Collection>(_ data: Bytes) where Bytes.Element == UInt8 {
        encode(UInt32(data.count))
        encodeFixedOpaque(data)
    }

    /// Fixed-length opaque data: the bytes and padding, without a length.
    mutating func encodeFixedOpaque<Bytes: Collection>(_ data: Bytes) where Bytes.Element == UInt8 {
        bytes.append(contentsOf: data)
        bytes.append(contentsOf: repeatElement(0, count: (4 - data.count % 4) % 4))
    }

    mutating func encode(_ string: String) {
        encodeOpaque(Array(string.utf8))
    }
}

/// Reads XDR data, throwing `XDRError.truncated` rather than reading past the end.
struct XDRDecoder {
    private let bytes: [UInt8]
    private var offset: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
    }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func decodeUInt32() throws -> UInt32 {
        guard bytes.count - offset >= 4 else { throw XDRError.truncated }
        defer { offset += 4 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    mutating func decodeUInt64() throws -> UInt64 {
        let high = try decodeUInt32()
        let low = try decodeUInt32()
        return UInt64(high) << 32 | UInt64(low)
    }

    mutating func decodeBool() throws -> Bool {
        switch try decodeUInt32() {
        case 0: return false
        case 1: return true
        default: throw XDRError.invalidBool
        }
    }

    /// Variable-length opaque data, refusing a declared length above `maxLength`.
    mutating func decodeOpaque(maxLength: Int = .max) throws -> [UInt8] {
        let length = Int(try decodeUInt32())
        guard length <= maxLength else { throw XDRError.tooLong(length) }
        return try decodeFixedOpaque(length: length)
    }

    mutating func decodeFixedOpaque(length: Int) throws -> [UInt8] {
        let padded = length + (4 - length % 4) % 4
        guard length >= 0, bytes.count - offset >= padded else { throw XDRError.truncated }
        defer { offset += padded }
        return Array(bytes[offset..<(offset + length)])
    }

    mutating func decodeString(maxLength: Int = .max) throws -> String {
        let raw = try decodeOpaque(maxLength: maxLength)
        // File names are bytes on the server; one that is not UTF-8 is shown with
        // replacement characters rather than failing the whole listing.
        return String(decoding: raw, as: UTF8.self)
    }
}

enum XDRError: Error, Equatable {
    case truncated
    case invalidBool
    case tooLong(Int)
}
