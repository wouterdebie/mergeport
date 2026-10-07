import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("Usage: swift scripts/require-stopped-app.swift /path/to/Mergeport.app")
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
    .standardizedFileURL.resolvingSymlinksInPath()
for app in NSRunningApplication.runningApplications(withBundleIdentifier: "dev.wouter.mergeport") where !app.isTerminated {
    guard let bundleURL = app.bundleURL else {
        fail("Cannot locate running Mergeport process \(app.processIdentifier). Quit it before bundling.")
    }
    if bundleURL.standardizedFileURL.resolvingSymlinksInPath() == destination {
        fail("Refusing to replace running Mergeport (PID \(app.processIdentifier)) at \(destination.path). Quit it first, or run the installed copy in Applications instead.")
    }
}
