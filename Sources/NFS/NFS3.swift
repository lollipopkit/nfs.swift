import Foundation

// NFS version 3 (RFC 1813) and its MOUNT protocol, as far as MFuse uses them.

/// An NFS file handle: opaque to the client, at most 64 bytes.
public struct NFSFileHandle: Sendable, Hashable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }
}

public enum NFSFileType: UInt32, Sendable {
    case regular = 1, directory, block, character, symlink, socket, fifo
}

/// `fattr3`.
public struct NFSAttributes: Sendable, Equatable {
    public var type: NFSFileType
    /// Permission bits, including setuid, setgid and sticky.
    public var mode: UInt32
    public var uid: UInt32
    public var gid: UInt32
    public var size: UInt64
    public var fileID: UInt64
    public var modified: Date
    public var changed: Date
}

/// `nfsstat3` values other than `NFS3_OK`.
public struct NFSStatusError: Error, Equatable, LocalizedError {
    public let status: UInt32

    public init(status: UInt32) {
        self.status = status
    }

    public static let perm: UInt32 = 1
    public static let noEntry: UInt32 = 2
    public static let access: UInt32 = 13
    public static let exists: UInt32 = 17
    public static let notDirectory: UInt32 = 20
    public static let isDirectory: UInt32 = 21
    public static let readOnlyFS: UInt32 = 30
    public static let notEmpty: UInt32 = 66
    public static let stale: UInt32 = 70
    public static let badHandle: UInt32 = 10001
    public static let notSupported: UInt32 = 10004
    public static let jukebox: UInt32 = 10008

    public var errorDescription: String? {
        let names: [UInt32: String] = [
            1: "NFS3ERR_PERM", 2: "NFS3ERR_NOENT", 5: "NFS3ERR_IO", 6: "NFS3ERR_NXIO",
            13: "NFS3ERR_ACCES", 17: "NFS3ERR_EXIST", 18: "NFS3ERR_XDEV", 19: "NFS3ERR_NODEV",
            20: "NFS3ERR_NOTDIR", 21: "NFS3ERR_ISDIR", 22: "NFS3ERR_INVAL", 27: "NFS3ERR_FBIG",
            28: "NFS3ERR_NOSPC", 30: "NFS3ERR_ROFS", 31: "NFS3ERR_MLINK", 63: "NFS3ERR_NAMETOOLONG",
            66: "NFS3ERR_NOTEMPTY", 69: "NFS3ERR_DQUOT", 70: "NFS3ERR_STALE", 71: "NFS3ERR_REMOTE",
            10001: "NFS3ERR_BADHANDLE", 10002: "NFS3ERR_NOT_SYNC", 10003: "NFS3ERR_BAD_COOKIE",
            10004: "NFS3ERR_NOTSUPP", 10005: "NFS3ERR_TOOSMALL", 10006: "NFS3ERR_SERVERFAULT",
            10007: "NFS3ERR_BADTYPE", 10008: "NFS3ERR_JUKEBOX"
        ]
        return "NFS server error \(names[status] ?? String(status))"
    }
}

/// `MNT3ERR_*` from the MOUNT service.
public struct MountStatusError: Error, Equatable, LocalizedError {
    public let status: UInt32

    public init(status: UInt32) {
        self.status = status
    }

    public var errorDescription: String? {
        switch status {
        case 1: return "The server refused to mount the export (MNT3ERR_PERM)"
        case 2: return "The export path does not exist on the server (MNT3ERR_NOENT)"
        case 13: return "The server denied access to the export (MNT3ERR_ACCES)"
        case 20: return "The export path is not a directory (MNT3ERR_NOTDIR)"
        default: return "The server refused to mount the export (status \(status))"
        }
    }
}

/// One entry from READDIRPLUS.
public struct NFSDirectoryEntry: Sendable {
    public let name: String
    public let attributes: NFSAttributes?
    public let handle: NFSFileHandle?
}

/// What `CREATE` does when the name is taken.
public enum NFSCreateMode: Sendable {
    /// Truncates and reuses an existing file.
    case unchecked
    /// Fails with `NFS3ERR_EXIST`.
    case guarded
}

