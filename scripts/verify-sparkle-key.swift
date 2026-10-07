import CryptoKit
import Foundation

struct PreflightError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func publicKey(in path: String) throws -> Data {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    guard let dictionary = plist as? [String: Any],
          let encoded = dictionary["SUPublicEDKey"] as? String,
          let key = Data(base64Encoded: encoded), key.count == 32 else {
        throw PreflightError(message: "Missing or invalid SUPublicEDKey in \(path).")
    }
    return key
}

func verify() throws {
    guard CommandLine.arguments.count == 4 else {
        throw PreflightError(message: "Usage: swift scripts/verify-sparkle-key.swift /path/to/sign_update pinned-Info.plist bundle-Info.plist < private-key")
    }
    let pinned = try publicKey(in: CommandLine.arguments[2])
    guard try publicKey(in: CommandLine.arguments[3]) == pinned else {
        throw PreflightError(message: "Bundle SUPublicEDKey differs from the repository pin. Refusing to sign.")
    }
    let input = try FileHandle.standardInput.readToEnd() ?? Data()
    guard var encoded = String(data: input, encoding: .utf8) else {
        throw PreflightError(message: "Signing key must be a single base64-encoded value on stdin.")
    }
    while encoded.hasSuffix("\n") || encoded.hasSuffix("\r") { encoded.removeLast() }
    guard let secret = Data(base64Encoded: encoded),
          [32, 96].contains(secret.count), secret.base64EncodedString() == encoded else {
        throw PreflightError(message: "Signing key must be a base64-encoded 32-byte seed or 96-byte legacy key.")
    }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mergeport-key-preflight-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer {
        do { try FileManager.default.removeItem(at: directory) }
        catch {
            FileHandle.standardError.write(Data("Could not remove preflight temporary files: \(error.localizedDescription)\n".utf8))
        }
    }
    let challenge = Data("Mergeport Sparkle signing-key preflight\n".utf8)
    let payload = directory.appendingPathComponent("challenge.bin")
    try challenge.write(to: payload)

    let signer = Process()
    signer.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
    signer.arguments = ["--ed-key-file", "-", "-p", payload.path]
    signer.currentDirectoryURL = directory
    signer.environment = ProcessInfo.processInfo.environment.filter { $0.key != "SPARKLE_PRIVATE_KEY" }
    let stdin = Pipe()
    let output = Pipe()
    signer.standardInput = stdin
    signer.standardOutput = output
    // Sparkle can echo malformed private keys in errors; never forward its output.
    signer.standardError = output
    try signer.run()
    try stdin.fileHandleForWriting.write(contentsOf: Data(encoded.utf8))
    try stdin.fileHandleForWriting.close()
    let result = try output.fileHandleForReading.readToEnd() ?? Data()
    signer.waitUntilExit()
    guard signer.terminationReason == .exit, signer.terminationStatus == 0,
          let text = String(data: result, encoding: .utf8),
          let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          signature.count == 64 else {
        throw PreflightError(message: "Sparkle could not sign the preflight payload. Check the supplied key and signing tool.")
    }
    let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: pinned)
    guard verifier.isValidSignature(signature, for: challenge) else {
        throw PreflightError(message: "Sparkle signing key does not match SUPublicEDKey. Refusing to sign; do not generate a replacement key.")
    }
    print("Sparkle signing key matches the pinned and bundled SUPublicEDKey.")
}

do { try verify() }
catch {
    FileHandle.standardError.write(Data("Sparkle key preflight failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
