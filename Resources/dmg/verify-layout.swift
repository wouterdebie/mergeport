import Foundation
import CoreFoundation

func require(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw NSError(domain: "DMGLayout", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
}

do {
    try require(CommandLine.arguments.count == 2, "Usage: verify-layout.swift MOUNT_PATH")
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let data = try Data(contentsOf: root.appendingPathComponent(".DS_Store"))
    func number(at offset: Int) -> UInt32 {
        data[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }
    func blob(_ key: String) throws -> Data {
        let marker = Data((key + "blob").utf8)
        guard let range = data.range(of: marker) else {
            throw NSError(domain: "DMGLayout", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing Finder record: \(key)"])
        }
        let offset = range.upperBound
        try require(offset + 4 <= data.count, "Truncated Finder record")
        let length = Int(number(at: offset))
        try require(offset + 4 + length <= data.count, "Invalid Finder record length")
        return data.subdata(in: offset + 4..<offset + 4 + length)
    }
    func plist(_ key: String) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: blob(key), format: nil)
        guard let dictionary = object as? [String: Any] else {
            throw NSError(domain: "DMGLayout", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid Finder plist"])
        }
        return dictionary
    }
    let window = try plist("bwsp")
    let view = try plist("icvp")
    try require(window["ShowToolbar"] as? Bool == false, "Toolbar must be hidden")
    try require(window["ShowStatusBar"] as? Bool == false, "Status bar must be hidden")
    try require(window["ShowSidebar"] as? Bool == false, "Sidebar must be hidden")
    try require((window["WindowBounds"] as? String)?.contains("{600, 392}") == true,
                "Unexpected Finder window dimensions")
    try require(view["iconSize"] as? Double == 96, "Unexpected icon size")
    try require(view["textSize"] as? Double == 13, "Unexpected label size")
    try require(view["arrangeBy"] as? String == "none", "Icons must use manual placement")
    try require(view["labelOnBottom"] as? Bool == true, "Labels must be below icons")
    try require(view["backgroundType"] as? Int == 2, "Finder background must be an image")

    for (name, x) in [("Mergeport.app", 150), ("Applications", 450)] {
        var marker = Data(name.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] })
        marker.append(Data("Ilocblob".utf8))
        guard let range = data.range(of: marker) else {
            throw NSError(domain: "DMGLayout", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing icon position for \(name)"])
        }
        let offset = range.upperBound
        try require(offset + 20 <= data.count && number(at: offset) == 16,
                    "Invalid icon position record")
        try require(number(at: offset + 4) == x && number(at: offset + 8) == 185,
                    "Incorrect icon position for \(name)")
    }

    guard let alias = view["backgroundImageAlias"] as? Data,
          let bookmark = CFURLCreateBookmarkDataFromAliasRecord(kCFAllocatorDefault, alias as CFData) else {
        throw NSError(domain: "DMGLayout", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Missing background alias"])
    }
    var stale = false
    let background = try URL(resolvingBookmarkData: bookmark.takeRetainedValue() as Data,
                             options: [.withoutUI, .withoutMounting],
                             relativeTo: root, bookmarkDataIsStale: &stale)
    let expected = root.appendingPathComponent(".background/background.tiff")
    if background.resolvingSymlinksInPath().path != expected.resolvingSymlinksInPath().path {
        // Two images made from the same template share a filesystem identity.
        // Finder may resolve the alias through the first mounted instance.
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey]
        let actualResource = try background.resourceValues(forKeys: keys)
        let expectedResource = try expected.resourceValues(forKeys: keys)
        let actualFile = try FileManager.default.attributesOfItem(atPath: background.path)
        let expectedFile = try FileManager.default.attributesOfItem(atPath: expected.path)
        try require(actualResource.volumeUUIDString != nil &&
                    actualResource.volumeUUIDString == expectedResource.volumeUUIDString &&
                    actualFile[.systemFileNumber] as? UInt64 == expectedFile[.systemFileNumber] as? UInt64 &&
                    background.path.hasSuffix("/.background/background.tiff") &&
                    (try Data(contentsOf: background)) == (try Data(contentsOf: expected)),
                    "Finder background alias does not resolve to this template's background")
    }
    print("Finder layout verified: 600×392 window, app left, Applications right, background resolves.")
} catch {
    fputs("DMG layout validation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