/// Transfer sizes from FSINFO.
public struct NFSTransferSizes: Sendable {
    public var read: UInt32
    public var write: UInt32
    public var directory: UInt32
}

enum PortMapper {
    static let port = 111
    private static let program: UInt32 = 100_000

    /// PMAPPROC_GETPORT over TCP; 0 means the service is not registered.
    static func port(of program: UInt32, version: UInt32, using client: RPCClient) async throws -> Int {
        var args = XDREncoder()
        args.encode(program)
        args.encode(version)
        args.encode(UInt32(6))    // IPPROTO_TCP
        args.encode(UInt32(0))
        var reply = try await client.call(program: Self.program, version: 2, procedure: 3, arguments: args.bytes, idempotent: true)
        return Int(try reply.decodeUInt32())
    }
}

enum MountProtocol {
    static let program: UInt32 = 100_005
    static let version: UInt32 = 3

    /// MOUNTPROC3_MNT: the root handle of `exportPath`.
    static func mount(_ exportPath: String, using client: RPCClient) async throws -> NFSFileHandle {
        var args = XDREncoder()
        args.encodeName(exportPath)
        var reply = try await client.call(program: program, version: version, procedure: 1, arguments: args.bytes, idempotent: true)
        let status = try reply.decodeUInt32()
        guard status == 0 else { throw MountStatusError(status: status) }
        return NFSFileHandle(bytes: try reply.decodeOpaque(maxLength: 64))
    }

    /// MOUNTPROC3_UMNT. The server only uses it for its `showmount` bookkeeping.
    static func unmount(_ exportPath: String, using client: RPCClient) async throws {
        var args = XDREncoder()
        args.encodeName(exportPath)
        _ = try await client.call(program: program, version: version, procedure: 3, arguments: args.bytes, idempotent: true)
    }
}

/// The NFSv3 procedures, one call each, over one TCP connection to the NFS service.
///
/// `NFSClient` builds on this; use it directly for what that does not cover.
public struct NFS3Client: Sendable {
    static let program: UInt32 = 100_003
    static let version: UInt32 = 3

    let rpc: RPCClient

    public init(host: String, port: Int = 2049, credential: RPCCredential) {
        self.rpc = RPCClient(host: host, port: port, credential: credential)
    }

    public func close() async {
        await rpc.close()
    }

    /// The root handle of `exportPath`, from the MOUNT service the portmapper on
    /// `host` names.
    public static func mount(_ exportPath: String, host: String, credential: RPCCredential) async throws -> NFSFileHandle {
        let portMapper = RPCClient(host: host, port: PortMapper.port, credential: credential)
        let mountPort: Int
        do {
            mountPort = try await PortMapper.port(of: MountProtocol.program, version: MountProtocol.version, using: portMapper)
            await portMapper.close()
        } catch {
            await portMapper.close()
            throw error
        }
        guard mountPort != 0 else { throw NFSClientError.noMountService }
        let mountClient = RPCClient(host: host, port: mountPort, credential: credential)
        do {
            let root = try await MountProtocol.mount(exportPath, using: mountClient)
            await mountClient.close()
            return root
        } catch {
            await mountClient.close()
            throw error
        }
    }

    private enum Procedure: UInt32 {
        case null = 0, getattr, setattr, lookup, access, readlink, read, write, create, mkdir
        case symlink, mknod, remove, rmdir, rename, link, readdir, readdirplus, fsstat, fsinfo
        case pathconf, commit
    }

    public func null() async throws {
        _ = try await call(.null, idempotent: true) { _ in }
    }

    public func getattr(_ handle: NFSFileHandle) async throws -> NFSAttributes {
        var reply = try await call(.getattr, idempotent: true) { $0.encode(handle) }
        try reply.decodeStatus()
        return try reply.decodeAttributes()
    }

    public func setMode(_ mode: UInt32, of handle: NFSFileHandle) async throws {
        var reply = try await call(.setattr, idempotent: true) {
            $0.encode(handle)
            $0.encodeSetAttributes(mode: mode)
            $0.encode(false)    // no ctime guard
        }
        try reply.decodeStatus()
    }

