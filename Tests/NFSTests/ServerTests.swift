import Foundation
import Testing

@testable import NFS

/// Against a real server, when `NFS_TEST_HOST` and `NFS_TEST_EXPORT` name one; the export
/// must be writable by `NFS_TEST_UID`/`NFS_TEST_GID` (default: this process's ids) and have
/// the `insecure` option.
private func serverConfiguration() -> NFSClient.Configuration? {
    let environment = ProcessInfo.processInfo.environment
    guard let host = environment["NFS_TEST_HOST"], !host.isEmpty,
          let export = environment["NFS_TEST_EXPORT"], !export.isEmpty else {
        return nil
    }
    let current = RPCCredential.currentProcess
    return NFSClient.Configuration(
        host: host,
        exportPath: export,
        credential: RPCCredential(
            uid: environment["NFS_TEST_UID"].flatMap { UInt32($0) } ?? current.uid,
            gid: environment["NFS_TEST_GID"].flatMap { UInt32($0) } ?? current.gid
        )
    )
}

@Suite(.enabled(if: serverConfiguration() != nil, "set NFS_TEST_HOST and NFS_TEST_EXPORT"))
struct ServerTests {
    @Test func fileLifecycle() async throws {
        let client = NFSClient(configuration: try #require(serverConfiguration()))
        try await client.connect()
        let root = "nfs-swift-test-\(UUID().uuidString.prefix(8))"
        do {
            try await client.createDirectory(at: root)

            let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            try await client.write(payload, to: "\(root)/file.bin", mode: .guarded)
            #expect(try await client.read("\(root)/file.bin") == payload)
            #expect(try await client.read("\(root)/file.bin", offset: 1000, length: 10) == payload.subdata(in: 1000..<1010))
            await #expect(throws: NFSClientError.alreadyExists(path: "\(root)/file.bin")) {
                try await client.write(Data("x".utf8), to: "\(root)/file.bin", mode: .guarded)
            }

            try await client.write(Data("short".utf8), to: "\(root)/file.bin")
            #expect(try await client.attributes(of: "\(root)/file.bin").size == 5)

            try await client.createDirectory(at: "\(root)/sub")
            try await client.moveItem(at: "\(root)/file.bin", to: "\(root)/sub/moved.bin")
            #expect(try await client.contentsOfDirectory(at: "\(root)/sub").map(\.name) == ["moved.bin"])
            await #expect(throws: NFSClientError.notFound(path: "\(root)/file.bin")) {
                _ = try await client.attributes(of: "\(root)/file.bin")
            }

            try await client.setPermissions(0o600, at: "\(root)/sub/moved.bin")
            #expect(try await client.attributes(of: "\(root)/sub/moved.bin").mode & 0o777 == 0o600)

            // Bytes that are not UTF-8 ("caf\xE9" in Latin-1) survive a listing and come back
            // as the same name.
            let latin1 = NFSName.string(from: [0x63, 0x61, 0x66, 0xE9])
            try await client.write(Data("latin1".utf8), to: "\(root)/\(latin1)", mode: .guarded)
            #expect(try await client.contentsOfDirectory(at: root).map(\.name).contains(latin1))
            #expect(try await client.read("\(root)/\(latin1)") == Data("latin1".utf8))

            // Copies: a tree with a file, a symlink and its permission bits; not onto
            // something that exists, nor into itself.
            try await client.createSymbolicLink(at: "\(root)/sub/link", withDestination: "moved.bin")
            try await client.copyItem(at: "\(root)/sub", to: "\(root)/sub-copy")
            #expect(try await client.destinationOfSymbolicLink(at: "\(root)/sub-copy/link") == "moved.bin")
            #expect(try await client.read("\(root)/sub-copy/moved.bin") == Data("short".utf8))
            #expect(try await client.attributes(of: "\(root)/sub-copy/moved.bin").mode & 0o777 == 0o600)
            await #expect(throws: NFSClientError.alreadyExists(path: "\(root)/sub-copy")) {
                try await client.copyItem(at: "\(root)/sub", to: "\(root)/sub-copy")
            }
            await #expect(throws: NFSClientError.invalidPath("\(root)/sub/inner")) {
                try await client.copyItem(at: "\(root)/sub", to: "\(root)/sub/inner")
            }
            let large = Data((0..<2_500_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
            try await client.write(large, to: "\(root)/large.bin")
            try await client.copyItem(at: "\(root)/large.bin", to: "\(root)/large-copy.bin")
            #expect(try await client.read("\(root)/large-copy.bin") == large)
        } catch {
            try? await client.removeItem(at: root)
            await client.disconnect()
            throw error
        }
        try await client.removeItem(at: root)
        await #expect(throws: NFSClientError.notFound(path: root)) {
            _ = try await client.attributes(of: root)
        }
        await client.disconnect()
    }
}
