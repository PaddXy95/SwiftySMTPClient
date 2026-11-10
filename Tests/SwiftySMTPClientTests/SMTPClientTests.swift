import Foundation
import NIOCore
import Testing
@testable import SwiftySMTPClient

@Suite(.serialized) struct SMTPClientTests {
    static let message = Data("Subject: x\r\n\r\nHello\r\n.foo\r\n.\r\n".utf8)
    static let credentials = SMTPCredentials(username: "noreply@example.com", password: "token")

    @Test func plainWithoutAuthentication() async throws {
        let upstream = try await FakeUpstream.start()
        defer { Task { await upstream.stop() } }
        try await upstream.client(.plain).send(from: "noreply@x.de", recipients: ["a@b.de", "c@d.de"], message: Self.message)
        #expect(upstream.recorder.commands == ["EHLO [127.0.0.1]", "MAIL FROM:<noreply@x.de> SIZE=\(Self.message.count)", "RCPT TO:<a@b.de>", "RCPT TO:<c@d.de>", "DATA", "QUIT"])
        #expect(upstream.recorder.messages == [Self.message])
    }

    @Test func startTLSWithAuthPlain() async throws {
        let upstream = try await FakeUpstream.start()
        defer { Task { await upstream.stop() } }
        try await upstream.client(.starttls, credentials: Self.credentials).send(from: "noreply@x.de", recipients: ["a@b.de"], message: Self.message)
        let commands = upstream.recorder.commands
        #expect(commands.prefix(4) == ["EHLO [127.0.0.1]", "STARTTLS", "EHLO [127.0.0.1]", "AUTH PLAIN \(Data("\u{0}noreply@example.com\u{0}token".utf8).base64EncodedString())"])
        #expect(upstream.recorder.messages.count == 1)
    }

    @Test func authLoginFallback() async throws {
        var behavior = FakeUpstreamBehavior()
        behavior.capabilities = ["STARTTLS", "AUTH LOGIN"]
        let upstream = try await FakeUpstream.start(behavior)
        defer { Task { await upstream.stop() } }
        try await upstream.client(.starttls, credentials: Self.credentials).send(from: "n@x.de", recipients: ["a@b.de"], message: Self.message)
        #expect(upstream.recorder.commands.contains("AUTH LOGIN"))
        #expect(upstream.recorder.commands.contains("<login-password>"))
    }

