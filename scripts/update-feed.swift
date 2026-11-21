import CryptoKit
import Foundation

// The key file is exactly 32 random bytes and stays on the release machine.
let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 1 || args.count == 5 else {
    fatalError("Usage: swift scripts/update-feed.swift KEY [VERSION BUILD ZIP_URL SHA256]")
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: URL(fileURLWithPath: args[0])))
if args.count == 1 {
    print(key.publicKey.rawRepresentation.base64EncodedString())
} else {
    let payload = Data(args.dropFirst().joined(separator: "|").utf8)
    let signature = try key.signature(for: payload)
    let feed = ["version": args[1], "build": args[2], "url": args[3], "sha256": args[4],
                "signature": signature.base64EncodedString()]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: feed, options: [.sortedKeys, .prettyPrinted]))
}
