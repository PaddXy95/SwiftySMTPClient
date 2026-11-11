# Configuration

`SMTPClientConfiguration` holds the settings for one server. Only `host` is required.

| Property         | Default                   | Meaning                                                                 |
|------------------|---------------------------|-------------------------------------------------------------------------|
| `host`           | (required)                | Server host name; also used to check the TLS certificate.               |
| `port`           | from `encryption`         | `25` for `.plain`, `465` for `.ssl`, `587` for `.starttls`.             |
| `encryption`     | `.starttls`               | See [Encryption](#encryption).                                          |
| `credentials`    | `nil`                     | `nil` sends without authentication.                                     |
| `clientName`     | `"[127.0.0.1]"`           | Name sent in `EHLO`. The address literal does not reveal host names.    |
| `connectTimeout` | `.seconds(30)`            | TCP connect plus, for `.ssl`, the TLS handshake.                        |
| `replyTimeout`   | `.seconds(60)`            | Maximum wait for **each** server reply.                                 |
| `trustRoots`     | `.default` (system store) | CAs trusted for the server certificate.                                 |

`SMTPClient.init` also takes an optional `eventLoopGroup`. Without it, the client uses
`MultiThreadedEventLoopGroup.singleton`. The initializer throws if no TLS context can be created from `trustRoots`.

Credentials are sent with `AUTH PLAIN`, or with `AUTH LOGIN` if the server does not offer `PLAIN`. The `description`
of `SMTPCredentials` shows the password as `***`.

## SwiftNIO types

Timeouts are SwiftNIO `TimeAmount`s and custom CAs are `NIOSSLTrustRoots`. If you name those types yourself, add
`NIOCore` (from `swift-nio`) or `NIOSSL` (from `swift-nio-ssl`) to your target's dependencies as well and import it.

## Encryption

| `SMTPEncryption` | Behaviour                                                                                        |
|------------------|--------------------------------------------------------------------------------------------------|
| `.plain`         | No encryption. Credentials, if set, are sent **in clear text**; use only on trusted networks.    |
| `.ssl`           | TLS from the first byte (SMTPS).                                                                 |
| `.starttls`      | Connects in plaintext, then requires `STARTTLS`. Fails with `.startTLSNotOffered` otherwise, before any credentials are sent. |

In STARTTLS mode the upgrade is mandatory: there is no silent fallback to plaintext. Anything the server sent before
the TLS handshake is discarded (protection against STARTTLS command injection, CVE-2011-0411).

## TLS verification

TLS is strict: the client always checks the certificate chain and that the certificate matches `host`, and it
requires TLS 1.2 or newer. By default it trusts the system trust store; `trustRoots` replaces it with your own CAs.
TLS client certificates are not supported.

### Servers with their own CA

```swift
import NIOSSL

let ca = try NIOSSLCertificate.fromPEMFile("/etc/ssl/internal-ca.pem")
let configuration = SMTPClientConfiguration(
    host: "mail.internal.example",
    encryption: .starttls,
    trustRoots: .certificates(ca)
)
```
