import Foundation
import CryptoKit

// The release key: the app carries the public half and installs only what this private half signed.
// Used by Tools/release.command. Keep the key file outside the repository.
//
//   relkey keygen <key-file>          creates a key (refuses to overwrite) and prints its public half
//   relkey pub <key-file>             prints the public half
//   relkey sign <key-file> <file>     prints a base64 signature of the file
//   relkey verify <pub> <sig> <file>  exits 0 when the signature matches

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("读不到密钥：\(path)") }
    return key
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("用法：relkey keygen|pub|sign|verify …") }

switch command {
case "keygen":
    guard arguments.count == 2 else { fail("用法：relkey keygen <key-file>") }
    let path = arguments[1]
    if FileManager.default.fileExists(atPath: path) { fail("密钥已存在，不覆盖：\(path)") }
    let key = Curve25519.Signing.PrivateKey()
    let directory = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let data = Data(key.rawRepresentation.base64EncodedString().utf8)
    guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else { fail("写不了 \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "pub":
    guard arguments.count == 2 else { fail("用法：relkey pub <key-file>") }
    print(loadKey(arguments[1]).publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard arguments.count == 3 else { fail("用法：relkey sign <key-file> <file>") }
    guard let payload = FileManager.default.contents(atPath: arguments[2]) else { fail("读不到 \(arguments[2])") }
    guard let signature = try? loadKey(arguments[1]).signature(for: payload) else { fail("签名失败") }
    print(signature.base64EncodedString())

case "verify":
    guard arguments.count == 4 else { fail("用法：relkey verify <public-key> <signature> <file>") }
    guard let keyBytes = Data(base64Encoded: arguments[1]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else { fail("公钥不对") }
    guard let signature = Data(base64Encoded: arguments[2]) else { fail("签名不是 base64") }
    guard let payload = FileManager.default.contents(atPath: arguments[3]) else { fail("读不到 \(arguments[3])") }
    guard key.isValidSignature(signature, for: payload) else { fail("签名对不上") }
    print("ok")

default:
    fail("不认识的命令：\(command)")
}