    @Test func noAuthMechanism() async throws {
        var behavior = FakeUpstreamBehavior()
        behavior.capabilities = ["STARTTLS"]
        let upstream = try await FakeUpstream.start(behavior)
        defer { Task { await upstream.stop() } }
        await #expect(throws: SMTPClientError.authNotOffered) {
            try await upstream.client(.starttls, credentials: Self.credentials).send(from: "n@x.de", recipients: ["a@b.de"], message: Self.message)
        }
    }

    @Test func startTLSNotOfferedNeverSendsCredentials() async throws {
        var behavior = FakeUpstreamBehavior()
        behavior.capabilities = ["AUTH PLAIN"]
        let upstream = try await FakeUpstream.start(behavior)
        defer { Task { await upstream.stop() } }
        await #expect(throws: SMTPClientError.startTLSNotOffered) {
            try await upstream.client(.starttls, credentials: Self.credentials).send(from: "n@x.de", recipients: ["a@b.de"], message: Self.message)
        }
        #expect(!upstream.recorder.commands.contains { $0.hasPrefix("AUTH") })
    }

    @Test func wrongHostnameFailsTLS() async throws {
        var behavior = FakeUpstreamBehavior()
        behavior.tlsCertificate = "wrong"
        let upstream = try await FakeUpstream.start(behavior)
        defer { Task { await upstream.stop() } }
        let error = await #expect(throws: SMTPClientError.self) {
            try await upstream.client(.starttls, credentials: Self.credentials).send(from: "n@x.de", recipients: ["a@b.de"], message: Self.message)
        }
        guard case .tlsFailed = error else { Issue.record("expected tlsFailed, got \(String(describing: error))"); return }
    }

    @Test func implicitTLS() async throws {
        var behavior = FakeUpstreamBehavior()
        behavior.implicitTLS = true
        let upstream = try await FakeUpstream.start(behavior)
        defer { Task { await upstream.stop() } }
        try await upstream.client(.ssl, credentials: Self.credentials).send(from: "n@x.de", recipients: ["a@b.de"], message: Self.message)
        #expect(upstream.recorder.messages.count == 1)
    }

    @Test func authRejected() async throws {
        var behavior = FakeUpstreamBehavior()
        behavior.authReply = SMTPReply(535, "5.7.8 bad credentials")
        let upstream = try await FakeUpstream.start(behavior)
        defer { Task { await upstream.stop() } }
        await #expect(throws: SMTPClientError.rejected(stage: .auth, reply: SMTPReply(535, "5.7.8 bad credentials"))) {
            try await upstream.client(.starttls, credentials: Self.credentials).send(from: "n@x.de", recipients: ["a@b.de"], message: Self.message)
        }
    }

    @Test func recipientRejectedAbortsBeforeData() async throws {
        var behavior = FakeUpstreamBehavior()
        behavior.rejectedRecipients = ["bad@b.de": SMTPReply(550, "5.1.1 unknown")]
        let upstream = try await FakeUpstream.start(behavior)
        defer { Task { await upstream.stop() } }
        await #expect(throws: SMTPClientError.rejected(stage: .rcptTo, reply: SMTPReply(550, "5.1.1 unknown"))) {
            try await upstream.client(.plain).send(from: "n@x.de", recipients: ["a@b.de", "bad@b.de"], message: Self.message)
        }
        #expect(!upstream.recorder.commands.contains("DATA"))
    }

    /// Regression: CR/LF in an envelope address ended `RCPT TO` and injected further commands (CWE-93).
    @Test(arguments: ["x@a.de>\r\nDATA", "x@a.de\nRSET", "x@a.de\r", "x@a.de\u{0}", "x@a.de> NOTIFY=NEVER", "x<@a.de", "x@a.de\u{7F}", "ä@b.de"])
    func invalidRecipientIsRejectedBeforeConnecting(_ recipient: String) async throws {
        let upstream = try await FakeUpstream.start()
        defer { Task { await upstream.stop() } }
        await #expect(throws: SMTPClientError.invalidAddress(recipient)) {
            try await upstream.client(.plain).send(from: "n@x.de", recipients: ["a@b.de", recipient], message: Self.message)
        }
        #expect(upstream.recorder.commands.isEmpty)
    }

    @Test func invalidSenderIsRejectedBeforeConnecting() async throws {
        let sender = "n@x.de>\r\nRCPT TO:<victim@y.de"
        let upstream = try await FakeUpstream.start()
        defer { Task { await upstream.stop() } }
        await #expect(throws: SMTPClientError.invalidAddress(sender)) {
            try await upstream.client(.plain).send(from: sender, recipients: ["a@b.de"], message: Self.message)
        }
        #expect(upstream.recorder.commands.isEmpty)
    }

    /// The null reverse-path `MAIL FROM:<>` (used for bounces) stays allowed.
    @Test func emptySenderIsAllowed() async throws {
        let upstream = try await FakeUpstream.start()
        defer { Task { await upstream.stop() } }
        try await upstream.client(.plain).send(from: "", recipients: ["a@b.de"], message: Self.message)
        #expect(upstream.recorder.commands.contains("MAIL FROM:<> SIZE=\(Self.message.count)"))
    }

    @Test func dotStuffing() {
        let stuffed = SMTPClientConnection.dotStuffed(Data(".foo\r\nbar\r\n.\r\n".utf8))
        #expect(String(decoding: stuffed, as: UTF8.self) == "..foo\r\nbar\r\n..\r\n.\r\n")
        #expect(String(decoding: SMTPClientConnection.dotStuffed(Data("no newline".utf8)), as: UTF8.self) == "no newline\r\n.\r\n")
    }

    @Test func eightBitAndSize() async throws {
        let eightBit = Data([0x53, 0x3A, 0x20, 0xC3, 0xA4, 13, 10, 13, 10, 0x61, 13, 10])
        let upstream = try await FakeUpstream.start()
        defer { Task { await upstream.stop() } }
        try await upstream.client(.plain).send(from: "n@x.de", recipients: ["a@b.de"], message: eightBit)
        #expect(upstream.recorder.commands.contains("MAIL FROM:<n@x.de> BODY=8BITMIME SIZE=\(eightBit.count)"))

        var no8Bit = FakeUpstreamBehavior()
        no8Bit.capabilities = []
        let second = try await FakeUpstream.start(no8Bit)
        defer { Task { await second.stop() } }
        await #expect(throws: SMTPClientError.eightBitNotSupported) {
            try await second.client(.plain).send(from: "n@x.de", recipients: ["a@b.de"], message: eightBit)
        }
        #expect(!second.recorder.commands.contains { $0.hasPrefix("MAIL") })

        var small = FakeUpstreamBehavior()
        small.capabilities = ["SIZE 100"]
        let third = try await FakeUpstream.start(small)
        defer { Task { await third.stop() } }
        await #expect(throws: SMTPClientError.messageTooLarge(limit: 100)) {
            try await third.client(.plain).send(from: "n@x.de", recipients: ["a@b.de"], message: Data(repeating: 0x61, count: 200))
        }
    }

    @Test func timeoutsAndClosedConnection() async throws {
        var silent = FakeUpstreamBehavior()
        silent.silence = .greeting
        let upstream = try await FakeUpstream.start(silent)
        defer { Task { await upstream.stop() } }
        await #expect(throws: SMTPClientError.timeout(.greeting)) {
            try await upstream.client(.plain, replyTimeout: .milliseconds(200)).send(from: "n@x.de", recipients: ["a@b.de"], message: Self.message)
        }

        var closing = FakeUpstreamBehavior()
        closing.closeAfterEndOfData = true
        let second = try await FakeUpstream.start(closing)
        defer { Task { await second.stop() } }
        await #expect(throws: SMTPClientError.connectionClosed(.endOfData)) {
            try await second.client(.plain).send(from: "n@x.de", recipients: ["a@b.de"], message: Self.message)
        }
    }

    @Test func connectFailure() async throws {
        let client = try SMTPClient(configuration: SMTPClientConfiguration(host: "127.0.0.1", port: 1, encryption: .plain, connectTimeout: .seconds(2)))
        let error = await #expect(throws: SMTPClientError.self) {
            try await client.send(from: "n@x.de", recipients: ["a@b.de"], message: Self.message)
        }
        guard case .connectFailed = error else { Issue.record("expected connectFailed, got \(String(describing: error))"); return }
    }

    @Test func cancellationClosesConnection() async throws {
        var silent = FakeUpstreamBehavior()
        silent.silence = .afterEHLO
        let upstream = try await FakeUpstream.start(silent)
        defer { Task { await upstream.stop() } }
        let client = try upstream.client(.plain, replyTimeout: .seconds(30))
        let task = Task { try await client.send(from: "n@x.de", recipients: ["a@b.de"], message: Self.message) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = await task.result
        let deadline = ContinuousClock.now + .seconds(2)
        while upstream.recorder.closedConnections == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(upstream.recorder.closedConnections == 1)
    }
}
