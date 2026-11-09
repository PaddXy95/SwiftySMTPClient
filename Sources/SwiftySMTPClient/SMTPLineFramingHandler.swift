public import NIOCore

/// Fired through the pipeline (`errorCaught`) when a line exceeds the handler's `maxLineLength`.
public struct SMTPLineTooLongError: Error, Equatable {
    public let maxLineLength: Int

    public init(maxLineLength: Int) {
        self.maxLineLength = maxLineLength
    }
}

/// Splits the inbound byte stream into lines (CRLF, tolerant: bare LF) and emits each line WITHOUT its
/// terminator as a `ByteBuffer` (bytes stay untouched, 8-bit safe). Usable on the client and the server side.
///
/// A custom handler instead of `ByteToMessageDecoder`, because it owns its buffer:
/// - `discardBufferedInput()` drops not-yet-delivered plaintext synchronously after STARTTLS
///   (protection against STARTTLS command injection, CVE-2011-0411). A flag in a `ByteToMessageDecoder`
///   would only be evaluated when the next bytes arrive – i.e. it would drop the first decrypted bytes.
/// - `pauseDelivery()` / `resumeDelivery()` stop line delivery and socket reads while async work runs.
///
/// All methods must be called on the channel's event loop.
public final class SMTPLineFramingHandler: ChannelDuplexHandler, RemovableChannelHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    public static let defaultMaxLineLength = 64 * 1024

    private let maxLineLength: Int
    private var buffer = ByteBuffer()
    private var context: ChannelHandlerContext?
    private var paused = false
    private var readPending = false
    private var delivering = false
    private var failed = false

    /// - Parameter maxLineLength: Longest accepted line in bytes, without terminator. Longer lines fire
    ///   `SMTPLineTooLongError` and stop all further delivery.
    public init(maxLineLength: Int = SMTPLineFramingHandler.defaultMaxLineLength) {
        self.maxLineLength = maxLineLength
    }

    /// Reads one line (without terminator). `nil` if no complete line is buffered yet.
    static func nextLine(in buffer: inout ByteBuffer, maxLength: Int) throws(SMTPLineTooLongError) -> ByteBuffer? {
        let view = buffer.readableBytesView
        guard let lfIndex = view.firstIndex(of: UInt8(ascii: "\n")) else {
            if buffer.readableBytes > maxLength + 1 {
                throw SMTPLineTooLongError(maxLineLength: maxLength)
            }
            return nil
        }
        let lengthIncludingLF = lfIndex - view.startIndex + 1
        var contentLength = lengthIncludingLF - 1
        if contentLength > 0, view[lfIndex - 1] == UInt8(ascii: "\r") {
            contentLength -= 1
        }
        guard contentLength <= maxLength else {
            throw SMTPLineTooLongError(maxLineLength: maxLength)
        }
        let line = buffer.readSlice(length: contentLength)!
        buffer.moveReaderIndex(forwardBy: lengthIncludingLF - contentLength)
        return line
    }

    // MARK: Control API (event loop only)

    /// Drops all bytes received but not yet delivered as lines. Call right before adding a TLS handler for STARTTLS.
    public func discardBufferedInput() {
        buffer.clear()
    }

    /// Stops delivering lines and stops reading from the socket (back pressure) until `resumeDelivery()`.
    public func pauseDelivery() {
        paused = true
    }

    /// Delivers buffered lines and resumes reading.
    public func resumeDelivery() {
        guard paused else { return }
        paused = false
        guard let context else { return }
        deliver(context: context)
        if !paused, readPending {
            readPending = false
            context.read()
        }
    }

    // MARK: ChannelHandler

    public func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        buffer = context.channel.allocator.buffer(capacity: 1024)
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !failed else { return }
        var incoming = Self.unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        deliver(context: context)
    }

    public func read(context: ChannelHandlerContext) {
        if paused {
            readPending = true
        } else {
            context.read()
        }
    }

    private func deliver(context: ChannelHandlerContext) {
        guard !delivering else { return }
        delivering = true
        defer { delivering = false }
        do {
            while !paused, !failed, let line = try Self.nextLine(in: &buffer, maxLength: maxLineLength) {
                context.fireChannelRead(Self.wrapInboundOut(line))
            }
            if buffer.readableBytes == 0 {
                buffer.clear()
            } else if buffer.readerIndex > 4096 {
                buffer.discardReadBytes()
            }
        } catch {
            failed = true
            buffer.clear()
            context.fireErrorCaught(error)
        }
    }
}
