public import Foundation
public import NIOCore
import NIOPosix
public import NIOSSL
import NIOTLS

/// Failures reported by the client pipeline, mapped to `SMTPClientError` (with the stage) by the connection.
enum SMTPClientHandlerError: Error {
    case timeout
    case closed
    case malformed(String)
    case tls(String)
}

/// Event-loop-confined state of one client connection: turns lines into replies and hands them to the
/// single waiting reader. Never touched off the event loop (accessed through `NIOLoopBound`).
final class SMTPClientHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let framer: SMTPLineFramingHandler
    private let eventLoop: any EventLoop
    private var context: ChannelHandlerContext?
    private var parser = SMTPReplyParser()
    private var replies = CircularBuffer<Result<SMTPReply, SMTPClientHandlerError>>()
    private var waiter: (promise: EventLoopPromise<SMTPReply>, timeout: Scheduled<Void>)?
    private var terminalError: SMTPClientHandlerError?
    private var firstError: (any Error)?
    /// Outcome of the current TLS handshake; `nil` while it is running (or none was started).
    private var handshakeResult: Result<Void, SMTPClientHandlerError>?
    /// Promises are created lazily: NIO may run the channel initializer for several connection attempts
    /// (e.g. ::1 and 127.0.0.1 for "localhost"); an eagerly created, never-completed promise would trip
    /// NIO's leak check when the losing attempt is discarded.
    private var handshakeWaiter: (promise: EventLoopPromise<Void>, timeout: Scheduled<Void>?)?

    init(framer: SMTPLineFramingHandler, eventLoop: any EventLoop) {
        self.framer = framer
        self.eventLoop = eventLoop
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        fail(.closed)
        completeHandshake(.failure(.closed))
        self.context = nil
    }

    /// Completes when the running (or already finished) TLS handshake is done.
    func handshake(timeout: TimeAmount) -> EventLoopFuture<Void> {
        if let handshakeResult {
            switch handshakeResult {
            case .success: return eventLoop.makeSucceededVoidFuture()
            case .failure(let error): return eventLoop.makeFailedFuture(error)
            }
        }
        let promise = eventLoop.makePromise(of: Void.self)
        let timeoutTask = eventLoop.assumeIsolated().scheduleTask(in: timeout) {
            self.completeHandshake(.failure(.timeout))
            self.context?.close(promise: nil)
        }
        handshakeWaiter = (promise, timeoutTask)
        return promise.futureResult
    }

    func nextReply(timeout: TimeAmount) -> EventLoopFuture<SMTPReply> {
        if let next = replies.popFirst() {
            switch next {
            case .success(let reply): return eventLoop.makeSucceededFuture(reply)
            case .failure(let error): return eventLoop.makeFailedFuture(error)
            }
        }
        if let terminalError {
            return eventLoop.makeFailedFuture(terminalError)
        }
        let promise = eventLoop.makePromise(of: SMTPReply.self)
        let timeoutTask = eventLoop.assumeIsolated().scheduleTask(in: timeout) {
            guard let waiter = self.waiter, waiter.promise.futureResult === promise.futureResult else { return }
            self.waiter = nil
            promise.fail(SMTPClientHandlerError.timeout)
            self.context?.close(promise: nil)   // the dialogue is out of sync after a timeout
        }
        waiter = (promise, timeoutTask)
        return promise.futureResult
    }

    func abort() {
        fail(.closed)
        context?.close(promise: nil)
    }

    func upgradeToTLS(sslContext: NIOSSLContext, serverHostname: String, timeout: TimeAmount) -> EventLoopFuture<Void> {
        guard let context else { return eventLoop.makeFailedFuture(terminalError ?? .closed) }
        framer.discardBufferedInput()
        replies.removeAll()
        handshakeResult = nil
        do {
            let handler = try NIOSSLClientHandler(context: sslContext, serverHostname: serverHostname)
            try context.pipeline.syncOperations.addHandler(handler, position: .first)
        } catch {
            return eventLoop.makeFailedFuture(SMTPClientHandlerError.tls("\(error)"))
        }
        return handshake(timeout: timeout)
    }

    // MARK: ChannelInboundHandler

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = Self.unwrapInboundIn(data)
        let line = buffer.readString(length: buffer.readableBytes) ?? ""
        do {
            if let reply = try parser.consume(line: line) {
                deliver(.success(reply))
            }
        } catch {
            deliver(.failure(.malformed(line)))
            context.close(promise: nil)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent, case .handshakeCompleted = tlsEvent {
            completeHandshake(.success(()))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if firstError == nil { firstError = error }
        if error is SMTPLineTooLongError {
            deliver(.failure(.malformed("Reply line too long")))
        }
        completeHandshake(.failure(.tls("\(error)")))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let firstError, !(firstError is SMTPLineTooLongError) {
            let tlsError = SMTPClientHandlerError.tls("\(firstError)")
            completeHandshake(.failure(tlsError))
            fail(tlsError)
        } else {
            completeHandshake(.failure(.closed))
            fail(.closed)
        }
        context.fireChannelInactive()
    }

    // MARK: Helpers

    private func deliver(_ result: Result<SMTPReply, SMTPClientHandlerError>) {
        if let waiter {
            self.waiter = nil
            waiter.timeout.cancel()
            waiter.promise.completeWith(result.mapError { $0 as any Error })
        } else {
            replies.append(result)
        }
    }

    private func fail(_ error: SMTPClientHandlerError) {
        if terminalError == nil { terminalError = error }
        if let waiter {
            self.waiter = nil
            waiter.timeout.cancel()
            waiter.promise.fail(error)
        }
    }

    private func completeHandshake(_ result: Result<Void, SMTPClientHandlerError>) {
        guard handshakeResult == nil else { return }
        handshakeResult = result
        if let waiter = handshakeWaiter {
            handshakeWaiter = nil
            waiter.timeout?.cancel()
            waiter.promise.completeWith(result.mapError { $0 as any Error })
        }
    }
}

