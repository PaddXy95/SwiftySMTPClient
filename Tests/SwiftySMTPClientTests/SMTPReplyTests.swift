import Testing
@testable import SwiftySMTPClient

@Suite struct SMTPReplyTests {
    @Test func encodesMultiline() {
        #expect(SMTPReply(code: 250, lines: ["a", "b"]).encoded() == "250-a\r\n250 b\r\n")
        #expect(SMTPReply(221, "bye").encoded() == "221 bye\r\n")
    }
}
