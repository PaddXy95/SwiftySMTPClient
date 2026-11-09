/// Extensions a server announces in its `EHLO` reply (only those the client acts on).
public struct SMTPCapabilities: Sendable, Equatable {
    public var startTLS: Bool
    /// Upper-cased SASL mechanism names, e.g. `PLAIN`, `LOGIN`.
    public var authMechanisms: Set<String>
    public var eightBitMIME: Bool
    /// Maximum message size in bytes (`SIZE` extension); `nil` if not announced or unlimited.
    public var maxSize: Int?

    public init(startTLS: Bool = false, authMechanisms: Set<String> = [], eightBitMIME: Bool = false, maxSize: Int? = nil) {
        self.startTLS = startTLS
        self.authMechanisms = authMechanisms
        self.eightBitMIME = eightBitMIME
        self.maxSize = maxSize
    }

    /// Parses an `EHLO` reply; the first line (the server's greeting) is ignored.
    public static func parse(_ reply: SMTPReply) -> SMTPCapabilities {
        var capabilities = SMTPCapabilities()
        for line in reply.lines.dropFirst() {
            let tokens = line.uppercased().split(separator: " ").map(String.init)
            guard let keyword = tokens.first else { continue }
            switch keyword {
            case "STARTTLS": capabilities.startTLS = true
            case "AUTH": capabilities.authMechanisms.formUnion(tokens.dropFirst())
            case "8BITMIME": capabilities.eightBitMIME = true
            case "SIZE":
                if tokens.count > 1, let size = Int(tokens[1]), size > 0 {
                    capabilities.maxSize = size
                }
            default: break
            }
        }
        return capabilities
    }
}