/// Low-level async access to one SMTP connection: you drive the dialogue yourself, command by command.
///
/// `SMTPClient` is built on top of this. Use it directly for tests against SMTP servers or for commands the
/// high-level client does not send. Only one command may be in flight at a time.
public final class SMTPClientConnection: Sendable {
    let channel: any Channel
    private let handler: NIOLoopBound<SMTPClientHandler>

    private init(channel: any Channel, handler: NIOLoopBound<SMTPClientHandler>) {
        self.channel = channel
        self.handler = handler
    }

    /// Opens a TCP connection (and, with `implicitTLS`, completes the TLS handshake). Does not read the greeting.
    ///
    /// - Parameters:
    ///   - implicitTLS: TLS context for SMTPS (port 465); `nil` for a plaintext connection.
    ///   - eventLoopGroup: Defaults to `MultiThreadedEventLoopGroup.singleton`.
    public static func connect(host: String, port: Int, implicitTLS: NIOSSLContext? = nil, connectTimeout: TimeAmount = .seconds(30),
                               eventLoopGroup: (any EventLoopGroup)? = nil) async throws(SMTPClientError) -> SMTPClientConnection {
        let bootstrap = ClientBootstrap(group: eventLoopGroup ?? MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(connectTimeout)
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
        let channel: any Channel
        let handler: NIOLoopBound<SMTPClientHandler>
        do {
            // The handler is captured while the pipeline is built, before the first read: a server that greets and
            // closes at once (e.g. 421) may already have torn the pipeline down by the time `connect` returns.
            (channel, handler) = try await bootstrap.connect(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    if let implicitTLS {
                        try sync.addHandler(NIOSSLClientHandler(context: implicitTLS, serverHostname: host))
                    }
                    let framer = SMTPLineFramingHandler()
                    let handler = SMTPClientHandler(framer: framer, eventLoop: channel.eventLoop)
                    try sync.addHandler(framer)
                    try sync.addHandler(handler)
                    return (channel, NIOLoopBound(handler, eventLoop: channel.eventLoop))
                }
            }
        } catch {
            throw .connectFailed("\(error)")
        }
        let connection = SMTPClientConnection(channel: channel, handler: handler)
        if implicitTLS != nil {
            do throws(SMTPClientError) {
                try await connection.awaitHandshake(timeout: connectTimeout)
            } catch {
                try? await channel.close()
                throw error
            }
        }
        return connection
    }

    /// Waits for the next (possibly multi-line) reply. `stage` only labels errors.
    /// A timeout closes the connection, because the dialogue is out of sync afterwards.
    public func readReply(stage: SMTPClientStage, timeout: TimeAmount) async throws(SMTPClientError) -> SMTPReply {
        let handler = self.handler
        let channel = self.channel
        let future = channel.eventLoop.flatSubmit { handler.value.nextReply(timeout: timeout) }
        do {
            return try await withTaskCancellationHandler {
                try await future.get()
            } onCancel: {
                channel.eventLoop.execute { handler.value.abort() }
            }
        } catch {
            throw Self.map(error, stage: stage)
        }
    }

