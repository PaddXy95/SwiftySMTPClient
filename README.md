# SwiftySMTPClient

[![CI](https://github.com/PaddXy95/SwiftySMTPClient/actions/workflows/ci.yml/badge.svg)](https://github.com/PaddXy95/SwiftySMTPClient/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/PaddXy95/SwiftySMTPClient?include_prereleases&sort=semver)](https://github.com/PaddXy95/SwiftySMTPClient/releases)

A small, async/await SMTP client for Swift, built on [SwiftNIO](https://github.com/apple/swift-nio) and
[SwiftNIO SSL](https://github.com/apple/swift-nio-ssl). It hands a finished message to an SMTP server, such as
your mail provider's submission server, a relay or a local MTA. It does not build the message for you.

```swift
let client = try SMTPClient(configuration: SMTPClientConfiguration(
    host: "smtp.example.com",
    encryption: .starttls,
    credentials: SMTPCredentials(username: "noreply@example.com", password: "app-password")
))
try await client.send(from: "noreply@example.com", recipients: ["alice@example.org"], message: message)
```

## Features

- **async/await API** with typed throws (`throws(SMTPClientError)`). Every error says which step of the dialogue failed.
- **Encryption:** plaintext, implicit TLS (SMTPS, port 465) or STARTTLS (port 587). In STARTTLS mode the upgrade
  is mandatory: there is no silent fallback to plaintext.
- **Strict TLS:** full certificate and hostname verification, TLS 1.2 or newer, system trust store or your own CAs.
- **Authentication:** `AUTH PLAIN`, with `AUTH LOGIN` as a fallback.
- **ESMTP extensions:** reads `SIZE` and `8BITMIME` from the `EHLO` reply. Oversized or 8-bit messages are
  refused *before* `MAIL FROM` when the server cannot accept them.
- **Correct `DATA` encoding:** dot-stuffing and the terminating `CRLF.CRLF` are added for you, and bytes are sent
  unchanged (8-bit safe).
- **Timeouts and cancellation:** a connect timeout and a timeout for each reply. Cancelling the calling task closes
  the connection right away, even if a write is stuck on a server that stopped reading.
- **One connection per message:** no pooling and no shared state. `SMTPClient` is a `Sendable` value you can use
  from any number of tasks at once.
- **Low-level access:** `SMTPClientConnection` lets you run the dialogue command by command, for example to test
  your own SMTP server.
- Runs on **Linux and macOS**.

## Requirements

- Swift 6.2 or newer
- macOS 13+ or Linux (both are tested). It also builds for iOS 16+; tvOS 16, watchOS 9 and visionOS 1 are declared
  as minimums, but none of these platforms are tested at runtime.

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/PaddXy95/SwiftySMTPClient.git", .upToNextMinor(from: "0.1.0")),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "SwiftySMTPClient", package: "SwiftySMTPClient"),
        ]
    ),
]
```

While the package is below `1.0.0`, only a minor version (`0.2.0`) may contain breaking changes; new features and
fixes come as patch versions. `.upToNextMinor` therefore picks up every compatible release, while `from:` would also
accept the breaking `0.2.0`, `0.3.0` and so on.

Timeouts are SwiftNIO `TimeAmount`s and custom CAs are `NIOSSLTrustRoots`. If you name those types yourself, add
`NIOCore` (from `swift-nio`) or `NIOSSL` (from `swift-nio-ssl`) to your target's dependencies as well and import it.

## Usage

### Sending a message

`message` must be a complete RFC 5322 message: headers, an empty line, then the body, all with **CRLF** line
endings. The client sends it exactly as given. Building MIME (HTML, attachments, encoded headers) is up to you or
another library.

```swift
import Foundation
import SwiftySMTPClient

let client = try SMTPClient(configuration: SMTPClientConfiguration(
    host: "smtp.example.com",          // port defaults to 587 for .starttls
    encryption: .starttls,
    credentials: SMTPCredentials(username: "noreply@example.com", password: "app-password")
))

let message = Data([
    "From: Example App <noreply@example.com>",
    "To: alice@example.org",
    "Subject: Hello",
    "MIME-Version: 1.0",
    "Content-Type: text/plain; charset=utf-8",
    "Content-Transfer-Encoding: 8bit",
    "",
    "Hi Alice, greetings from Swift!",
].joined(separator: "\r\n").utf8)

try await client.send(
    from: "noreply@example.com",                 // envelope sender (MAIL FROM)
    recipients: ["alice@example.org"],           // envelope recipients (RCPT TO), include Cc and Bcc here
    message: message
)
```

The envelope (`from`, `recipients`) is what the server delivers to. The `From:`/`To:`/`Cc:` headers are only what
the recipient sees, so Bcc recipients go in `recipients` and in no header.

### Configuration

| Property         | Default                   | Meaning                                                                 |
|------------------|---------------------------|-------------------------------------------------------------------------|
| `host`           | (required)                | Server host name; also used to check the TLS certificate.               |
| `port`           | from `encryption`         | `25` for `.plain`, `465` for `.ssl`, `587` for `.starttls`.             |
| `encryption`     | `.starttls`               | See below.                                                              |
| `credentials`    | `nil`                     | `nil` sends without authentication.                                     |
| `clientName`     | `"[127.0.0.1]"`           | Name sent in `EHLO`. The address literal does not reveal host names.    |
| `connectTimeout` | `.seconds(30)`            | TCP connect plus, for `.ssl`, the TLS handshake.                        |
| `replyTimeout`   | `.seconds(60)`            | Maximum wait for **each** server reply.                                 |
| `trustRoots`     | `.default` (system store) | CAs trusted for the server certificate.                                 |

`SMTPClient.init` also takes an optional `eventLoopGroup`. Without it, the client uses
`MultiThreadedEventLoopGroup.singleton`.

| `SMTPEncryption` | Behaviour                                                                                        |
|------------------|--------------------------------------------------------------------------------------------------|
| `.plain`         | No encryption. Credentials, if set, are sent **in clear text**; use only on trusted networks.    |
| `.ssl`           | TLS from the first byte (SMTPS).                                                                 |
| `.starttls`      | Connects in plaintext, then requires `STARTTLS`. Fails with `.startTLSNotOffered` otherwise, before any credentials are sent. |

#### Servers with their own CA

```swift
import NIOSSL

let ca = try NIOSSLCertificate.fromPEMFile("/etc/ssl/internal-ca.pem")
let configuration = SMTPClientConfiguration(
    host: "mail.internal.example",
    encryption: .starttls,
    trustRoots: .certificates(ca)
)
```

### Error handling

`send` throws `SMTPClientError`. Every case has a one-line `description` that is safe to log; it never contains
credentials.

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

`SMTPClientStage` is one of `connect`, `greeting`, `ehlo`, `startTLS`, `auth`, `mailFrom`, `rcptTo`, `data` and
`endOfData`. A failure in `endOfData` is the critical one: the server may or may not have accepted the message.

A typical retry decision:

```swift
do throws(SMTPClientError) {
    try await client.send(from: sender, recipients: recipients, message: message)
} catch {
    switch error {
    case .rejected(.auth, _):
        break   // credentials: fix the configuration, then retry
    case .rejected(_, let reply) where reply.isPermanentNegative,   // 5xx
         .eightBitNotSupported, .messageTooLarge, .invalidAddress, .invalidCommand:
        break   // permanent: the same message will fail again
    default:
        break   // network, TLS, timeout, 4xx: retry later
    }
}
```

The first rejected recipient ends the transaction before `DATA`, so nothing is sent to the other recipients
either. If you need per-recipient results, send one message per recipient.

### Timeouts and cancellation

`replyTimeout` applies to each reply, so a large message to a slow server can take longer than that in total. For
an overall deadline, cancel the task:

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

A cancelled `send` throws `connectionClosed` for the step it was in.

### Low-level connection

`SMTPClientConnection` is the layer `SMTPClient` is built on. It is handy for integration tests of an SMTP server
or for commands the client does not send:

```swift
let connection = try await SMTPClientConnection.connect(host: "localhost", port: 2525)
let greeting = try await connection.readReply(stage: .greeting, timeout: .seconds(5))
let ehlo = try await connection.command("EHLO test", stage: .ehlo, timeout: .seconds(5))
print(greeting.code, SMTPCapabilities.parse(ehlo))
_ = try await connection.command("QUIT", stage: .data, timeout: .seconds(5))
await connection.close()
```

`stage` only labels errors. `connect(implicitTLS:)` and `startTLS(context:serverHostname:timeout:)` take an
`NIOSSLContext` you build yourself. Only one command may be in flight at a time.

### Building blocks for SMTP servers

Two types are useful on the server side as well:

- **`SMTPLineFramingHandler`**: a SwiftNIO handler that splits the byte stream into lines (CRLF, bare LF
  tolerated) and passes each line on as a `ByteBuffer` without its terminator. It enforces a maximum line length
  (`SMTPLineTooLongError`), can drop buffered plaintext before a STARTTLS handshake (`discardBufferedInput()`),
  and can pause delivery and socket reads while you do async work (`pauseDelivery()` / `resumeDelivery()`).
- **`SMTPReply`**: a reply code plus lines. `encoded()` returns the wire format (`250-first\r\n250 last\r\n`).

```swift
let framer = SMTPLineFramingHandler(maxLineLength: 1000)
try channel.pipeline.syncOperations.addHandler(framer)
try channel.pipeline.syncOperations.addHandler(MyCommandHandler(framer: framer))  // receives one line per read
// …
context.writeAndFlush(NIOAny(ByteBuffer(string: SMTPReply(250, "OK").encoded())), promise: nil)
```

## Not included

- Building messages (MIME, attachments, encoded words), DKIM signing
- MX lookup: the client talks to the one host you configure
- Connection reuse or `PIPELINING`
- `SMTPUTF8` (use ASCII addresses), `DSN`, and SASL mechanisms other than `PLAIN` and `LOGIN` (no `XOAUTH2`)
- TLS client certificates

## Development

```bash
swift build
swift test                      # unit and integration tests against an in-process fake server
scripts/generate-test-certs.sh  # regenerate the test PKI in Tests/SwiftySMTPClientTests/Fixtures
```

The tests start a scripted SMTP server on `127.0.0.1` with a test CA and need no network access.

### CI and releases

Everything runs in [`ci.yml`](.github/workflows/ci.yml):

- **Every pull request and every push to `main`:** `swift test` on Linux with Swift 6.2 (the oldest supported
  toolchain) and 6.4, and on macOS with Xcode 26, plus a build for iOS.
- **Every push to `main`:** once all tests pass, a new version is released right away. The workflow creates the git
  tag and the GitHub release. SwiftPM reads versions straight from the tags, so there is no registry to upload to.

The new version follows from the commit messages since the last release
([Conventional Commits](https://www.conventionalcommits.org), [`scripts/release-version.sh`](scripts/release-version.sh)):

| Commits since the last release                                        | while `0.x`       | from `1.0.0` on   |
|-----------------------------------------------------------------------|-------------------|-------------------|
| a breaking change: `feat!: …`, `fix(api)!: …` or a `BREAKING CHANGE:` footer | `0.1.3` → `0.2.0` | `1.4.2` → `2.0.0` |
| at least one `feat: …`                                                | `0.1.3` → `0.1.4` | `1.4.2` → `1.5.0` |
| anything else (`fix:`, `docs:`, `ci:`, `refactor:`, …)                | `0.1.3` → `0.1.4` | `1.4.2` → `1.4.3` |

The first push releases `0.1.0`. All commits of one push end up in one release. The release notes list them,
followed by GitHub's generated notes (merged pull requests and a compare link).

- **Push without a release:** put `[skip ci]` in the commit message (of the last commit, if you push several). This
  skips the tests as well.
- **Failing tests:** nothing is released. The next green push releases those commits too.
- **`1.0.0`** is never reached automatically. When the API is stable, create it once by hand, e.g.
  `gh release create 1.0.0 --target main --generate-notes`. Later pushes continue from there.
- **Never move or delete a published tag.** SwiftPM pins the commit in `Package.resolved`, so a moved tag breaks
  resolution for everyone who already uses it. Push a fix instead; it becomes the next patch version.

The client was first written for [SwiftyRelay](https://github.com/PaddXy95/SwiftyRelay), a self-hosted mail
gateway.