    /// The handle and attributes of `name` inside `directory`.
    public func lookup(_ name: String, in directory: NFSFileHandle) async throws -> (NFSFileHandle, NFSAttributes?) {
        var reply = try await call(.lookup, idempotent: true) {
            $0.encode(directory)
            $0.encodeName(name)
        }
        try reply.decodeStatus()
        let handle = try reply.decodeHandle()
        return (handle, try reply.decodeOptionalAttributes())
    }

    /// Up to `count` bytes from `offset`, and whether they reach the end of the file.
    public func read(_ handle: NFSFileHandle, offset: UInt64, count: UInt32) async throws -> (data: [UInt8], eof: Bool) {
        var reply = try await call(.read, idempotent: true) {
            $0.encode(handle)
            $0.encode(offset)
            $0.encode(count)
        }
        try reply.decodeStatus()
        _ = try reply.decodeOptionalAttributes()
        _ = try reply.decodeUInt32()                     // count
        let eof = try reply.decodeBool()
        let data = try reply.decodeOpaque(maxLength: Int(count))
        return (data, eof)
    }

    /// Writes unstable data and returns how many bytes the server took, and the write
    /// verifier COMMIT is checked against.
    public func write(_ handle: NFSFileHandle, offset: UInt64, data: ArraySlice<UInt8>) async throws -> (count: UInt32, verifier: [UInt8]) {
        var reply = try await call(.write, idempotent: true) {
            $0.encode(handle)
            $0.encode(offset)
            $0.encode(UInt32(data.count))
            $0.encode(UInt32(0))                         // UNSTABLE
            $0.encodeOpaque(data)
        }
        try reply.decodeStatus()
        try reply.skipWCC()
        let count = try reply.decodeUInt32()
        _ = try reply.decodeUInt32()                     // committed
        return (count, try reply.decodeFixedOpaque(length: 8))
    }

    /// Makes unstable writes durable and returns the verifier they must still match.
    public func commit(_ handle: NFSFileHandle) async throws -> [UInt8] {
        var reply = try await call(.commit, idempotent: true) {
            $0.encode(handle)
            $0.encode(UInt64(0))
            $0.encode(UInt32(0))                         // to the end of the file
        }
        try reply.decodeStatus()
        try reply.skipWCC()
        return try reply.decodeFixedOpaque(length: 8)
    }

    /// Creates `name`, or with `.unchecked` truncates the file already there.
    public func create(_ name: String, in directory: NFSFileHandle, mode: NFSCreateMode) async throws -> NFSFileHandle {
        var reply = try await call(.create, idempotent: false) {
            $0.encode(directory)
            $0.encodeName(name)
            $0.encode(UInt32(mode == .unchecked ? 0 : 1))
            $0.encodeSetAttributes(mode: 0o644, size: 0)
        }
        try reply.decodeStatus()
        guard let handle = try reply.decodeOptionalHandle() else {
            // RFC 1813 lets a server leave the handle out; it is then looked up.
            return try await lookup(name, in: directory).0
        }
        return handle
    }

    public func mkdir(_ name: String, in directory: NFSFileHandle) async throws {
        var reply = try await call(.mkdir, idempotent: false) {
            $0.encode(directory)
            $0.encodeName(name)
            $0.encodeSetAttributes(mode: 0o755)
        }
        try reply.decodeStatus()
    }

    public func symlink(_ name: String, in directory: NFSFileHandle, target: String) async throws {
        var reply = try await call(.symlink, idempotent: false) {
            $0.encode(directory)
            $0.encodeName(name)
            $0.encodeSetAttributes()
            $0.encodeName(target)
        }
        try reply.decodeStatus()
    }

    public func remove(_ name: String, in directory: NFSFileHandle) async throws {
        var reply = try await call(.remove, idempotent: false) {
            $0.encode(directory)
            $0.encodeName(name)
        }
        try reply.decodeStatus()
    }

