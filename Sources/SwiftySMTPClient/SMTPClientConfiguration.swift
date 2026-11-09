public import NIOCore
public import NIOSSL

/// How the connection to the server is secured.
public enum SMTPEncryption: String, Sendable, Equatable, CaseIterable {
    /// Plaintext (usually port 25). Credentials are sent unencrypted.
    case plain
    /// TLS from the first byte, "SMTPS" (usually port 465).
    case ssl
    /// Plaintext connect, then mandatory `STARTTLS` (usually port 587). Never falls back to plaintext.
    case starttls

    public var defaultPort: Int {
        switch self {
        case .plain: 25
        case .ssl: 465
        case .starttls: 587
        }
    }
}

public struct SMTPCredentials: Sendable, Equatable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

// Keeps the password out of logs, string interpolation and `dump`.
extension SMTPCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "SMTPCredentials(username: \(username), password: ***)" }
    public var debugDescription: String { description }
}

public struct SMTPClientConfiguration: Sendable {
    public var host: String
    public var port: Int
    public var encryption: SMTPEncryption
    /// `nil` sends without authentication.
    public var credentials: SMTPCredentials?
    /// Name sent in `EHLO`. The default is an address literal (RFC 5321) that does not reveal internal host names.
    public var clientName: String
    public var connectTimeout: TimeAmount
    /// Maximum time to wait for each single server reply.
    public var replyTimeout: TimeAmount
    /// Trusted CAs for the server certificate (default: the system trust store).
    public var trustRoots: NIOSSLTrustRoots

    /// - Parameter port: Defaults to the usual port for `encryption` (25, 465 or 587).
    public init(
        host: String,
        port: Int? = nil,
        encryption: SMTPEncryption = .starttls,
        credentials: SMTPCredentials? = nil,
        clientName: String = "[127.0.0.1]",
        connectTimeout: TimeAmount = .seconds(30),
        replyTimeout: TimeAmount = .seconds(60),
        trustRoots: NIOSSLTrustRoots = .default
    ) {
        self.host = host
        self.port = port ?? encryption.defaultPort
        self.encryption = encryption
        self.credentials = credentials
        self.clientName = clientName
        self.connectTimeout = connectTimeout
        self.replyTimeout = replyTimeout
        self.trustRoots = trustRoots
    }
}
