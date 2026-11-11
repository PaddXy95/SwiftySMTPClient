# Usage

`SMTPClient.send(from:recipients:message:)` sends one message. The [Quick start](../README.md#quick-start) shows a
complete example; this page explains what goes in and how a send behaves.

## Message format

`message` must be a complete RFC 5322 message: headers, an empty line, then the body, all with **CRLF** line endings.
The client sends it exactly as given. Building MIME (HTML, attachments, encoded headers) is up to you or another
library.

- Dot-stuffing and the terminating `CRLF.CRLF` are added for you, and bytes are sent unchanged (8-bit safe).
- For a message with 8-bit bytes, `MAIL FROM` carries `BODY=8BITMIME`. If the server does not offer `8BITMIME`,
  `send` fails with `eightBitNotSupported` before `MAIL FROM`.
- If the server announces a `SIZE` limit, `MAIL FROM` carries the message size. A larger message fails with
  `messageTooLarge(limit:)` before `MAIL FROM`.

## Envelope and Bcc

The envelope (`from`, `recipients`) is what the server delivers to. `from` is the envelope sender (`MAIL FROM`), a
bare address without angle brackets; `recipients` are the envelope recipients (`RCPT TO`). The `From:`/`To:`/`Cc:`
headers are only what the recipient sees, so Cc and Bcc recipients go in `recipients`, and Bcc recipients in no
header.

An empty `from` sends the null reverse-path `<>` (as used for bounces). Addresses must be printable ASCII without
spaces, `<` or `>`; anything else throws `.invalidAddress` before connecting, so untrusted addresses cannot inject SMTP
commands.

```swift
try await client.send(
    from: "noreply@example.com",
    recipients: ["alice@example.org", "bob@example.org", "audit@example.com"],  // To, Cc and Bcc
    message: message   // headers: To: alice@example.org, Cc: bob@example.org, no Bcc header
)
```

The first rejected recipient ends the whole transaction, see [Errors](errors.md#rejected-recipients).

## Connections and concurrency

Every `send` opens its own connection and closes it when it is done: there is no pooling and no shared state.
`SMTPClient` is a `Sendable` value that is cheap to copy; you can use one instance from any number of tasks at once.

## Timeouts and cancellation

`connectTimeout` covers the TCP connect plus, for `.ssl`, the TLS handshake. `replyTimeout` applies to **each**
server reply, so a large message to a slow server can take longer than that in total. For an overall deadline, cancel
the task:

```swift
try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try await client.send(from: sender, recipients: recipients, message: message) }
    group.addTask {
        try await Task.sleep(for: .seconds(120))
        throw CancellationError()
    }
    try await group.next()      // first one to finish wins
    group.cancelAll()           // closes the connection if the deadline won
}
```

Cancelling the calling task closes the connection right away, even if a write is stuck on a server that stopped
reading. A cancelled `send` throws `connectionClosed` for the step it was in.

## Not included

- Building messages (MIME, attachments, encoded words), DKIM signing
- MX lookup: the client talks to the one host you configure
- Connection reuse or `PIPELINING`
- `SMTPUTF8` (use ASCII addresses), `DSN`, and SASL mechanisms other than `PLAIN` and `LOGIN` (no `XOAUTH2`)
- TLS client certificates
