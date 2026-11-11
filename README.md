# SwiftySMTPClient

[![CI](https://github.com/PaddXy95/SwiftySMTPClient/actions/workflows/ci.yml/badge.svg)](https://github.com/PaddXy95/SwiftySMTPClient/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/PaddXy95/SwiftySMTPClient?include_prereleases&sort=semver)](https://github.com/PaddXy95/SwiftySMTPClient/releases)
![Swift](https://img.shields.io/badge/Swift-6.2%2B-F05138?logo=swift&logoColor=white)
![Platforms](https://img.shields.io/badge/Platforms-macOS%2013%2B%20%7C%20Linux%20%7C%20iOS%2016%2B-lightgrey)
![SwiftNIO](https://img.shields.io/badge/SwiftNIO-2-F05138)
![License](https://img.shields.io/badge/License-MIT-blue)

A small async/await SMTP client for Swift, built on [SwiftNIO](https://github.com/apple/swift-nio) and
[SwiftNIO SSL](https://github.com/apple/swift-nio-ssl). It hands a finished message to an SMTP server, such as your
mail provider's submission server, a relay or a local MTA. It does not build the message for you, and it deliberately
leaves out MX lookup, connection reuse, DKIM and SASL mechanisms other than `PLAIN` and `LOGIN`
(see [Not included](docs/usage.md#not-included)).

```swift
let client = try SMTPClient(configuration: SMTPClientConfiguration(
    host: "smtp.example.com",
    encryption: .starttls,
    credentials: SMTPCredentials(username: "noreply@example.com", password: "app-password")
))
try await client.send(from: "noreply@example.com", recipients: ["alice@example.org"], message: message)
```

## Features

- async/await API with typed throws (`throws(SMTPClientError)`); errors say which step of the dialogue failed
- Plaintext, implicit TLS (SMTPS, port 465) or STARTTLS (port 587), with no silent fallback to plaintext
- Strict TLS: certificate and host name verification, TLS 1.2 or newer, system trust store or your own CAs
- `AUTH PLAIN`, with `AUTH LOGIN` as a fallback
- No command injection: addresses and command lines with CR, LF, `<` or `>` are rejected before anything is sent
- Reads `SIZE` and `8BITMIME`: oversized or 8-bit messages the server cannot take fail before `MAIL FROM`
- Dot-stuffing and the terminating `CRLF.CRLF` are added for you; bytes are sent unchanged (8-bit safe)
- Connect timeout, a timeout per reply, and cancellation that closes the connection right away
- One connection per message, no pooling, no shared state: `SMTPClient` is a `Sendable` value for any number of tasks
- `SMTPClientConnection` runs the dialogue command by command, for example to test your own SMTP server
- Runs on Linux and macOS

## Installation

Requires Swift 6.2 or newer and macOS 13+ or Linux (both are tested). It also builds for iOS 16+; tvOS 16, watchOS 9
and visionOS 1 are declared as minimums, but none of these platforms are tested at runtime.

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

## Quick start

`message` is a complete RFC 5322 message with CRLF line endings, sent exactly as given. The envelope (`from`,
`recipients`) decides who gets it, so Cc and Bcc recipients go in `recipients` as well.

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

## Documentation

- [Usage](docs/usage.md): message format, envelope and Bcc, concurrency, timeouts and cancellation, what is not included
- [Configuration](docs/configuration.md): all options, encryption modes, TLS verification, servers with their own CA
- [Errors](docs/errors.md): error cases, dialogue stages, retry decisions, rejected recipients
- [Low-level API](docs/low-level.md): `SMTPClientConnection` and building blocks for SMTP servers
- [Development](docs/development.md): build, tests, test certificates, CI and releases

## About

SwiftySMTPClient was first written for [SwiftyRelay](https://github.com/PaddXy95/SwiftyRelay), a self-hosted mail
gateway.

SwiftySMTPClient is written with AI. Code, tests and documentation were created with Claude by Anthropic and fully
reviewed by me.

## License

[MIT](LICENSE), Copyright (c) 2026 PaddXy95.
