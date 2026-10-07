import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdates()

    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var error: String?
    @Published private(set) var started = false
    private var controller: SPUStandardUpdaterController?

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development build"
    }

    func start() {
        guard controller == nil else { return }
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains("--demo"), !arguments.contains("--smoke-test") else {
            error = "Updates are disabled in demo and test runs."
            return
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            error = "Run the bundled Mergeport.app to enable updates."
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        do {
            try controller.updater.start()
            controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
            controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticChecks)
            controller.updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastCheck)
            started = true
        } catch {
            self.error = "Could not start the updater: \(error.localizedDescription)"
        }
    }

    func check() {
        guard let controller, canCheck else { return }
        error = nil
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard let controller, started else {
            error = "The updater is not available in this build."
            return
        }
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let message: String?
        // Sparkle reports "no update" and user cancellation through this callback too.
        if let failure = error as NSError? {
            let expected = failure.domain == SUSparkleErrorDomain &&
                [Int(SUError.noUpdateError.rawValue), Int(SUError.installationCanceledError.rawValue)].contains(failure.code)
            message = expected ? nil : "Update check: \(failure.localizedDescription)"
        } else {
            message = nil
        }
        Task { @MainActor [weak self] in
            self?.error = message
        }
    }
}

struct UpdateSettingsSection: View {
    @ObservedObject var updates = AppUpdates.shared

    var body: some View {
        Section("Updates") {
            HStack {
                Text("Version \(updates.version)").foregroundStyle(.secondary)
                Spacer()
                Button("Check for Updates…") { updates.check() }.disabled(!updates.canCheck)
            }
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
                .disabled(!updates.started)
            Text("Checks GitHub once a day while the app is running. Downloads are signed and notarized; installation and restart require your approval.")
                .font(.caption).foregroundStyle(.secondary)
            if let lastCheck = updates.lastCheck {
                Text("Last checked \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = updates.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }
}

struct CheckForUpdatesCommand: View {
    @ObservedObject var updates = AppUpdates.shared

    var body: some View {
        Button("Check for Updates…") { updates.check() }.disabled(!updates.canCheck)
    }
}
