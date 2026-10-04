import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// The `AUTH_SYS` credential (RFC 5531 appendix A) every call carries: NFSv3 servers
/// authorize by these ids, not by a login.
public struct RPCCredential: Sendable, Equatable {
    public var uid: UInt32
    public var gid: UInt32
    /// The client name in the credential. Servers log it at most; the default keeps the
    /// machine's real host name to itself.
    public var machineName: String

    public init(uid: UInt32, gid: UInt32, machineName: String = "nfs.swift") {
        self.uid = uid
        self.gid = gid
        self.machineName = machineName
    }

    /// The ids of the process, as `mount_nfs` and the Linux kernel client send them.
    public static var currentProcess: RPCCredential {
        RPCCredential(uid: getuid(), gid: getgid())
    }

    fileprivate func encodeAuthSys(into xdr: inout XDREncoder) {
        var body = XDREncoder()
        body.encode(UInt32(0))   // stamp
        body.encode(machineName)
        body.encode(uid)
        body.encode(gid)
        body.encode(UInt32(1))   // supplementary gids
        body.encode(gid)
        xdr.encode(UInt32(1))    // AUTH_SYS
        xdr.encodeOpaque(body.bytes)
    }
}

public enum RPCError: Error, Equatable, LocalizedError {
    case connectionClosed
    case timedOut
    case programUnavailable
    case programMismatch(low: UInt32, high: UInt32)
    case procedureUnavailable
    case garbageArguments
    case systemError
    case rpcVersionMismatch
    /// The server rejected the credential; `authStat` is RFC 5531's `auth_stat`.
    case authenticationRejected(authStat: UInt32)
    case malformedReply
    case recordTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .connectionClosed: return "The connection to the server was closed"
        case .timedOut: return "The server did not answer in time"
        case .programUnavailable: return "The server does not offer this RPC service"
        case .programMismatch(let low, let high):
            return "The server only supports versions \(low)–\(high) of this RPC service"
        case .procedureUnavailable: return "The server does not support this RPC procedure"
        case .garbageArguments: return "The server could not decode the request"
        case .systemError: return "The server failed to process the request"
        case .rpcVersionMismatch: return "The server does not speak ONC RPC version 2"
        case .authenticationRejected(let stat): return "The server rejected the credentials (auth_stat \(stat))"
        case .malformedReply: return "The server sent a malformed reply"
        case .recordTooLarge(let size): return "The server sent a reply of \(size) bytes, more than allowed"
        }
    }
}

/// One ONC RPC (RFC 5531) client over TCP. Calls are matched to replies by XID, so any
/// number can be in flight at once on the one connection.
///
/// A connection the server closed — Linux closes idle NFS connections after a few
/// minutes — is reopened by the next call.
actor RPCClient {
    static let callTimeout: TimeAmount = .seconds(30)

    private let host: String
    private let port: Int
    private let credential: RPCCredential
    private var channel: Channel?
    private var connecting: Task<Channel, Error>?
    private var nextXID = UInt32.random(in: .min ... .max)

    init(host: String, port: Int, credential: RPCCredential) {
        self.host = host
        self.port = port
        self.credential = credential
    }

    /// Calls `procedure` and returns a decoder positioned at its results.
    ///
    /// `idempotent` calls are sent once more on a fresh connection when the first one
    /// closes before answering; repeating anything else could report a failure for work
    /// the first attempt did.
    func call(
        program: UInt32,
        version: UInt32,
        procedure: UInt32,
        arguments: [UInt8] = [],
        idempotent: Bool
    ) async throws -> XDRDecoder {
        do {
            return try await send(program: program, version: version, procedure: procedure, arguments: arguments)
        } catch RPCError.connectionClosed where idempotent {
            return try await send(program: program, version: version, procedure: procedure, arguments: arguments)
        }
    }

    func close() async {
        connecting?.cancel()
        connecting = nil
        let channel = self.channel
        self.channel = nil
        try? await channel?.close()
    }

    // MARK: - Private

    private func send(program: UInt32, version: UInt32, procedure: UInt32, arguments: [UInt8]) async throws -> XDRDecoder {
        let channel = try await activeChannel()
        let handler = try await channel.pipeline.handler(type: RPCReplyHandler.self).get()

        let xid = nextXID
        nextXID &+= 1
        var xdr = XDREncoder()
        xdr.encode(xid)
        xdr.encode(UInt32(0))        // CALL
        xdr.encode(UInt32(2))        // RPC version
        xdr.encode(program)
        xdr.encode(version)
        xdr.encode(procedure)
        credential.encodeAuthSys(into: &xdr)
        xdr.encode(UInt32(0))        // verifier: AUTH_NONE
        xdr.encode(UInt32(0))
        let message = xdr.bytes + arguments

        var buffer = channel.allocator.buffer(capacity: message.count + 4)
        buffer.writeInteger(UInt32(0x8000_0000) | UInt32(message.count))  // one, last, fragment
        buffer.writeBytes(message)

        let reply = handler.expectReply(xid: xid, on: channel.eventLoop, timeout: Self.callTimeout)
        channel.writeAndFlush(buffer, promise: nil)
        return try Self.acceptedResults(of: try await reply.get())
    }

    private func activeChannel() async throws -> Channel {
        if let channel, channel.isActive { return channel }
        if let connecting { return try await connecting.value }

        let host = self.host
        let port = self.port
        let task = Task {
            try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(.seconds(15))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(RPCRecordDecoder()))
                        try channel.pipeline.syncOperations.addHandler(RPCReplyHandler())
                    }
                }
                .connect(host: host, port: port)
                .get()
        }
        connecting = task
        defer { connecting = nil }
        let channel = try await task.value
        self.channel = channel
        return channel
    }

    /// Skips the reply header, or throws what it reports.
    static func acceptedResults(of record: [UInt8]) throws -> XDRDecoder {
        var reply = XDRDecoder(record)
        _ = try reply.decodeUInt32()                       // xid, already matched
        guard try reply.decodeUInt32() == 1 else { throw RPCError.malformedReply }  // REPLY
        switch try reply.decodeUInt32() {
        case 0:                                            // MSG_ACCEPTED
            _ = try reply.decodeUInt32()                   // verifier flavor
            _ = try reply.decodeOpaque(maxLength: 400)
            switch try reply.decodeUInt32() {
            case 0: return reply
            case 1: throw RPCError.programUnavailable
            case 2: throw RPCError.programMismatch(low: try reply.decodeUInt32(), high: try reply.decodeUInt32())
            case 3: throw RPCError.procedureUnavailable
            case 4: throw RPCError.garbageArguments
            default: throw RPCError.systemError
            }
        case 1:                                            // MSG_DENIED
            switch try reply.decodeUInt32() {
            case 0: throw RPCError.rpcVersionMismatch
            case 1: throw RPCError.authenticationRejected(authStat: try reply.decodeUInt32())
            default: throw RPCError.malformedReply
            }
        default:
            throw RPCError.malformedReply
        }
    }
}

