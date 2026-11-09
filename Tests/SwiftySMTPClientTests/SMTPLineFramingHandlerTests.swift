import NIOCore
import NIOEmbedded
import Testing
@testable import SwiftySMTPClient

@Suite struct SMTPLineFramingHandlerTests {
    func channel(maxLineLength: Int = 64) throws -> (EmbeddedChannel, SMTPLineFramingHandler) {
        let framer = SMTPLineFramingHandler(maxLineLength: maxLineLength)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(framer)
        return (channel, framer)
    }

    func lines(_ channel: EmbeddedChannel) throws -> [String] {
        var result: [String] = []
        while var line = try channel.readInbound(as: ByteBuffer.self) {
            result.append(line.readString(length: line.readableBytes) ?? "")
        }
        return result
    }

    @Test func splitsCRLFAndBareLFAcrossChunks() throws {
        let (channel, _) = try channel()
        try channel.writeInbound(ByteBuffer(string: "EHLO a\r\nNO"))
        try channel.writeInbound(ByteBuffer(string: "OP\nQUIT\r"))
        #expect(try lines(channel) == ["EHLO a", "NOOP"])
        try channel.writeInbound(ByteBuffer(string: "\n\r\n"))
        #expect(try lines(channel) == ["QUIT", ""])
    }

    @Test func keepsEightBitBytes() throws {
        let (channel, _) = try channel()
        try channel.writeInbound(ByteBuffer(bytes: [0xC3, 0xA4, 0xFF, 13, 10]))
        var line = try #require(try channel.readInbound(as: ByteBuffer.self))
        #expect(line.readBytes(length: line.readableBytes) == [0xC3, 0xA4, 0xFF])
    }

    @Test func tooLongLineFiresError() throws {
        let (channel, _) = try channel(maxLineLength: 8)
        #expect(throws: SMTPLineTooLongError(maxLineLength: 8)) {
            try channel.writeInbound(ByteBuffer(string: "0123456789\r\n"))
        }
        let (unterminated, _) = try self.channel(maxLineLength: 8)
        #expect(throws: SMTPLineTooLongError(maxLineLength: 8)) {
            try unterminated.writeInbound(ByteBuffer(string: "0123456789"))
        }
    }

    @Test func discardDropsBufferedBytes() throws {
        let (channel, framer) = try channel()
        try channel.writeInbound(ByteBuffer(string: "partial"))
        framer.discardBufferedInput()
        try channel.writeInbound(ByteBuffer(string: "next\r\n"))
        #expect(try lines(channel) == ["next"])
    }

    @Test func pauseHoldsLinesUntilResume() throws {
        let (channel, framer) = try channel()
        framer.pauseDelivery()
        try channel.writeInbound(ByteBuffer(string: "a\r\nb\r\n"))
        #expect(try lines(channel).isEmpty)
        framer.resumeDelivery()
        #expect(try lines(channel) == ["a", "b"])
    }
}
