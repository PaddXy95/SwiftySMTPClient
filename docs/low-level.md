# Low-level API

## SMTPClientConnection

`SMTPClientConnection` is the layer `SMTPClient` is built on. You drive the dialogue yourself, command by command,
which is handy for integration tests of an SMTP server or for commands the client does not send:

```swift
let connection = try await SMTPClientConnection.connect(host: "localhost", port: 2525)
let greeting = try await connection.readReply(stage: .greeting, timeout: .seconds(5))
let ehlo = try await connection.command("EHLO test", stage: .ehlo, timeout: .seconds(5))
print(greeting.code, SMTPCapabilities.parse(ehlo))
_ = try await connection.command("QUIT", stage: .data, timeout: .seconds(5))
await connection.close()
```

| Method                                     | Does                                                                   |
|--------------------------------------------|------------------------------------------------------------------------|
| `connect(host:port:implicitTLS:connectTimeout:eventLoopGroup:)` | Opens the connection (with `implicitTLS`, including the handshake). Does not read the greeting. |
| `readReply(stage:timeout:)`                | Waits for the next reply, also a multi-line one.                       |
| `command(_:stage:timeout:)`                | Sends one line (`CRLF` is appended) and returns the reply. A line with CR or LF throws `.invalidCommand` and sends nothing.             |
| `sendData(_:timeout:)`                     | After `354` to `DATA`: sends the message with dot-stuffing and `CRLF.CRLF`, returns the final reply. |
| `startTLS(context:serverHostname:timeout:)`| After `220` to `STARTTLS`: upgrades to TLS and discards input received before the handshake. |
| `close()`                                  | Closes the connection without sending `QUIT`.                          |

`stage` only labels errors. `connect(implicitTLS:)` and `startTLS(context:serverHostname:timeout:)` take an
`NIOSSLContext` you build yourself. Only one command may be in flight at a time. A reply timeout closes the
connection, because the dialogue is out of sync afterwards.

`SMTPCapabilities.parse(_:)` reads an `EHLO` reply into the extensions the client acts on: `startTLS`,
`authMechanisms`, `eightBitMIME` and `maxSize`.

## Building blocks for SMTP servers

Two types are useful on the server side as well:

- **`SMTPLineFramingHandler`**: a SwiftNIO handler that splits the byte stream into lines (CRLF, bare LF
  tolerated) and passes each line on as a `ByteBuffer` without its terminator. It enforces a maximum line length
  (`SMTPLineTooLongError`), can drop buffered plaintext before a STARTTLS handshake (`discardBufferedInput()`),
  and can pause delivery and socket reads while you do async work (`pauseDelivery()` / `resumeDelivery()`).
  Call its methods on the channel's event loop.
- **`SMTPReply`**: a reply code plus lines. `encoded()` returns the wire format (`250-first\r\n250 last\r\n`).

```swift
let framer = SMTPLineFramingHandler(maxLineLength: 1000)
try channel.pipeline.syncOperations.addHandler(framer)
try channel.pipeline.syncOperations.addHandler(MyCommandHandler(framer: framer))  // receives one line per read
// …
context.writeAndFlush(NIOAny(ByteBuffer(string: SMTPReply(250, "OK").encoded())), promise: nil)
```