/// Reassembles record-marked fragments (RFC 5531 section 11) into whole replies.
final class RPCRecordDecoder: ByteToMessageDecoder {
    typealias InboundOut = [UInt8]

    /// Large enough for a READ or READDIRPLUS reply of the biggest transfer size servers
    /// offer; anything beyond is refused rather than buffered.
    static let maxRecordSize = 4 * 1024 * 1024 + 64 * 1024

    private var record: [UInt8] = []

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let header = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) else {
            return .needMoreData
        }
        let length = Int(header & 0x7fff_ffff)
        guard record.count + length <= Self.maxRecordSize else {
            throw RPCError.recordTooLarge(record.count + length)
        }
        guard buffer.readableBytes >= 4 + length else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 4)
        record.append(contentsOf: buffer.readBytes(length: length) ?? [])
        if header & 0x8000_0000 != 0 {
            context.fireChannelRead(wrapInboundOut(record))
            record = []
        }
        return .continue
    }
}

/// Hands each reply to the call with its XID.
final class RPCReplyHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = [UInt8]

    private struct State {
        var pending: [UInt32: EventLoopPromise<[UInt8]>] = [:]
        var isClosed = false
    }

    // One lock for both, so a call cannot register between the connection closing and
    // the waiting calls being failed, and then wait out its whole timeout.
    private let state = NIOLockedValueBox(State())

    func expectReply(xid: UInt32, on eventLoop: EventLoop, timeout: TimeAmount) -> EventLoopFuture<[UInt8]> {
        let promise = eventLoop.makePromise(of: [UInt8].self)
        let registered = state.withLockedValue { state in
            guard !state.isClosed else { return false }
            state.pending[xid] = promise
            return true
        }
        guard registered else {
            promise.fail(RPCError.connectionClosed)
            return promise.futureResult
        }
        let timeoutTask = eventLoop.scheduleTask(in: timeout) { [state] in
            state.withLockedValue { $0.pending.removeValue(forKey: xid) }?.fail(RPCError.timedOut)
        }
        promise.futureResult.whenComplete { _ in timeoutTask.cancel() }
        return promise.futureResult
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let record = unwrapInboundIn(data)
        guard record.count >= 4 else { return }
        let xid = UInt32(record[0]) << 24 | UInt32(record[1]) << 16 | UInt32(record[2]) << 8 | UInt32(record[3])
        // A reply nobody waits for any more (it timed out) is dropped.
        state.withLockedValue { $0.pending.removeValue(forKey: xid) }?.succeed(record)
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(RPCError.connectionClosed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // A reset or similar transport failure is a closed connection to the caller, which
        // may then retry on a new one.
        failAll(error as? RPCError ?? .connectionClosed)
        context.close(promise: nil)
    }

    private func failAll(_ error: RPCError) {
        let waiting = state.withLockedValue { state in
            state.isClosed = true
            defer { state.pending.removeAll() }
            return Array(state.pending.values)
        }
        waiting.forEach { $0.fail(error) }
    }
}
