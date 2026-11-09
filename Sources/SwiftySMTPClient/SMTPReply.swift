/// An SMTP reply: a three-digit code and one or more text lines.
public struct SMTPReply: Hashable, Sendable {
    public let code: Int
    public let lines: [String]

    public init(code: Int, lines: [String]) {
        self.code = code
        self.lines = lines.isEmpty ? [""] : lines
    }

    public init(_ code: Int, _ text: String) {
        self.init(code: code, lines: [text])
    }

    /// Wire format, e.g. `250-first\r\n250 last\r\n`.
    public func encoded() -> String {
        lines.enumerated().map { index, line in
            "\(code)\(index == lines.count - 1 ? " " : "-")\(line)\r\n"
        }.joined()
    }

    /// All lines joined with a space.
    public var text: String { lines.joined(separator: " ") }
    /// `2xx` or `3xx`.
    public var isPositive: Bool { (200..<400).contains(code) }
    /// `4xx`: the command may succeed when retried later.
    public var isTransientNegative: Bool { (400..<500).contains(code) }
    /// `5xx`: retrying the same command will fail again.
    public var isPermanentNegative: Bool { (500..<600).contains(code) }
}
