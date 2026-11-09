/// Step of the SMTP dialogue in which an error occurred.
public enum SMTPClientStage: String, Sendable, Equatable {
    case connect, greeting, ehlo, startTLS, auth, mailFrom, rcptTo, data, endOfData
}

/// Everything that can go wrong while sending a message.
public enum SMTPClientError: Error, Equatable {
    /// TCP connection could not be established (DNS, refused, connect timeout).
    case connectFailed(String)
    /// TLS handshake or certificate verification failed.
    case tlsFailed(String)
    /// The server did not reply within `replyTimeout`.
    case timeout(SMTPClientStage)
    /// The server closed the connection (or a write failed).
    case connectionClosed(SMTPClientStage)
    /// A reply line was not valid SMTP.
    case malformedReply(String)
    /// The server answered with an unexpected reply code.
    case rejected(stage: SMTPClientStage, reply: SMTPReply)
    /// `.starttls` was requested, but the server does not offer `STARTTLS`.
    case startTLSNotOffered
    /// Credentials are configured, but the server offers neither `AUTH PLAIN` nor `AUTH LOGIN`.
    case authNotOffered
    /// The message contains 8-bit bytes, but the server does not offer `8BITMIME`.
    case eightBitNotSupported
    /// The message is larger than the server's announced `SIZE` limit.
    case messageTooLarge(limit: Int)
}

extension SMTPClientError: CustomStringConvertible {
    /// Single-line description for logs (never contains credentials).
    public var description: String {
        switch self {
        case .connectFailed(let reason): "Connection failed: \(reason)"
        case .tlsFailed(let reason): "TLS failed: \(reason)"
        case .timeout(let stage): "Timed out (\(stage.rawValue))"
        case .connectionClosed(let stage): "Connection closed by server (\(stage.rawValue))"
        case .malformedReply(let line): "Malformed server reply: \(line.prefix(200))"
        case .rejected(let stage, let reply): "Rejected (\(stage.rawValue)): \(reply.code) \(reply.text.prefix(200))"
        case .startTLSNotOffered: "Server does not offer STARTTLS"
        case .authNotOffered: "Server offers neither AUTH PLAIN nor AUTH LOGIN"
        case .eightBitNotSupported: "Message contains 8-bit data, but the server does not support 8BITMIME"
        case .messageTooLarge(let limit): "Message exceeds the server's size limit of \(limit) bytes"
        }
    }
}
