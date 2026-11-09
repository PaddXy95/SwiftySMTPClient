import Foundation
import NIOCore
import Testing
import SwiftySMTPClient

/// Uses only the public API, as a consumer of the package would.
@Suite struct SMTPClientConnectionTests {
    @Test func manualDialogue() async throws {
        let upstream = try await FakeUpstream.start()
        defer { Task { await upstream.stop() } }
        let connection = try await SMTPClientConnection.connect(host: "127.0.0.1", port: upstream.port, connectTimeout: .seconds(2))
        #expect(try await connection.readReply(stage: .greeting, timeout: .seconds(2)) == SMTPReply(220, "fake ESMTP"))
        let ehlo = try await connection.command("EHLO test", stage: .ehlo, timeout: .seconds(2))
        #expect(SMTPCapabilities.parse(ehlo).startTLS)
        #expect(try await connection.command("NOOP", stage: .ehlo, timeout: .seconds(2)).code == 502)
        await connection.close()
        #expect(upstream.recorder.commands == ["EHLO test", "NOOP"])
    }

    /// Regression: a server that greets and closes at once (e.g. 421 at its connection limit) made `connect` fail
    /// with `connectFailed("notFound")`, because the client looked up its handler after NIO had torn down the pipeline.
    @Test func greetingBeforeImmediateCloseIsStillRead() async throws {
        var behavior = FakeUpstreamBehavior()
        behavior.greeting = SMTPReply(421, "4.3.2 Too many connections, try again later")
        behavior.closeAfterGreeting = true
        let upstream = try await FakeUpstream.start(behavior)
        defer { Task { await upstream.stop() } }
        for _ in 0..<10 {
            // Occupy every thread of the cooperative pool (as a busy CI runner does), so the task resumes after
            // `connect` only once NIO has already read the 421, seen the close and torn down the pipeline.
            let spinners = (0..<ProcessInfo.processInfo.activeProcessorCount).map { _ in
                Task.detached {
                    let end = ContinuousClock.now + .milliseconds(50)
                    while ContinuousClock.now < end {}
                }
            }
            let connection = try await SMTPClientConnection.connect(host: "127.0.0.1", port: upstream.port, connectTimeout: .seconds(2))
            for spinner in spinners { await spinner.value }
            #expect(try await connection.readReply(stage: .greeting, timeout: .seconds(2)) == behavior.greeting)
            await #expect(throws: SMTPClientError.connectionClosed(.greeting)) {
                try await connection.readReply(stage: .greeting, timeout: .seconds(2))
            }
            await connection.close()
        }
    }

    /// Regression: a DATA write to a server that stops reading ignored cancellation, so a caller's overall
    /// deadline could never end the attempt.
    @Test(.timeLimit(.minutes(1))) func cancellationEndsStalledDataWrite() async throws {
        var behavior = FakeUpstreamBehavior()
        behavior.stopReadingAfterData = .seconds(15)
        behavior.capabilities = ["8BITMIME", "SIZE 100000000"]
        let upstream = try await FakeUpstream.start(behavior)
        defer { Task { await upstream.stop() } }
        let client = try upstream.client(.plain, replyTimeout: .seconds(30))
        let big = Data(repeating: UInt8(ascii: "a"), count: 8 * 1024 * 1024)
        let started = ContinuousClock.now
        let task = Task { try await client.send(from: "n@x.de", recipients: ["a@b.de"], message: big) }
        try await Task.sleep(for: .seconds(1))
        task.cancel()
        let result = await task.result
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(throws: SMTPClientError.self) { try result.get() }
    }
}

@Suite struct SMTPClientConfigurationTests {
    @Test func defaultPortFollowsEncryption() {
        #expect(SMTPClientConfiguration(host: "h", encryption: .plain).port == 25)
        #expect(SMTPClientConfiguration(host: "h", encryption: .ssl).port == 465)
        #expect(SMTPClientConfiguration(host: "h").port == 587)
        #expect(SMTPClientConfiguration(host: "h", port: 2525, encryption: .ssl).port == 2525)
    }

    @Test func passwordNeverRendered() throws {
        let credentials = SMTPCredentials(username: "user", password: "s3cret-token")
        let client = try SMTPClient(configuration: SMTPClientConfiguration(host: "h", credentials: credentials))
        for value in [credentials as Any, client.configuration, client] {
            for rendered in [String(describing: value), String(reflecting: value)] {
                #expect(!rendered.contains("s3cret-token"), "password leaked in \(rendered)")
            }
        }
    }

    @Test func errorDescription() {
        let error = SMTPClientError.rejected(stage: .rcptTo, reply: SMTPReply(550, "5.1.1 unknown"))
        #expect(error.description == "Rejected (rcptTo): 550 5.1.1 unknown")
        #expect("\(SMTPClientError.timeout(.greeting))" == "Timed out (greeting)")
    }
}
