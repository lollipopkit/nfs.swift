import Foundation

/// An NFSv3 export, addressed by path.
///
/// Paths are relative to the export's root and use `/` between components; `/` and the
/// empty string both name the root. Handles are looked up once and reused until the server
/// reports them stale, at which point the path is looked up again.
///
/// Requests come from an unprivileged port unless the process can bind one below 1024,
/// which normally takes root. Linux servers refuse unprivileged ports unless the export has
/// the `insecure` option.
public actor NFSClient {
    public struct Configuration: Sendable {
        public var host: String
        /// The NFS service's port. The MOUNT service is found through the portmapper.
        public var port: Int
        public var exportPath: String
        public var credential: RPCCredential
        /// Upper bound for one READ or WRITE, below what the server offers if need be.
        public var maxTransferSize: UInt32

        public init(
            host: String,
            port: Int = 2049,
            exportPath: String,
            credential: RPCCredential = .currentProcess,
            maxTransferSize: UInt32 = 1024 * 1024
        ) {
            self.host = host
            self.port = port
            self.exportPath = exportPath
            self.credential = credential
            self.maxTransferSize = maxTransferSize
        }
    }

    private struct Session {
        let nfs: NFS3Client
        let root: NFSFileHandle
        let readSize: UInt32
        let writeSize: UInt32
    }

    private static let directoryReplySize: UInt32 = 64 * 1024

    public let configuration: Configuration
    private var session: Session?
    private var handles: [String: NFSFileHandle] = [:]

    public var isConnected: Bool { session != nil }

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Lifecycle

    /// Mounts the export and reads the server's transfer sizes.
    public func connect() async throws {
        guard session == nil else { return }
        let host = configuration.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw NFSClientError.invalidPath("") }

        let root: NFSFileHandle
        do {
            root = try await NFS3Client.mount(configuration.exportPath, host: host, credential: configuration.credential)
        } catch let error as MountStatusError {
            throw NFSClientError.mountRefused(error)
        } catch RPCError.authenticationRejected(let stat) {
            throw NFSClientError.credentialsRejected(authStat: stat)
        }

        let nfs = NFS3Client(host: host, port: configuration.port, credential: configuration.credential)
        do {
            let sizes = try await nfs.fsinfo(root)
            session = Session(
                nfs: nfs,
                root: root,
                readSize: clamped(sizes.read),
                writeSize: clamped(sizes.write)
            )
            handles = [:]
        } catch {
            await nfs.close()
            if case RPCError.authenticationRejected(let stat) = error {
                throw NFSClientError.credentialsRejected(authStat: stat)
            }
            throw error
        }
    }

    /// NFSv3 keeps no session on the server, so this only closes the connection. UMNT
    /// would update the server's advisory list of mounts and nothing else.
    public func disconnect() async {
        let session = self.session
        self.session = nil
        handles = [:]
        await session?.nfs.close()
    }

    // MARK: - Reading

    public func attributes(of path: String) async throws -> NFSAttributes {
        try await perform(on: path) { session in
            try await session.nfs.getattr(try await self.handle(for: path, in: session))
        }
    }

    /// Everything in a directory but `.` and `..`, with each entry's attributes.
    public func contentsOfDirectory(at path: String) async throws -> [NFSItem] {
        try await perform(on: path) { session in
            let directory = try await self.handle(for: path, in: session)
            var items: [NFSItem] = []
            for entry in try await self.entries(of: directory, in: session) {
                let childPath = Self.joined(path, entry.name)
                let handle: NFSFileHandle
                let attributes: NFSAttributes
                if let entryHandle = entry.handle, let entryAttributes = entry.attributes {
                    (handle, attributes) = (entryHandle, entryAttributes)
                } else {
                    // READDIRPLUS may leave either out; LOOKUP then supplies them.
                    let (lookedUp, lookedUpAttributes) = try await session.nfs.lookup(entry.name, in: directory)
                    handle = lookedUp
                    if let lookedUpAttributes {
                        attributes = lookedUpAttributes
                    } else {
                        attributes = try await session.nfs.getattr(lookedUp)
                    }
                }
                self.handles[Self.key(childPath)] = handle
                items.append(NFSItem(name: entry.name, attributes: attributes))
            }
            return items
        }
    }

    public func destinationOfSymbolicLink(at path: String) async throws -> String {
        try await perform(on: path) { session in
            try await session.nfs.readlink(try await self.handle(for: path, in: session))
        }
    }

    /// Up to `length` bytes from `offset`; fewer when the file ends first.
    public func read(_ path: String, offset: UInt64 = 0, length: UInt64 = .max) async throws -> Data {
        guard length > 0 else { return Data() }
        return try await perform(on: path) { session in
            let handle = try await self.handle(for: path, in: session)
            var data = Data()
            var position = offset
            while UInt64(data.count) < length {
                let wanted = UInt32(min(UInt64(session.readSize), length - UInt64(data.count)))
                let chunk = try await session.nfs.read(handle, offset: position, count: wanted)
                data.append(contentsOf: chunk.data)
                position += UInt64(chunk.data.count)
                // An empty reply that does not claim the end would otherwise loop forever.
                if chunk.eof || chunk.data.isEmpty { break }
            }
            return data
        }
    }

    // MARK: - Writing

    /// Writes a whole file: `.unchecked` replaces one that exists, `.guarded` fails with
    /// `NFSClientError.alreadyExists`.
    ///
    /// Data goes out as unstable WRITEs followed by one COMMIT. A server that restarts in
    /// between loses unstable data, which a changed write verifier shows; the file is then
    /// written again from the start.
    public func write(_ source: some NFSUploadSource, to path: String, mode: NFSCreateMode = .unchecked) async throws {
        let (parent, name) = try Self.split(path)
        try await perform(on: path) { session in
            let directory = try await self.handle(for: parent, in: session)
            let handle: NFSFileHandle
            do {
                handle = try await session.nfs.create(name, in: directory, mode: mode)
            } catch let error as NFSStatusError where error.status == NFSStatusError.exists {
                throw NFSClientError.alreadyExists(path: path)
            }
            self.handles[Self.key(path)] = handle

            for _ in 0..<3 where try await Self.write(source, to: handle, in: session) {
                return
            }
            throw NFSClientError.serverKeptRestarting(path: path)
        }
    }

    public func write(_ data: Data, to path: String, mode: NFSCreateMode = .unchecked) async throws {
        try await write(DataUploadSource(data: data), to: path, mode: mode)
    }

    public func createDirectory(at path: String) async throws {
        let (parent, name) = try Self.split(path)
        try await perform(on: path) { session in
            let directory = try await self.handle(for: parent, in: session)
            try await session.nfs.mkdir(name, in: directory)
        }
    }

    /// Creates a symbolic link at `path` pointing to `destination`, which the server
    /// stores as given.
    public func createSymbolicLink(at path: String, withDestination destination: String) async throws {
        let (parent, name) = try Self.split(path)
        try await perform(on: path) { session in
            let directory = try await self.handle(for: parent, in: session)
            try await session.nfs.symlink(name, in: directory, target: destination)
        }
    }

    /// Removes a file, or a directory with everything in it.
    public func removeItem(at path: String) async throws {
        _ = try Self.split(path)
        try await perform(on: path) { session in
            try await self.removeRecursively(path, in: session)
        }
    }

    /// Renames or moves an item. NFS replaces an existing destination file; with
    /// `replacing: false` an existing destination fails with `.alreadyExists` instead.
    public func moveItem(at source: String, to destination: String, replacing: Bool = false) async throws {
        let (sourceParent, sourceName) = try Self.split(source)
        let (destinationParent, destinationName) = try Self.split(destination)
        try await perform(on: source) { session in
            let from = try await self.handle(for: sourceParent, in: session)
            let to = try await self.handle(for: destinationParent, in: session)
            if !replacing {
                do {
                    _ = try await session.nfs.lookup(destinationName, in: to)
                    throw NFSClientError.alreadyExists(path: destination)
                } catch let error as NFSStatusError where error.status == NFSStatusError.noEntry {}
            }
            try await session.nfs.rename(sourceName, in: from, to: destinationName, in: to)
            self.forgetHandles(under: source)
            self.forgetHandles(under: destination)
        }
    }

    /// Copies a file, symbolic link or directory tree, with its permission bits.
    ///
    /// NFSv3 has no server-side copy, so file data passes through the client one transfer
    /// at a time. An existing destination fails with `.alreadyExists`, and so does a copy
    /// of a directory into itself, with `.invalidPath`.
    public func copyItem(at source: String, to destination: String) async throws {
        _ = try Self.split(source)
        _ = try Self.split(destination)
        let sourceKey = Self.key(source)
        let destinationKey = Self.key(destination)
        guard destinationKey != sourceKey, !destinationKey.hasPrefix(sourceKey + "/") else {
            throw NFSClientError.invalidPath(destination)
        }
        try await perform(on: source) { session in
            try await self.copyRecursively(source, to: destination, in: session)
        }
    }

    /// Sets the permission bits, `0o7777` at most.
    public func setPermissions(_ mode: UInt32, at path: String) async throws {
        try await perform(on: path) { session in
            try await session.nfs.setMode(mode & 0o7777, of: try await self.handle(for: path, in: session))
        }
    }

    // MARK: - Private

    /// Runs `body`, translating failures, and once more after a stale handle: a server
    /// forgets handles when an export is re-exported or its file system remounted, and
    /// looking the path up again from the root finds the current ones. A stale root
    /// handle needs a new mount.
    private func perform<T>(on path: String, _ body: (Session) async throws -> T) async throws -> T {
        guard let session else { throw NFSClientError.notConnected }
        do {
            do {
                return try await body(session)
            } catch let error as NFSStatusError where Self.isStale(error) {
                handles = [:]
                return try await body(session)
            }
        } catch let error as NFSStatusError where Self.isStale(error) {
            self.session = nil
            await session.nfs.close()
            throw NFSClientError.exportNoLongerMounted
        } catch let error as NFSStatusError {
            throw NFSClientError(status: error, path: path)
        }
    }

    private func handle(for path: String, in session: Session) async throws -> NFSFileHandle {
        let components = Self.components(path)
        guard let name = components.last else { return session.root }
        let key = Self.key(path)
        if let cached = handles[key] { return cached }
        let directory = try await handle(for: components.dropLast().joined(separator: "/"), in: session)
        do {
            let (handle, _) = try await session.nfs.lookup(name, in: directory)
            handles[key] = handle
            return handle
        } catch let error as NFSStatusError where error.status == NFSStatusError.noEntry {
            throw NFSClientError.notFound(path: path)
        }
    }

    private func forgetHandles(under path: String) {
        let key = Self.key(path)
        handles = handles.filter { $0.key != key && !$0.key.hasPrefix(key + "/") }
    }

    private func entries(of directory: NFSFileHandle, in session: Session) async throws -> [NFSDirectoryEntry] {
        do {
            return try await session.nfs.readdirplus(directory, maxReplySize: Self.directoryReplySize)
        } catch let error as NFSStatusError where error.status == NFSStatusError.notSupported {
            return try await session.nfs.readdir(directory, maxReplySize: Self.directoryReplySize)
                .map { NFSDirectoryEntry(name: $0, attributes: nil, handle: nil) }
        }
    }

    private func removeRecursively(_ path: String, in session: Session) async throws {
        let (parent, name) = try Self.split(path)
        let handle = try await handle(for: path, in: session)
        let directory = try await self.handle(for: parent, in: session)
        if try await session.nfs.getattr(handle).type == .directory {
            for entry in try await entries(of: handle, in: session) {
                try await removeRecursively(Self.joined(path, entry.name), in: session)
            }
            try await session.nfs.rmdir(name, in: directory)
        } else {
            try await session.nfs.remove(name, in: directory)
        }
        forgetHandles(under: path)
    }

    private func copyRecursively(_ source: String, to destination: String, in session: Session) async throws {
        let (parent, name) = try Self.split(destination)
        let sourceHandle = try await handle(for: source, in: session)
        let attributes = try await session.nfs.getattr(sourceHandle)
        let directory = try await handle(for: parent, in: session)

        // Failures here are about the destination, which `perform` cannot tell.
        func creating<T>(_ body: () async throws -> T) async throws -> T {
            do {
                return try await body()
            } catch let error as NFSStatusError {
                throw NFSClientError(status: error, path: destination)
            }
        }

        switch attributes.type {
        case .directory:
            try await creating { try await session.nfs.mkdir(name, in: directory) }
            for entry in try await entries(of: sourceHandle, in: session) {
                try await copyRecursively(Self.joined(source, entry.name), to: Self.joined(destination, entry.name), in: session)
            }
        case .symlink:
            let target = try await session.nfs.readlink(sourceHandle)
            try await creating { try await session.nfs.symlink(name, in: directory, target: target) }
            return
        case .regular:
            let copy = try await creating { try await session.nfs.create(name, in: directory, mode: .guarded) }
            handles[Self.key(destination)] = copy
            var completed = false
            for _ in 0..<3 where !completed {
                completed = try await Self.copyData(from: sourceHandle, to: copy, in: session)
            }
            guard completed else { throw NFSClientError.serverKeptRestarting(path: destination) }
        default:
            throw NFSClientError.unsupportedFileType(path: source)
        }
        // Last, so a read-only directory is still writable while it is filled.
        let copied = try await handle(for: destination, in: session)
        try await session.nfs.setMode(attributes.mode & 0o7777, of: copied)
    }

    /// Whether the whole file is durable under one write verifier.
    private static func copyData(from source: NFSFileHandle, to destination: NFSFileHandle, in session: Session) async throws -> Bool {
        var verifier: [UInt8]?
        var offset: UInt64 = 0
        while true {
            let chunk = try await session.nfs.read(source, offset: offset, count: session.readSize)
            var written = 0
            while written < chunk.data.count {
                let size = min(chunk.data.count - written, Int(session.writeSize))
                let result = try await session.nfs.write(
                    destination,
                    offset: offset + UInt64(written),
                    data: chunk.data[written..<(written + size)]
                )
                guard result.count != 0 else { throw NFSClientError.serverAcceptedNoData }
                if let verifier, verifier != result.verifier { return false }
                verifier = result.verifier
                written += Int(result.count)
            }
            offset += UInt64(chunk.data.count)
            if chunk.eof || chunk.data.isEmpty { break }
        }
        guard let verifier else { return true }
        return try await session.nfs.commit(destination) == verifier
    }

    /// Whether everything written is durable under one write verifier.
    private static func write(_ source: some NFSUploadSource, to handle: NFSFileHandle, in session: Session) async throws -> Bool {
        guard source.count > 0 else { return true }
        var verifier: [UInt8]?
        var offset: UInt64 = 0
        while offset < source.count {
            let chunk = try source.chunk(at: offset, maxLength: Int(session.writeSize))
            guard !chunk.isEmpty else { throw NFSClientError.sourceEndedEarly }
            var written = 0
            while written < chunk.count {
                let result = try await session.nfs.write(handle, offset: offset + UInt64(written), data: chunk[written...])
                guard result.count != 0 else { throw NFSClientError.serverAcceptedNoData }
                if let verifier, verifier != result.verifier { return false }
                verifier = result.verifier
                written += Int(result.count)
            }
            offset += UInt64(chunk.count)
        }
        return try await session.nfs.commit(handle) == verifier
    }

    private func clamped(_ size: UInt32) -> UInt32 {
        min(max(size, 4096), max(configuration.maxTransferSize, 4096))
    }

    private static func isStale(_ error: NFSStatusError) -> Bool {
        error.status == NFSStatusError.stale || error.status == NFSStatusError.badHandle
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private static func key(_ path: String) -> String {
        "/" + components(path).joined(separator: "/")
    }

    private static func joined(_ directory: String, _ name: String) -> String {
        key(directory) == "/" ? "/" + name : key(directory) + "/" + name
    }

    /// The parent directory and name of a path that is not the root.
    static func split(_ path: String) throws -> (parent: String, name: String) {
        let components = components(path)
        guard let name = components.last, name != ".", name != ".." else {
            throw NFSClientError.invalidPath(path)
        }
        return (components.dropLast().joined(separator: "/"), name)
    }
}

