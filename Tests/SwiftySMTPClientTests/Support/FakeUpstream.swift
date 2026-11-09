import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
@testable import SwiftySMTPClient

/// Scripted SMTP server that plays the remote server in client tests.
struct FakeUpstreamBehavior: Sendable {
    enum Silence: Sendable { case none, greeting, afterEHLO, endOfData }

    var greeting = SMTPReply(220, "fake ESMTP")
    /// Closes the connection right after the greeting (e.g. a server at its connection limit replying 421).
    var closeAfterGreeting = false
    var capabilities: [String] = ["STARTTLS", "AUTH PLAIN LOGIN", "8BITMIME", "SIZE 1000000"]
    var authReply = SMTPReply(235, "2.7.0 ok")
    var rejectedRecipients: [String: SMTPReply] = [:]
    var dataEndReply = SMTPReply(250, "2.0.0 queued")
    var silence: Silence = .none
    var closeAfterEndOfData = false
    var implicitTLS = false
    var tlsCertificate = "localhost"
    /// Stops reading from the socket after replying 354 (the client's DATA write stalls) and resumes after this delay.
    var stopReadingAfterData: TimeAmount?
}

final class FakeUpstreamRecorder: Sendable {
    private let state = NIOLockedValueBox<(commands: [String], messages: [Data], connections: Int, closed: Int)>(([], [], 0, 0))
    var commands: [String] { state.withLockedValue { $0.commands } }
    var messages: [Data] { state.withLockedValue { $0.messages } }
    var closedConnections: Int { state.withLockedValue { $0.closed } }
    func record(command: String) { state.withLockedValue { $0.commands.append(command) } }
    func record(message: Data) { state.withLockedValue { $0.messages.append(message) } }
    func connectionClosed() { state.withLockedValue { $0.closed += 1 } }
}

final class FakeUpstream: Sendable {
    let port: Int
    let recorder: FakeUpstreamRecorder
    private let channel: any Channel

    private init(port: Int, recorder: FakeUpstreamRecorder, channel: any Channel) {
        self.port = port
        self.recorder = recorder
        self.channel = channel
    }

    static func start(_ behavior: FakeUpstreamBehavior = FakeUpstreamBehavior()) async throws -> FakeUpstream {
        let recorder = FakeUpstreamRecorder()
        let tls = try TestFixtures.serverContext(behavior.tlsCertificate)
        var bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        if behavior.stopReadingAfterData != nil {
            // Small receive buffer so the client's write backs up quickly once we stop reading.
            bootstrap = bootstrap.childChannelOption(.socketOption(.so_rcvbuf), value: 4096)
        }
        let channel = try await bootstrap
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    if behavior.implicitTLS {
                        try sync.addHandler(NIOSSLServerHandler(context: tls))
                    }
                    let framer = SMTPLineFramingHandler()
                    try sync.addHandler(framer)
                    try sync.addHandler(FakeUpstreamHandler(behavior: behavior, recorder: recorder, framer: framer, tls: tls))
                    channel.closeFuture.whenComplete { _ in recorder.connectionClosed() }
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return FakeUpstream(port: channel.localAddress!.port!, recorder: recorder, channel: channel)
    }

    func stop() async {
        try? await channel.close()
    }

    func client(_ encryption: SMTPEncryption, credentials: SMTPCredentials? = nil, replyTimeout: TimeAmount = .seconds(5), host: String = "localhost") throws -> SMTPClient {
        try SMTPClient(configuration: SMTPClientConfiguration(
            host: host, port: port, encryption: encryption, credentials: credentials,
            connectTimeout: .seconds(5), replyTimeout: replyTimeout, trustRoots: try TestFixtures.trustRoots()
        ))
    }
}

private final class FakeUpstreamHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Mode { case command, authLoginUser, authLoginPassword, data }

    private let behavior: FakeUpstreamBehavior
    private let recorder: FakeUpstreamRecorder
    private let framer: SMTPLineFramingHandler
    private let tls: NIOSSLContext
    private var mode = Mode.command
    private var tlsActive: Bool
    private var data: [UInt8] = []

    init(behavior: FakeUpstreamBehavior, recorder: FakeUpstreamRecorder, framer: SMTPLineFramingHandler, tls: NIOSSLContext) {
        self.behavior = behavior
        self.recorder = recorder
        self.framer = framer
        self.tls = tls
        self.tlsActive = behavior.implicitTLS
    }

    func channelActive(context: ChannelHandlerContext) {
        if behavior.silence != .greeting { send(behavior.greeting, context) }
        if behavior.closeAfterGreeting { context.close(promise: nil) }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data buffer: NIOAny) {
        var buffer = Self.unwrapInboundIn(buffer)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        let line = String(decoding: bytes, as: UTF8.self)
        switch mode {
        case .data:
            if line == "." {
                recorder.record(message: Data(data))
                data = []
                mode = .command
                if behavior.closeAfterEndOfData { context.close(promise: nil); return }
                if behavior.silence == .endOfData { return }
                send(behavior.dataEndReply, context)
            } else {
                self.data += (bytes.first == UInt8(ascii: ".") ? Array(bytes.dropFirst()) : bytes) + [13, 10]
            }
            return
        case .authLoginUser:
            recorder.record(command: "<login-user>")
            mode = .authLoginPassword
            send(SMTPReply(334, "UGFzc3dvcmQ6"), context)
            return
        case .authLoginPassword:
            recorder.record(command: "<login-password>")
            mode = .command
            send(behavior.authReply, context)
            return
        case .command:
            break
        }
        recorder.record(command: line)
        let verb = line.split(separator: " ").first.map { $0.uppercased() } ?? ""
        switch verb {
        case "EHLO":
            if behavior.silence == .afterEHLO { return }
            let caps = behavior.capabilities.filter { !(tlsActive && $0 == "STARTTLS") }
            send(SMTPReply(code: 250, lines: ["fake"] + caps), context)
        case "STARTTLS":
            send(SMTPReply(220, "2.0.0 go ahead"), context)
            framer.discardBufferedInput()
            try? context.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls), position: .first)
            tlsActive = true
        case "AUTH":
            if line.uppercased().hasPrefix("AUTH LOGIN") {
                mode = .authLoginUser
                send(SMTPReply(334, "VXNlcm5hbWU6"), context)
            } else {
                send(behavior.authReply, context)
            }
        case "MAIL":
            send(SMTPReply(250, "2.1.0 ok"), context)
        case "RCPT":
            let address = line.split(separator: "<").last.map { String($0.dropLast()) } ?? ""
            send(behavior.rejectedRecipients[address] ?? SMTPReply(250, "2.1.5 ok"), context)
        case "DATA":
            mode = .data
            send(SMTPReply(354, "go"), context)
            if let resumeAfter = behavior.stopReadingAfterData {
                framer.pauseDelivery()
                context.channel.setOption(.autoRead, value: false).whenComplete { _ in }
                let framer = self.framer
                context.eventLoop.assumeIsolated().scheduleTask(in: resumeAfter) {
                    context.channel.setOption(.autoRead, value: true).whenComplete { _ in }
                    framer.resumeDelivery()
                }
            }
        case "QUIT":
            send(SMTPReply(221, "bye"), context)
            context.close(promise: nil)
        default:
            send(SMTPReply(502, "unknown"), context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    private func send(_ reply: SMTPReply, _ context: ChannelHandlerContext) {
        context.writeAndFlush(Self.wrapOutboundOut(context.channel.allocator.buffer(string: reply.encoded())), promise: nil)
    }
}
