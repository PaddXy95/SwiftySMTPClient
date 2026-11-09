import Foundation
import NIOSSL
@testable import SwiftySMTPClient

/// Test PKI in `Tests/SwiftySMTPClientTests/Fixtures` (generated once by `scripts/generate-test-certs.sh`):
/// `ca.pem`, `localhost.pem`/`.key` (SAN localhost, 127.0.0.1), `wrong.pem`/`.key` (SAN wrong.example).
enum TestFixtures {
    static func path(_ name: String, _ ext: String) -> String {
        guard let path = Bundle.module.path(forResource: name, ofType: ext, inDirectory: "Fixtures") else {
            fatalError("Fixture \(name).\(ext) fehlt")
        }
        return path
    }

    static func trustRoots() throws -> NIOSSLTrustRoots {
        .certificates(try NIOSSLCertificate.fromPEMFile(path("ca", "pem")))
    }

    static func serverContext(_ name: String = "localhost") throws -> NIOSSLContext {
        let chain = try NIOSSLCertificate.fromPEMFile(path(name, "pem"))
        let key = try NIOSSLPrivateKey(file: path(name, "key"), format: .pem)
        return try NIOSSLContext(configuration: .makeServerConfiguration(certificateChain: chain.map { .certificate($0) }, privateKey: .privateKey(key)))
    }
}
