import AppKit
import MergeportCore
import SwiftUI

enum SettingsTab: Hashable {
    case general, repositories, grouping, advanced
}

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            YardMark(size: 88)
            VStack(spacing: 10) {
                Text("Give your pull requests a home.").font(.system(size: 30, weight: .bold))
                Text("Across repos. Through reviews. From draft to merge.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 28) {
                feature("tray.full", "One overview", "Your PRs and review requests\nacross every repository.")
                feature("arrow.triangle.branch", "Your workflow", "Copilot, feedback, checks\nand staging / main siblings.")
                feature("rectangle.stack", "Keep your place", "Native reviews and local drafts\nthat stay open between sessions.")
            }.padding(.vertical, 12)
            Button("Connect GitHub") { model.showConnection = true }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isSigningOut)
            Button("Explore with sample data") { model.preview() }.buttonStyle(.link)
            Text("Native overview and reviews. One browser-based login. Credentials in Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }

    private func feature(_ icon: String, _ title: String, _ description: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint)
            Text(title).font(.headline)
            Text(description).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(width: 190)
    }
}

struct ConnectionView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                YardMark(size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connect GitHub").font(.title2.bold())
                    Text("One login in your normal browser").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if model.oauthConfiguration.clientID == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Label("GitHub sign-in is unavailable in this build", systemImage: "exclamationmark.triangle")
                        .font(.headline).foregroundStyle(.orange)
                    Text("Use a configured Mergeport build. You do not need to register your own GitHub app.")
                        .font(.callout)
                    Button("Open Advanced Settings") {
                        model.settingsTab = .advanced
                        dismiss()
                        openSettings()
                    }
                    Text("Developers and forks can configure a custom OAuth app there.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text("Authorize Mergeport to show your pull requests and review requests across repositories. Choose your GitHub account in the browser, then enter the code below.")
                    .font(.callout)
                if model.oauthConfiguration.usesCustomApp {
                    Label("Using the custom OAuth app from Advanced settings", systemImage: "wrench.and.screwdriver")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Permissions: repo, read:org and notifications, including private repositories. Mergeport reads PRs and submits comments, reviews, draft changes, sidebar edits and merges only when you request them.")
                .font(.caption).foregroundStyle(.secondary)
            if let code = model.deviceCode {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Enter this code on GitHub").font(.headline)
                    HStack {
                        Text(code.userCode).font(.system(size: 26, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code.userCode, forType: .string)
                        }
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                    Button("Open authorization page") { model.openExternal(code.verificationURI) }
                    Text("Waiting for authorization. The code expires in \(code.expiresIn / 60) minutes.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            if model.isSigningIn && model.deviceCode == nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Opening GitHub sign-in…").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            Text("Use your existing GitHub browser session and password manager. Native reviews use the OAuth connection directly; there is no second in-app web login.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { model.cancelSignIn(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.isSigningIn {
                    Button("Cancel sign-in") { model.cancelSignIn() }
                } else {
                    Button("Continue with GitHub") { model.signIn() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.oauthConfiguration.clientID == nil || model.isSigningOut)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }.padding(28).frame(width: 530)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if model.oauthConfiguration.clientID != nil { model.signIn() }
        }
    }
}

struct RepositorySettings: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Follow repositories").font(.title2.bold())
            Text("Your own PRs and requested reviews are found automatically. Follow repositories to include all their open PRs, including staging/main siblings and other authors.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("owner/repository", text: $input).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add", action: add).disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            List {
                ForEach(model.repositories, id: \.self) { repository in
                    HStack {
                        Label(repository, systemImage: "shippingbox")
                        Spacer()
                        Button {
                            model.removeRepository(repository)
                            Task { await model.refresh() }
                        } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Unfollow repository")
                    }
                }
            }.overlay {
                if model.repositories.isEmpty { Text("No followed repositories yet").foregroundStyle(.secondary) }
            }
            Text("Private organization repositories may need SSO authorization for your OAuth app. Repository access errors are shown rather than silently hiding PRs.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
    }

    private func add() {
        do {
            try model.addRepository(input)
            input = ""
            error = nil
            Task { await model.refresh() }
        } catch { self.error = error.localizedDescription }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(AppModel.shortcutHintsKey) private var shortcutHints = true
    @State private var confirmSignOut = false
    @State private var showConnection = false

    var body: some View {
        TabView(selection: $model.settingsTab) {
            Form {
                Section("GitHub account") {
                    LabeledContent("Account", value: model.accountStatus)
                    if model.isConnected {
                        Button("Sign out…", role: .destructive) { confirmSignOut = true }
                            .disabled(model.isSigningOut || model.hasRunningMutations)
                    } else {
                        Button("Connect GitHub…") { showConnection = true }.disabled(model.isSigningOut)
                        if model.isDemo { Button("Leave sample workspace") { model.leavePreview() } }
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
                Section("Linear") {
                    if model.isLinearConnected {
                        LabeledContent("Workspace", value: model.linearViewer.map { "\($0.workspace) · \($0.name)" } ?? "Connected")
                        LabeledContent("Linked issues", value: "\(model.linearIssues.count)")
                        Button("Disconnect Linear", role: .destructive) { model.disconnectLinear() }
                    } else if model.isConnectingLinear {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Waiting for Linear authorization in your browser…").foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { model.cancelLinearConnect() }
                        }
                    } else {
                        Button("Connect Linear…") { model.connectLinear() }
                            .disabled(model.linearClientID == nil || model.isDemo)
                    }
                    if let error = model.linearError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    Text(model.linearClientID == nil
                         ? "Linear sign-in is not configured in this build. Set MergeportLinearClientID in Info.plist or LINEAR_OAUTH_CLIENT_ID when bundling."
                         : "Shows Linear issue titles for ticket identifiers (Grouping › ticket prefixes) and opens issues from PRs. Read-only access; tokens are kept in Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Refresh") {
                    Picker("Refresh while active", selection: $model.refreshInterval) {
                        Text("Every minute").tag(60)
                        Text("Every 2 minutes").tag(120)
                        Text("Every 5 minutes").tag(300)
                        Text("Every 10 minutes").tag(600)
                    }
                    Text("Also refreshes when you return to the overview. Last-known data remains visible if a refresh fails.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Keyboard") {
                    Toggle("Show shortcut hints while holding ⌘", isOn: $shortcutHints)
                    Text("Shows ⌘-letter keys next to sidebar items and ⌘-number keys on tabs. Every shortcut also stays listed in the Go menu, and ⌘K opens quick open.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                UpdateSettingsSection()
                Section("Review tabs") {
                    Picker("Show tabs in", selection: $model.tabLayout) {
                        ForEach(TabLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    Text("Sidebar lists open PRs above the inbox with their status, grouped like the tab bar; groups collapse. The top bar keeps Chrome-style tabs.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Close merged and closed tabs", selection: $model.tabAutoClose) {
                        ForEach(TabAutoClose.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("Only tabs that merged or closed while open. The tab you're on and tabs with unsent drafts stay open. Right-click a tab to close its group, other tabs, or all merged and closed tabs.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Reviews are native and use your OAuth account. Open tabs, selected sections and unsent review/discussion/reply drafts are restored when the app starts. No embedded-browser login is needed.")
                        .font(.callout).foregroundStyle(.secondary)
                    Link("Manage authorized OAuth apps", destination: URL(string: "https://github.com/settings/applications")!)
                }
                Section("Status panel") {
                    Toggle("Show the status panel (⌥⌘P)", isOn: $model.showStatusPanel)
                    Text("A small always-on-top panel with your pull requests by lane, visible on every Space. Updates since you last opened a PR are highlighted. Click a PR to open it here, ⌥-click to open it on GitHub.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Show in the menu bar", isOn: $model.showMenuBarItem)
                    Text("Shows how many PRs need you: requested reviews, and your PRs that need attention or are ready to merge. Click to toggle the panel; right-click for more.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Toggle the panel from anywhere with ⌃⌥⌘P", isOn: $model.panelHotKey)
                    Toggle("Fade the panel when the pointer isn't over it", isOn: $model.panelFadesWhenIdle)
                    Toggle("Hide the panel while Mergeport is in front", isOn: $model.panelHidesWithApp)
                }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            RepositorySettings().padding(22).tabItem { Label("Repositories", systemImage: "shippingbox") }
                .tag(SettingsTab.repositories)
            GroupingSettingsView().tabItem { Label("Grouping", systemImage: "rectangle.3.group") }.tag(SettingsTab.grouping)
            Form {
                Section("Custom OAuth app") {
                    Text("For developers and forks only. Normal users connect through Mergeport's bundled GitHub integration.")
                        .font(.callout).foregroundStyle(.secondary)
                    LabeledContent("Bundled integration", value:
                        GitHubOAuthConfiguration(bundledClientID: model.bundledClientID).clientID == nil ? "Not configured" : "Configured")
                    TextField("Custom client ID", text: $model.customClientID)
                        .disabled(model.isSigningIn || model.isConnected || model.isSigningOut)
                    Text("Leave empty to use the bundled integration. Enter a public Client ID, never a client secret. Custom apps must have Device Flow enabled.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.customClientID.isEmpty {
                        Button("Use bundled integration") { model.customClientID = "" }
                            .disabled(model.isSigningIn || model.isConnected || model.isSigningOut)
                    }
                    if model.isConnected {
                        Text("Sign out before changing the OAuth app.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Link("Register a custom OAuth app", destination: URL(string: "https://github.com/settings/applications/new")!)
                }
            }.formStyle(.grouped).tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.advanced)
        }
        .frame(width: 610, height: 540)
        .onChange(of: model.refreshInterval) { model.savePreferences() }
        .onChange(of: model.customClientID) { model.savePreferences() }
        .sheet(isPresented: $showConnection, onDismiss: { if model.isSigningIn { model.cancelSignIn() } }) {
            ConnectionView().environmentObject(model)
        }
        .onChange(of: model.isConnected) { _, connected in if connected { showConnection = false } }
        .confirmationDialog("Sign out of Mergeport?", isPresented: $confirmSignOut) {
            Button("Sign out", role: .destructive) { Task { await model.signOut() } }
        } message: {
            Text("Removes the local OAuth token, cached PRs, tabs and unsent drafts. Any web cookies from older Mergeport versions are also cleared. To revoke GitHub authorization too, remove Mergeport from your authorized OAuth apps.")
        }
    }
}
