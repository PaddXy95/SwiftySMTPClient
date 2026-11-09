import Testing
@testable import SwiftySMTPClient

@Suite struct SMTPCapabilitiesTests {
    @Test func typicalProviderReply() {
        let reply = SMTPReply(code: 250, lines: ["smtp.example.com Hello", "SIZE 35882577", "8BITMIME", "STARTTLS", "AUTH PLAIN LOGIN", "ENHANCEDSTATUSCODES"])
        #expect(SMTPCapabilities.parse(reply) == SMTPCapabilities(startTLS: true, authMechanisms: ["PLAIN", "LOGIN"], eightBitMIME: true, maxSize: 35_882_577))
    }

    @Test func lowercaseAndEdgeCases() {
        let reply = SMTPReply(code: 250, lines: ["host", "starttls", "auth login", "AUTH=LOGIN", "size", "8bitmime"])
        let caps = SMTPCapabilities.parse(reply)
        #expect(caps.startTLS && caps.eightBitMIME)
        #expect(caps.authMechanisms == ["LOGIN"])
        #expect(caps.maxSize == nil)
        #expect(SMTPCapabilities.parse(SMTPReply(code: 250, lines: ["host", "SIZE 0"])).maxSize == nil)
    }
}
