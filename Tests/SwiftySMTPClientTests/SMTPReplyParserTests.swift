import Testing
@testable import SwiftySMTPClient

@Suite struct SMTPReplyParserTests {
    @Test func singleLine() throws {
        var parser = SMTPReplyParser()
        #expect(try parser.consume(line: "250 OK") == SMTPReply(250, "OK"))
    }

    @Test func multiLineAcrossCalls() throws {
        var parser = SMTPReplyParser()
        #expect(try parser.consume(line: "250-a") == nil)
        #expect(try parser.consume(line: "250-b") == nil)
        #expect(try parser.consume(line: "250 c") == SMTPReply(code: 250, lines: ["a", "b", "c"]))
        #expect(try parser.consume(line: "221") == SMTPReply(221, ""))
    }

    @Test func malformed() {
        var parser = SMTPReplyParser()
        #expect(throws: SMTPClientError.malformedReply("abc")) { try parser.consume(line: "abc") }
        var other = SMTPReplyParser()
        _ = try? other.consume(line: "250-a")
        #expect(throws: SMTPClientError.malformedReply("251 b")) { try other.consume(line: "251 b") }
        var third = SMTPReplyParser()
        #expect(throws: SMTPClientError.self) { try third.consume(line: "250xOK") }
    }
}
