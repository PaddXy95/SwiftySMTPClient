/// Collects `ddd-text` continuation lines until the final `ddd text` line.
struct SMTPReplyParser: Sendable {
    private var code: Int?
    private var lines: [String] = []

    init() {}

    mutating func consume(line: String) throws(SMTPClientError) -> SMTPReply? {
        let bytes = Array(line.utf8)
        guard bytes.count >= 3,
              bytes[0..<3].allSatisfy({ (0x30...0x39).contains($0) }),
              let code = Int(String(decoding: bytes[0..<3], as: UTF8.self))
        else { throw .malformedReply(line) }
        let separator: UInt8? = bytes.count > 3 ? bytes[3] : nil
        guard separator == nil || separator == UInt8(ascii: " ") || separator == UInt8(ascii: "-") else {
            throw .malformedReply(line)
        }
        if let current = self.code, current != code {
            throw .malformedReply(line)
        }
        self.code = code
        lines.append(bytes.count > 4 ? String(decoding: bytes[4...], as: UTF8.self) : "")
        if separator == UInt8(ascii: "-") {
            return nil
        }
        let reply = SMTPReply(code: code, lines: lines)
        self.code = nil
        lines = []
        return reply
    }
}