/// One entry of a directory listing.
public struct NFSItem: Sendable {
    public let name: String
    public let attributes: NFSAttributes
}

/// Bytes to upload, read in pieces so a large local file is never held whole.
public protocol NFSUploadSource: Sendable {
    var count: UInt64 { get }
    func chunk(at offset: UInt64, maxLength: Int) throws -> [UInt8]
}

public struct DataUploadSource: NFSUploadSource {
    public let data: Data
    public var count: UInt64 { UInt64(data.count) }

    public init(data: Data) {
        self.data = data
    }

    public func chunk(at offset: UInt64, maxLength: Int) throws -> [UInt8] {
        let start = data.startIndex + Int(offset)
        return [UInt8](data[start..<min(start + maxLength, data.endIndex)])
    }
}

/// A local file, read as it is uploaded.
public final class FileUploadSource: NFSUploadSource, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    public let count: UInt64

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        count = try handle.seekToEnd()
    }

    deinit {
        try? handle.close()
    }

    public func chunk(at offset: UInt64, maxLength: Int) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        try handle.seek(toOffset: offset)
        return [UInt8](try handle.read(upToCount: maxLength) ?? Data())
    }
}

public enum NFSClientError: Error, Equatable, LocalizedError {
    case notConnected
    case invalidPath(String)
    case notFound(path: String)
    case alreadyExists(path: String)
    case notDirectory(path: String)
    case isDirectory(path: String)
    case permissionDenied(path: String)
    case directoryNotEmpty(path: String)
    /// Any other `nfsstat3`.
    case server(NFSStatusError, path: String)
    /// The portmapper lists no MOUNT v3 service: the server is NFSv4-only, or not NFS.
    case noMountService
    case mountRefused(MountStatusError)
    case credentialsRejected(authStat: UInt32)
    /// The export's root handle went stale; connect again.
    case exportNoLongerMounted
    case serverKeptRestarting(path: String)
    case serverAcceptedNoData
    case sourceEndedEarly
    /// Devices, sockets and FIFOs cannot be copied.
    case unsupportedFileType(path: String)

