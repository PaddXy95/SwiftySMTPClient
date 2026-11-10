public import Foundation
public import NIOCore
import NIOPosix
import NIOSSL

/// Sends finished messages to one SMTP server. Every `send` opens its own connection (no pooling).
///
/// The value is cheap to copy and safe to share between tasks.
public struct SMTPClient: Sendable {
    public let configuration: SMTPClientConfiguration
    private let tlsContext: NIOSSLContext
    private let eventLoopGroup: any EventLoopGroup

    /// - Parameter eventLoopGroup: Defaults to `MultiThreadedEventLoopGroup.singleton`.
    /// - Throws: If the TLS context cannot be created from `configuration.trustRoots`.
    public init(configuration: SMTPClientConfiguration, eventLoopGroup: (any EventLoopGroup)? = nil) throws {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = configuration.trustRoots
        tls.certificateVerification = .fullVerification
        tls.minimumTLSVersion = .tlsv12
        self.tlsContext = try NIOSSLContext(configuration: tls)
        self.configuration = configuration
        self.eventLoopGroup = eventLoopGroup ?? MultiThreadedEventLoopGroup.singleton
    }

    /// Sends one message.
    ///
    /// - Parameters:
    ///   - sender: Envelope sender (`MAIL FROM`), a bare address without angle brackets. Empty sends the null
    ///     reverse-path `<>`.
    ///   - recipients: Envelope recipients (`RCPT TO`). The first rejected recipient aborts the transaction.
    ///   - message: The complete RFC 5322 message (headers and body) with CRLF line endings.
    ///     Dot-stuffing and the terminating `CRLF.CRLF` are added by the client.
    /// - Throws: `SMTPClientError`. Cancelling the task closes the connection and ends the call.
    ///   `.invalidAddress` is thrown before connecting if an address contains anything other than printable ASCII,
    ///   or a space, `<` or `>`, so untrusted addresses cannot inject SMTP commands.
    public func send(from sender: String, recipients: [String], message: Data) async throws(SMTPClientError) {
        for address in [sender] + recipients where !Self.isValidAddress(address) {
            throw .invalidAddress(address)
        }
        let config = configuration
        let connection = try await SMTPClientConnection.connect(
            host: config.host, port: config.port,
            implicitTLS: config.encryption == .ssl ? tlsContext : nil,
            connectTimeout: config.connectTimeout, eventLoopGroup: eventLoopGroup
        )
        do throws(SMTPClientError) {
            try await dialogue(connection, sender: sender, recipients: recipients, message: message)
            _ = try? await connection.command("QUIT", stage: .data, timeout: .seconds(5))
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    private func dialogue(_ connection: SMTPClientConnection, sender: String, recipients: [String], message: Data) async throws(SMTPClientError) {
        let config = configuration
        let timeout = config.replyTimeout
        try expect(try await connection.readReply(stage: .greeting, timeout: timeout), 220, stage: .greeting)

        var capabilities = try await ehlo(connection)
        if config.encryption == .starttls {
            guard capabilities.startTLS else { throw .startTLSNotOffered }
            try expect(try await connection.command("STARTTLS", stage: .startTLS, timeout: timeout), 220, stage: .startTLS)
            try await connection.startTLS(context: tlsContext, serverHostname: config.host, timeout: timeout)
            capabilities = try await ehlo(connection)
        }

        if let credentials = config.credentials {
            try await authenticate(connection, credentials: credentials, capabilities: capabilities)
        }

        var mailFrom = "MAIL FROM:<\(sender)>"
        if message.contains(where: { $0 > 127 }) {
            guard capabilities.eightBitMIME else { throw .eightBitNotSupported }
            mailFrom += " BODY=8BITMIME"
        }
        if let maxSize = capabilities.maxSize {
            guard message.count <= maxSize else { throw .messageTooLarge(limit: maxSize) }
            mailFrom += " SIZE=\(message.count)"
        }
        try expect(try await connection.command(mailFrom, stage: .mailFrom, timeout: timeout), 250, stage: .mailFrom)
        for recipient in recipients {
            let reply = try await connection.command("RCPT TO:<\(recipient)>", stage: .rcptTo, timeout: timeout)
            guard reply.code == 250 || reply.code == 251 else { throw .rejected(stage: .rcptTo, reply: reply) }
        }
        try expect(try await connection.command("DATA", stage: .data, timeout: timeout), 354, stage: .data)
        try expect(try await connection.sendData(message, timeout: timeout), 250, stage: .endOfData)
    }

    private func ehlo(_ connection: SMTPClientConnection) async throws(SMTPClientError) -> SMTPCapabilities {
        let reply = try await connection.command("EHLO \(configuration.clientName)", stage: .ehlo, timeout: configuration.replyTimeout)
        try expect(reply, 250, stage: .ehlo)
        return SMTPCapabilities.parse(reply)
    }

    private func authenticate(_ connection: SMTPClientConnection, credentials: SMTPCredentials, capabilities: SMTPCapabilities) async throws(SMTPClientError) {
        let timeout = configuration.replyTimeout
        func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
        if capabilities.authMechanisms.contains("PLAIN") {
            let token = base64("\u{0}\(credentials.username)\u{0}\(credentials.password)")
            try expect(try await connection.command("AUTH PLAIN \(token)", stage: .auth, timeout: timeout), 235, stage: .auth)
        } else if capabilities.authMechanisms.contains("LOGIN") {
            try expect(try await connection.command("AUTH LOGIN", stage: .auth, timeout: timeout), 334, stage: .auth)
            try expect(try await connection.command(base64(credentials.username), stage: .auth, timeout: timeout), 334, stage: .auth)
            try expect(try await connection.command(base64(credentials.password), stage: .auth, timeout: timeout), 235, stage: .auth)
        } else {
            throw .authNotOffered
        }
    }

    /// Printable ASCII without space, `<` and `>`: anything else could end the command line or the `<…>` path.
    static func isValidAddress(_ address: String) -> Bool {
        address.utf8.allSatisfy { (0x21...0x7E).contains($0) && $0 != UInt8(ascii: "<") && $0 != UInt8(ascii: ">") }
    }

    private func expect(_ reply: SMTPReply, _ code: Int, stage: SMTPClientStage) throws(SMTPClientError) {
        guard reply.code == code else { throw .rejected(stage: stage, reply: reply) }
    }
}