    /// Sends one command line (`CRLF` is appended) and returns the reply.
    /// A line containing CR or LF throws `.invalidCommand` without sending anything, so one call is always one command.
    public func command(_ line: String, stage: SMTPClientStage, timeout: TimeAmount) async throws(SMTPClientError) -> SMTPReply {
        guard !line.utf8.contains(where: { $0 == UInt8(ascii: "\r") || $0 == UInt8(ascii: "\n") }) else {
            throw .invalidCommand(stage)
        }
        try await write(Data((line + "\r\n").utf8), stage: stage)
        return try await readReply(stage: stage, timeout: timeout)
    }

    /// Sends the message body after a `354` reply to `DATA`, with dot-stuffing and the terminating `CRLF.CRLF`.
    /// Returns the final reply.
    public func sendData(_ message: Data, timeout: TimeAmount) async throws(SMTPClientError) -> SMTPReply {
        try await write(Self.dotStuffed(message), stage: .endOfData)
        return try await readReply(stage: .endOfData, timeout: timeout)
    }

    /// Upgrades the connection to TLS after the server accepted `STARTTLS` (`220`). Input the server sent before
    /// the handshake is discarded (protection against STARTTLS command injection, CVE-2011-0411).
    public func startTLS(context: NIOSSLContext, serverHostname: String, timeout: TimeAmount) async throws(SMTPClientError) {
        let handler = self.handler
        let future = channel.eventLoop.flatSubmit {
            handler.value.upgradeToTLS(sslContext: context, serverHostname: serverHostname, timeout: timeout)
        }
        do {
            try await future.get()
        } catch {
            throw Self.map(error, stage: .startTLS, tls: true)
        }
    }

    /// Closes the connection without sending `QUIT`.
    public func close() async {
        try? await channel.close()
    }

    private func awaitHandshake(timeout: TimeAmount) async throws(SMTPClientError) {
        let handler = self.handler
        do {
            try await channel.eventLoop.flatSubmit { handler.value.handshake(timeout: timeout) }.get()
        } catch {
            throw Self.map(error, stage: .connect, tls: true)
        }
    }

    private func write(_ data: Data, stage: SMTPClientStage) async throws(SMTPClientError) {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let channel = self.channel
        do {
            // A write to a peer that stopped reading never completes on its own; closing the channel fails it, so
            // the overall delivery timeout can end the attempt.
            try await withTaskCancellationHandler {
                try await channel.writeAndFlush(buffer)
            } onCancel: {
                channel.close(promise: nil)
            }
        } catch {
            throw .connectionClosed(stage)
        }
    }

    static func dotStuffed(_ message: Data) -> Data {
        var result = Data()
        result.reserveCapacity(message.count + message.count / 50 + 5)
        var atLineStart = true
        for byte in message {
            if atLineStart && byte == UInt8(ascii: ".") {
                result.append(UInt8(ascii: "."))
            }
            result.append(byte)
            atLineStart = byte == 10
        }
        if !result.isEmpty && !result.hasSuffix(Data([13, 10])) {
            result.append(contentsOf: [13, 10])
        }
        result.append(contentsOf: Array(".\r\n".utf8))
        return result
    }

    private static func map(_ error: any Error, stage: SMTPClientStage, tls: Bool = false) -> SMTPClientError {
        switch error {
        case let error as SMTPClientError: return error
        case SMTPClientHandlerError.timeout: return .timeout(stage)
        case SMTPClientHandlerError.closed: return tls ? .tlsFailed("Connection closed during TLS handshake") : .connectionClosed(stage)
        case SMTPClientHandlerError.malformed(let line): return .malformedReply(line)
        case SMTPClientHandlerError.tls(let description): return .tlsFailed(description)
        case is CancellationError: return .connectionClosed(stage)
        default: return tls ? .tlsFailed("\(error)") : .connectionClosed(stage)
        }
    }
}

private extension Data {
    func hasSuffix(_ suffix: Data) -> Bool {
        count >= suffix.count && self[(endIndex - suffix.count)...] == suffix
    }
}