    public func rmdir(_ name: String, in directory: NFSFileHandle) async throws {
        var reply = try await call(.rmdir, idempotent: false) {
            $0.encode(directory)
            $0.encodeName(name)
        }
        try reply.decodeStatus()
    }

    public func rename(_ name: String, in directory: NFSFileHandle, to newName: String, in newDirectory: NFSFileHandle) async throws {
        var reply = try await call(.rename, idempotent: false) {
            $0.encode(directory)
            $0.encodeName(name)
            $0.encode(newDirectory)
            $0.encodeName(newName)
        }
        try reply.decodeStatus()
    }

    /// Every entry of `directory` but `.` and `..`, paging through READDIRPLUS.
    public func readdirplus(_ directory: NFSFileHandle, maxReplySize: UInt32) async throws -> [NFSDirectoryEntry] {
        var entries: [NFSDirectoryEntry] = []
        var cookie: UInt64 = 0
        var cookieVerifier = [UInt8](repeating: 0, count: 8)
        while true {
            var reply = try await call(.readdirplus, idempotent: true) {
                $0.encode(directory)
                $0.encode(cookie)
                $0.encodeFixedOpaque(cookieVerifier)
                $0.encode(maxReplySize / 4)              // dircount: names and cookies only
                $0.encode(maxReplySize)
            }
            try reply.decodeStatus()
            _ = try reply.decodeOptionalAttributes()
            cookieVerifier = try reply.decodeFixedOpaque(length: 8)
            var sawEntry = false
            while try reply.decodeBool() {
                sawEntry = true
                _ = try reply.decodeUInt64()             // fileid
                let name = NFSName.string(from: try reply.decodeOpaque(maxLength: 255))
                cookie = try reply.decodeUInt64()
                let attributes = try reply.decodeOptionalAttributes()
                let handle = try reply.decodeOptionalHandle()
                if name != "." && name != ".." {
                    entries.append(NFSDirectoryEntry(name: name, attributes: attributes, handle: handle))
                }
            }
            if try reply.decodeBool() { return entries }
            // A page without entries that is not the last one would loop forever.
            guard sawEntry else { throw RPCError.malformedReply }
        }
    }

    /// Names only, for servers without READDIRPLUS.
    public func readdir(_ directory: NFSFileHandle, maxReplySize: UInt32) async throws -> [String] {
        var names: [String] = []
        var cookie: UInt64 = 0
        var cookieVerifier = [UInt8](repeating: 0, count: 8)
        while true {
            var reply = try await call(.readdir, idempotent: true) {
                $0.encode(directory)
                $0.encode(cookie)
                $0.encodeFixedOpaque(cookieVerifier)
                $0.encode(maxReplySize)
            }
            try reply.decodeStatus()
            _ = try reply.decodeOptionalAttributes()
            cookieVerifier = try reply.decodeFixedOpaque(length: 8)
            var sawEntry = false
            while try reply.decodeBool() {
                sawEntry = true
                _ = try reply.decodeUInt64()             // fileid
                let name = NFSName.string(from: try reply.decodeOpaque(maxLength: 255))
                cookie = try reply.decodeUInt64()
                if name != "." && name != ".." {
                    names.append(name)
                }
            }
            if try reply.decodeBool() { return names }
            guard sawEntry else { throw RPCError.malformedReply }
        }
    }

    public func readlink(_ handle: NFSFileHandle) async throws -> String {
        var reply = try await call(.readlink, idempotent: true) { $0.encode(handle) }
        try reply.decodeStatus()
        _ = try reply.decodeOptionalAttributes()
        return NFSName.string(from: try reply.decodeOpaque(maxLength: 4096))
    }

    public func fsinfo(_ root: NFSFileHandle) async throws -> NFSTransferSizes {
        var reply = try await call(.fsinfo, idempotent: true) { $0.encode(root) }
        try reply.decodeStatus()
        _ = try reply.decodeOptionalAttributes()
        let rtmax = try reply.decodeUInt32()
        _ = try reply.decodeUInt32()                     // rtpref
        _ = try reply.decodeUInt32()                     // rtmult
        let wtmax = try reply.decodeUInt32()
        _ = try reply.decodeUInt32()                     // wtpref
        _ = try reply.decodeUInt32()                     // wtmult
        let dtpref = try reply.decodeUInt32()
        return NFSTransferSizes(read: rtmax, write: wtmax, directory: dtpref)
    }

