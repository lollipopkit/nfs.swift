# nfs.swift

An NFSv3 client in Swift, built on SwiftNIO. It speaks ONC RPC over TCP directly, so it needs no kernel mount, no `mount_nfs` and no root, and works inside an app sandbox.

- NFSv3 (RFC 1813) with the MOUNT and portmapper protocols; `AUTH_SYS` credentials
- Path-based `NFSClient`: list, stat, read (whole or ranged), write, create, mkdir, remove (recursive), rename, chmod, readlink
- Writes go out as unstable WRITEs plus one COMMIT, and are redone when the server's write verifier shows it restarted in between
- File handles are cached and looked up again when the server reports them stale
- `NFS3Client` exposes the individual procedures for anything `NFSClient` does not cover
- macOS, iOS, tvOS, watchOS, visionOS and Linux

NFSv4 is not supported.

## Installation

```swift
.package(url: "https://github.com/lollipopkit/nfs.swift.git", from: "0.1.0")
```

```swift
.product(name: "NFS", package: "nfs.swift")
```

## Usage

```swift
import NFS

let client = NFSClient(configuration: .init(
    host: "nas.local",
    exportPath: "/srv/nfs",
    credential: RPCCredential(uid: 1000, gid: 1000)
))
try await client.connect()

for item in try await client.contentsOfDirectory(at: "/") {
    print(item.name, item.attributes.type, item.attributes.size)
}

try await client.write(Data("hello".utf8), to: "/hello.txt", mode: .guarded)
let data = try await client.read("/hello.txt")
try await client.write(try FileUploadSource(url: localFile), to: "/big.bin")
try await client.moveItem(at: "/hello.txt", to: "/docs/hello.txt")
try await client.removeItem(at: "/docs")

await client.disconnect()
```

Paths are relative to the export's root. Errors are `NFSClientError`, or `RPCError` for transport failures.

## Server requirements

- NFSv3 over TCP, with the MOUNT service registered with the portmapper (port 111).
- Requests come from a port above 1024 unless the process can bind a lower one, which normally takes root. Linux servers refuse those unless the export has the `insecure` option:

  ```
  /srv/nfs  *(rw,sync,insecure,no_subtree_check)
  ```

  `NFSClientError.mayNeedInsecureExport` tells when a refusal looks like this.
- The server authorizes by the `uid` and `gid` in `RPCCredential`, which default to the current process's.

## Testing

```bash
swift test
```

The server tests run when `NFS_TEST_HOST` and `NFS_TEST_EXPORT` point at a writable export; `NFS_TEST_UID` and `NFS_TEST_GID` set the ids to use.

## License

Apache License 2.0. See [LICENSE](LICENSE).
