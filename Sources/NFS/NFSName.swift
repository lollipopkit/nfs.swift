/// File names and symlink targets between the server's bytes and Swift strings.
///
/// NFS names are bytes. Most are UTF-8, but a server can hold anything a file system
/// accepts, such as names written in Latin-1 or GBK. Bytes that are not valid UTF-8 become
/// one code point each in U+10FE00–U+10FEFF (Supplementary Private Use Area-B), and turn
/// back into the same byte on the way out, so such files can still be opened, renamed and
/// deleted.
///
/// A name that really contains code points from that range is escaped the same way, byte
/// by byte, so the mapping is lossless in both directions.
public enum NFSName {
    static let escapeBase: UInt32 = 0x10FE00

    public static func string(from bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        var index = 0
        while index < bytes.count {
            if let (scalar, length) = decodeScalar(bytes, at: index), !isEscape(scalar) {
                scalars.append(scalar)
                index += length
            } else {
                scalars.append(Unicode.Scalar(escapeBase + UInt32(bytes[index]))!)
                index += 1
            }
        }
        return String(scalars)
    }

    public static func bytes(from string: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for scalar in string.unicodeScalars {
            if isEscape(scalar) {
                bytes.append(UInt8(scalar.value - escapeBase))
            } else {
                bytes.append(contentsOf: Array(String(scalar).utf8))
            }
        }
        return bytes
    }

    private static func isEscape(_ scalar: Unicode.Scalar) -> Bool {
        (escapeBase...(escapeBase + 0xFF)).contains(scalar.value)
    }

    /// One well-formed UTF-8 sequence (RFC 3629): no overlong forms, no surrogates,
    /// nothing above U+10FFFF.
    private static func decodeScalar(_ bytes: [UInt8], at index: Int) -> (Unicode.Scalar, Int)? {
        let lead = bytes[index]
        let length: Int
        let minimum: UInt32
        var value: UInt32
        switch lead {
        case 0x00...0x7F: return (Unicode.Scalar(lead), 1)
        case 0xC2...0xDF: (length, minimum, value) = (2, 0x80, UInt32(lead & 0x1F))
        case 0xE0...0xEF: (length, minimum, value) = (3, 0x800, UInt32(lead & 0x0F))
        case 0xF0...0xF4: (length, minimum, value) = (4, 0x10000, UInt32(lead & 0x07))
        default: return nil
        }
        guard index + length <= bytes.count else { return nil }
        for offset in 1..<length {
            let byte = bytes[index + offset]
            guard byte & 0xC0 == 0x80 else { return nil }
            value = value << 6 | UInt32(byte & 0x3F)
        }
        guard value >= minimum, let scalar = Unicode.Scalar(value) else { return nil }
        return (scalar, length)
    }
}
