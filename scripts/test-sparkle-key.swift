import CryptoKit
import Foundation

struct TestFailure: Error {
    let message: String
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(message: message) }
}

func run(_ executable: URL, _ arguments: [String], input: String = "",
         environment: [String: String]? = nil) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    let stdin = Pipe()
    let output = Pipe()
    process.standardInput = stdin
    process.standardOutput = output
    process.standardError = output
    try process.run()
    try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
    try stdin.fileHandleForWriting.close()
    let data = try output.fileHandleForReading.readToEnd() ?? Data()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func test() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let signer = root.appendingPathComponent(".build/artifacts/sparkle/Sparkle/bin/sign_update")
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mergeport-key-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer {
        do { try FileManager.default.removeItem(at: directory) }
        catch { FileHandle.standardError.write(Data("Could not clean up key tests: \(error)\n".utf8)) }
    }
    let checker = directory.appendingPathComponent("verify-key")
    let compiled = try run(URL(fileURLWithPath: "/usr/bin/xcrun"),
                           ["swiftc", root.appendingPathComponent("scripts/verify-sparkle-key.swift").path,
                            "-o", checker.path])
    try require(compiled.status == 0, "Preflight compilation failed: \(compiled.output)")

    let key = Curve25519.Signing.PrivateKey()
    let other = Curve25519.Signing.PrivateKey()
    let encoded = key.rawRepresentation.base64EncodedString()
    let wrong = other.rawRepresentation.base64EncodedString()
    let pinned = directory.appendingPathComponent("pinned.plist")
    let bundle = directory.appendingPathComponent("bundle.plist")
    func writePlist(_ url: URL, publicKey: String?) throws {
        var plist = ["CFBundleVersion": "1.2.3"]
        plist["SUPublicEDKey"] = publicKey
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    try writePlist(pinned, publicKey: publicKey)
    try writePlist(bundle, publicKey: publicKey)
    let arguments = [signer.path, pinned.path, bundle.path]
    func check(_ input: String, succeeds: Bool, message: String) throws {
        let result = try run(checker, arguments, input: input)
        try require((result.status == 0) == succeeds && result.output.contains(message),
                    "Unexpected preflight result: \(result.output)")
        for secret in [encoded, wrong, input] where !secret.isEmpty {
            try require(!result.output.contains(secret), "Preflight output exposed private input.")
        }
    }
    try check(encoded, succeeds: true, message: "matches")
    try check(encoded + "\n", succeeds: true, message: "matches")
    try check(wrong, succeeds: false, message: "does not match")
    try check("", succeeds: false, message: "base64-encoded")
    try check("invalid-secret-do-not-log!", succeeds: false, message: "base64-encoded")
    try check(" " + encoded, succeeds: false, message: "base64-encoded")
    try check(Data(repeating: 0, count: 64).base64EncodedString(),
              succeeds: false, message: "base64-encoded")

    // Legacy Sparkle keys store the expanded Ed25519 secret followed by the public key.
    var expanded = Array(SHA512.hash(data: key.rawRepresentation))
    expanded[0] &= 248
    expanded[31] &= 63
    expanded[31] |= 64
    let legacy = (Data(expanded) + key.publicKey.rawRepresentation).base64EncodedString()
    try check(legacy, succeeds: true, message: "matches")
    let wrongLegacy = (Data(expanded) + other.publicKey.rawRepresentation).base64EncodedString()
    try check(wrongLegacy, succeeds: false, message: "does not match")
    try writePlist(bundle, publicKey: other.publicKey.rawRepresentation.base64EncodedString())
    try check(encoded, succeeds: false, message: "Bundle SUPublicEDKey differs")
    try writePlist(bundle, publicKey: publicKey)
    try writePlist(pinned, publicKey: nil)
    try check(encoded, succeeds: false, message: "Missing or invalid")
    try writePlist(pinned, publicKey: "not-a-public-key")
    try check(encoded, succeeds: false, message: "Missing or invalid")
    try writePlist(pinned, publicKey: publicKey)

    let failedSigner = try run(checker, ["/usr/bin/false", pinned.path, bundle.path], input: encoded)
    try require(failedSigner.status != 0 && failedSigner.output.contains("could not sign"),
                "Signer failures must fail preflight.")

    for folder in ["scripts", "Resources", "dist/Mergeport.app/Contents", "dist/release", "tools"] {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(folder),
                                                withIntermediateDirectories: true)
    }
    for file in ["sign-release.sh", "verify-sparkle-key.swift"] {
        try FileManager.default.copyItem(at: root.appendingPathComponent("scripts/\(file)"),
                                        to: directory.appendingPathComponent("scripts/\(file)"))
    }
    try writePlist(directory.appendingPathComponent("Resources/Info.plist"), publicKey: publicKey)
    try writePlist(directory.appendingPathComponent("dist/Mergeport.app/Contents/Info.plist"), publicKey: publicKey)
    try Data("unused archive fixture".utf8).write(to: directory.appendingPathComponent("dist/release/Mergeport-1.2.3.zip"))
    let tools = directory.appendingPathComponent("tools")
    try FileManager.default.createSymbolicLink(at: tools.appendingPathComponent("sign_update"),
                                               withDestinationURL: signer)
    let generator = tools.appendingPathComponent("generate_appcast")
    try Data("#!/bin/bash\nif [ -n \"${SPARKLE_PRIVATE_KEY+x}\" ] || [ -n \"${KEY+x}\" ]; then\n  echo SECRET_IN_ENVIRONMENT\n  exit 24\nfi\necho GENERATOR_REACHED\nexit 23\n".utf8).write(to: generator)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: generator.path)
    var environment = ProcessInfo.processInfo.environment
    environment["VERSION"] = "1.2.3"
    environment["KEY"] = "inherited-export-marker"
    for (secret, succeeds) in [(wrong, false), (encoded, true)] {
        environment["SPARKLE_PRIVATE_KEY"] = secret
        let result = try run(URL(fileURLWithPath: "/bin/bash"),
                             [directory.appendingPathComponent("scripts/sign-release.sh").path, tools.path],
                             environment: environment)
        try require(result.output.contains("GENERATOR_REACHED") == succeeds,
                    "Release wrapper failed to gate appcast generation: \(result.output)")
        try require(!result.output.contains("SECRET_IN_ENVIRONMENT") && !result.output.contains(secret),
                    "Release wrapper exposed the signing key.")
        try require(result.status == (succeeds ? 23 : 1), "Release wrapper lost the failure status.")
    }
    print("PASS: Sparkle preflight checks matching, mismatched, legacy and malformed keys; plist pins; signer failures; secret-safe output; and release gating.")
}

do { try test() }
catch {
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}
