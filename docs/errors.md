# Errors

`send` throws `SMTPClientError` (typed throws). Every case has a one-line `description` that is safe to log; it never
contains credentials.

| Case                              | When                                                                 |
|-----------------------------------|----------------------------------------------------------------------|
| `connectFailed(String)`           | DNS, connection refused, connect timeout                             |
| `tlsFailed(String)`               | Handshake or certificate verification failed                         |
| `timeout(SMTPClientStage)`        | No reply within `replyTimeout`                                       |
| `connectionClosed(SMTPClientStage)` | The server closed the connection, or a write failed                |
| `malformedReply(String)`          | The server sent something that is not an SMTP reply                  |
| `rejected(stage:reply:)`          | Unexpected reply code, e.g. `535` for bad credentials or `550` for an unknown recipient |
| `startTLSNotOffered`              | `.starttls` requested, but the server does not offer it              |
| `authNotOffered`                  | Credentials set, but neither `AUTH PLAIN` nor `AUTH LOGIN` is offered |
| `eightBitNotSupported`            | The message has 8-bit bytes, but the server lacks `8BITMIME`         |
| `messageTooLarge(limit:)`         | The message exceeds the server's `SIZE` limit                        |
| `invalidAddress(String)`          | A sender or recipient has a character other than printable ASCII, or a space, `<` or `>`. Checked before connecting, so untrusted addresses cannot inject SMTP commands |
| `invalidCommand(SMTPClientStage)` | A line passed to `SMTPClientConnection.command` (or `clientName`) contains CR or LF. Nothing is sent |

## Stages

`SMTPClientStage` is one of `connect`, `greeting`, `ehlo`, `startTLS`, `auth`, `mailFrom`, `rcptTo`, `data` and
`endOfData`. A failure in `endOfData` is the critical one: the server may or may not have accepted the message.

## Retry decisions

`SMTPReply` tells transient `4xx` replies (`isTransientNegative`) from permanent `5xx` ones (`isPermanentNegative`).
A typical retry decision:

```swift
do throws(SMTPClientError) {
    try await client.send(from: sender, recipients: recipients, message: message)
} catch {
    switch error {
    case .rejected(.auth, _):
        break   // credentials: fix the configuration, then retry
    case .rejected(_, let reply) where reply.isPermanentNegative:   // 5xx
        break   // permanent: the same message will fail again
    case .eightBitNotSupported, .messageTooLarge, .invalidAddress, .invalidCommand:
        break   // permanent as well
    default:
        break   // network, TLS, timeout, 4xx: retry later
    }
}
```

## Rejected recipients

The first rejected recipient ends the transaction before `DATA`, so nothing is sent to the other recipients either.
If you need per-recipient results, send one message per recipient.
