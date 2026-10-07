import MergeportCore
import SwiftUI

struct GroupingSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var prefixes = ""
    @State private var suffixes = ""
    @State private var error: String?
    @State private var suffixError: String?
    @FocusState private var prefixesFocused: Bool
    @FocusState private var suffixesFocused: Bool

    var body: some View {
        Form {
            Section("Overview grouping") {
                Picker("Group by", selection: Binding(get: { model.groupingPreferences.mode }, set: { model.setGroupingMode($0) })) {
                    ForEach(PRGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Filters apply first. Source-branch groups stay within the same repository and source fork; ticket groups can span repositories.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Review tabs") {
                Picker("Group tabs by", selection: $model.tabGrouping) {
                    ForEach(TabGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Related tabs open next to each other and show the shared ticket, branch or repository once at the start of the group.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Reusable branch groups") {
                TextField("Branch suffixes", text: $suffixes, prompt: Text("-staging, -test"))
                    .focused($suffixesFocused)
                    .onSubmit(saveSuffixes)
                Text("In Branch groups mode, <branch>, <branch>-staging and <branch>-test share the same group. These rules automatically apply to new branches; no per-branch setup is needed.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Comma-separated, case-sensitive suffixes. Longer matches are removed first; chained suffixes are removed repeatedly. Leave empty for manual aliases only.")
                    .font(.caption).foregroundStyle(.secondary)
                if let suffixError { Text(suffixError).font(.caption).foregroundStyle(.orange) }
            }
            Section("Ticket identifiers") {
                TextField("Ticket prefixes", text: $prefixes, prompt: Text("CON-, ENG-"))
                    .focused($prefixesFocused)
                    .onSubmit(savePrefixes)
                Text("Comma-separated prefixes, followed by a ticket number. Source branches are checked before PR titles. IDs are case-insensitive; each PR appears once, under its first matching ID.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            Section("Branch group aliases") {
                Text("Optional overrides for exceptions to the reusable rules. Right-click a PR and choose Add source branch to group to attach it to another source branch.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.groupingPreferences.aliases.isEmpty {
                    Text("No branch aliases configured.").foregroundStyle(.secondary)
                }
                ForEach(model.groupingPreferences.aliases) { alias in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(alias.source.branch) → \(alias.target)").font(.caption.monospaced())
                            Text("\(alias.source.repository) · source: \(alias.source.sourceRepository)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            do { try model.removeBranchAlias(alias.source); error = nil }
                            catch { self.error = error.localizedDescription }
                        } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove branch alias")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            prefixes = model.groupingPreferences.ticketPrefixes.joined(separator: ", ")
            suffixes = model.groupingPreferences.branchSuffixes.joined(separator: ", ")
        }
        .onChange(of: prefixesFocused) { _, focused in if !focused { savePrefixes() } }
        .onChange(of: suffixesFocused) { _, focused in if !focused { saveSuffixes() } }
        .onDisappear { savePrefixes(); saveSuffixes() }
    }

    private func savePrefixes() {
        do {
            let normalized = try GroupingPreferences.prefixes(from: prefixes)
            if normalized != model.groupingPreferences.ticketPrefixes {
                var preferences = model.groupingPreferences
                preferences.ticketPrefixes = normalized
                try model.applyGrouping(preferences)
            }

            prefixes = normalized.joined(separator: ", ")
            error = nil
        } catch {
            self.error = error.localizedDescription
            NSLog("Mergeport grouping: %@", error.localizedDescription)
        }
    }

    private func saveSuffixes() {
        do {
            let normalized = try GroupingPreferences.suffixes(from: suffixes)
            if normalized != model.groupingPreferences.branchSuffixes {
                var preferences = model.groupingPreferences
                preferences.branchSuffixes = normalized
                try model.applyGrouping(preferences)
            }
            suffixes = normalized.joined(separator: ", ")
            suffixError = nil
        } catch {
            suffixError = error.localizedDescription
            NSLog("Mergeport grouping: %@", error.localizedDescription)
        }
    }
}

struct BranchGroupEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let pr: PullRequest
    @State private var target = ""
    @State private var error: String?

    private var choices: [String] {
        let identity = BranchIdentity(pr)
        return Set(model.pullRequests.filter {
            let other = BranchIdentity($0)
            return other.repository == identity.repository && other.sourceRepository == identity.sourceRepository && $0.head != pr.head
        }.map { model.canonicalBranch($0) }).filter { $0 != pr.head }.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add source branch to a group").font(.title2.bold())
            LabeledContent("Repository", value: pr.repository)
            LabeledContent("Source branch", value: pr.head)
            Text("Group all PRs from this source branch with the branch below. The mapping is saved and also applies to staging/main sibling links.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Canonical source branch", text: $target).textFieldStyle(.roundedBorder)
                Menu("Choose") {
                    ForEach(choices, id: \.self) { branch in Button(branch) { target = branch } }
                }.disabled(choices.isEmpty)
            }
            Text("Example: feature/foo-staging → feature/foo. The source fork and repository must stay the same.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if model.groupingPreferences.aliases.contains(where: { $0.source == BranchIdentity(pr) }) {
                    Button("Remove alias") {
                        do { try model.removeBranchAlias(BranchIdentity(pr)); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                Spacer()
                Button("Add to group") {
                    do { try model.attachBranch(pr, to: target); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 580)
        .onAppear {
            let existing = model.canonicalBranch(pr)
            if existing != pr.head { target = existing }
            else if pr.head.hasSuffix("-staging"), choices.contains(String(pr.head.dropLast(8))) { target = String(pr.head.dropLast(8)) }
            else { target = choices.first ?? "" }
        }
    }
}