    // MARK: - Private

    /// `NFS3ERR_JUKEBOX` means the server is fetching the data (from tape, say) and asks
    /// to be called again shortly.
    private func call(
        _ procedure: Procedure,
        idempotent: Bool,
        arguments: (inout XDREncoder) -> Void
    ) async throws -> XDRDecoder {
        var xdr = XDREncoder()
        arguments(&xdr)
        for attempt in 0..<5 {
            let reply = try await rpc.call(
                program: Self.program,
                version: Self.version,
                procedure: procedure.rawValue,
                arguments: xdr.bytes,
                idempotent: idempotent
            )
            var peek = reply
            guard procedure != .null, try peek.decodeUInt32() == NFSStatusError.jukebox, attempt < 4 else {
                return reply
            }
            try await Task.sleep(for: .seconds(1 << attempt))
        }
        preconditionFailure("unreachable: the last attempt always returns")
    }
}

// MARK: - XDR helpers for NFS types

extension XDREncoder {
    mutating func encode(_ handle: NFSFileHandle) {
        encodeOpaque(handle.bytes)
    }

    /// A file name or symlink target, as the bytes `NFSName` maps it back to.
    mutating func encodeName(_ name: String) {
        encodeOpaque(NFSName.bytes(from: name))
    }

    /// `sattr3` setting only what is given.
    mutating func encodeSetAttributes(mode: UInt32? = nil, size: UInt64? = nil) {
        encode(mode != nil)
        if let mode { encode(mode) }
        encode(false)                                    // uid
        encode(false)                                    // gid
        encode(size != nil)
        if let size { encode(size) }
        encode(UInt32(0))                                // atime: DONT_CHANGE
        encode(UInt32(0))                                // mtime: DONT_CHANGE
    }
}

extension XDRDecoder {
    /// Throws the `nfsstat3` at the head of a result. What follows a failure is not read.
    mutating func decodeStatus() throws {
        let status = try decodeUInt32()
        guard status == 0 else { throw NFSStatusError(status: status) }
    }

    mutating func decodeHandle() throws -> NFSFileHandle {
        NFSFileHandle(bytes: try decodeOpaque(maxLength: 64))
    }

    mutating func decodeOptionalHandle() throws -> NFSFileHandle? {
        try decodeBool() ? try decodeHandle() : nil
    }

    mutating func decodeAttributes() throws -> NFSAttributes {
        let rawType = try decodeUInt32()
        guard let type = NFSFileType(rawValue: rawType) else { throw RPCError.malformedReply }
        let mode = try decodeUInt32()
        _ = try decodeUInt32()                           // nlink
        let uid = try decodeUInt32()
        let gid = try decodeUInt32()
        let size = try decodeUInt64()
        _ = try decodeUInt64()                           // used
        _ = try decodeUInt64()                           // rdev
        _ = try decodeUInt64()                           // fsid
        let fileID = try decodeUInt64()
        _ = try decodeTime()                             // atime
        let modified = try decodeTime()
        let changed = try decodeTime()
        return NFSAttributes(type: type, mode: mode, uid: uid, gid: gid, size: size, fileID: fileID, modified: modified, changed: changed)
    }

    mutating func decodeOptionalAttributes() throws -> NFSAttributes? {
        try decodeBool() ? try decodeAttributes() : nil
    }

    mutating func skipOptionalAttributes() throws {
        _ = try decodeOptionalAttributes()
    }

    mutating func skipWCC() throws {
        if try decodeBool() {                            // pre_op_attr: size, mtime, ctime
            _ = try decodeUInt64()
            _ = try decodeTime()
            _ = try decodeTime()
        }
        try skipOptionalAttributes()
    }

    private mutating func decodeTime() throws -> Date {
        let seconds = try decodeUInt32()
        let nanoseconds = try decodeUInt32()
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000)
    }
}
