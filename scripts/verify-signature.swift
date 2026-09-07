import Foundation
import CryptoKit

let arguments = CommandLine.arguments
func fail() -> Never { fputs("Update signature verification failed.\n", stderr); exit(1) }
guard arguments.count == 4,
      let publicData = Data(base64Encoded: arguments[1]),
      let input = try? Data(contentsOf: URL(fileURLWithPath: arguments[2])),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicData) else { fail() }
let content: Data
let signature: Data
if arguments[3] == "--feed" {
    // Sparkle 2.9's signed-feed framing. The bytes before the final signing block are signed.
    let prefix = Data("<!-- sparkle-signatures:\n".utf8)
    guard let range = input.range(of: prefix, options: .backwards),
          let block = String(data: input[range.upperBound...], encoding: .utf8),
          let end = block.range(of: "-->"),
          block[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail() }
    content = input[..<range.lowerBound]
    let lines = block[..<end.lowerBound].split(separator: "\n")
    let signatures = lines.filter { $0.hasPrefix("edSignature:") }
    let lengths = lines.filter { $0.hasPrefix("length:") }
    guard signatures.count == 1, lengths.count == 1,
          let decoded = Data(base64Encoded: signatures[0].dropFirst("edSignature:".count).trimmingCharacters(in: .whitespaces)),
          Int(lengths[0].dropFirst("length:".count).trimmingCharacters(in: .whitespaces)) == content.count else { fail() }
    signature = decoded
} else {
    content = input
    guard let decoded = Data(base64Encoded: arguments[3]) else { fail() }
    signature = decoded
}
guard key.isValidSignature(signature, for: content) else { fail() }
print("Update signature verified.")