    init(status: NFSStatusError, path: String) {
        switch status.status {
        case NFSStatusError.noEntry: self = .notFound(path: path)
        case NFSStatusError.exists: self = .alreadyExists(path: path)
        case NFSStatusError.notDirectory: self = .notDirectory(path: path)
        case NFSStatusError.isDirectory: self = .isDirectory(path: path)
        case NFSStatusError.perm, NFSStatusError.access, NFSStatusError.readOnlyFS: self = .permissionDenied(path: path)
        case NFSStatusError.notEmpty: self = .directoryNotEmpty(path: path)
        default: self = .server(status, path: path)
        }
    }

    /// Whether the server refused the client as such, which with Linux servers usually
    /// means a request from a port above 1024 to an export without `insecure`.
    public var mayNeedInsecureExport: Bool {
        switch self {
        case .mountRefused(let error): return error.status == 1 || error.status == 13
        case .credentialsRejected: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        let insecureHint = " Linux servers refuse clients on ports above 1024 unless the export has the `insecure` option."
        switch self {
        case .notConnected: return "Not connected to the NFS server"
        case .invalidPath(let path): return "Invalid path: \(path)"
        case .notFound(let path): return "\(path) does not exist"
        case .alreadyExists(let path): return "\(path) already exists"
        case .notDirectory(let path): return "\(path) is not a directory"
        case .isDirectory(let path): return "\(path) is a directory"
        case .permissionDenied(let path): return "Permission denied: \(path)"
        case .directoryNotEmpty(let path): return "\(path) is not empty"
        case .server(let status, let path): return "\(status.localizedDescription): \(path)"
        case .noMountService: return "The server does not offer NFSv3 (no MOUNT v3 service is registered). NFSv4-only servers are not supported."
        case .mountRefused(let error): return (error.errorDescription ?? "") + (mayNeedInsecureExport ? "." + insecureHint : "")
        case .credentialsRejected(let stat): return "The server rejected the credentials (auth_stat \(stat))." + insecureHint
        case .exportNoLongerMounted: return "The NFS server no longer recognizes the mounted export"
        case .serverKeptRestarting(let path): return "The NFS server kept restarting while \(path) was written"
        case .serverAcceptedNoData: return "The NFS server accepted no data"
        case .sourceEndedEarly: return "The upload source ended before its stated size"
        case .unsupportedFileType(let path): return "\(path) is a device, socket or FIFO, which cannot be copied"
        }
    }
}
