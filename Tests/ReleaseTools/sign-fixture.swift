// Deterministic test-only seed. Never used by the application or release signer.
import Foundation
import CryptoKit
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let data = try JSONSerialization.data(withJSONObject: [
    "publicKey": key.publicKey.rawRepresentation.base64EncodedString(),
    "signature": key.signature(for: input).base64EncodedString()
])
print(String(decoding: data, as: UTF8.self))
