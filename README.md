# Mergeport

A native macOS home for GitHub pull requests, built with SwiftUI and AppKit.
Inspired by Davit and Don't Miss: a cross-repo overview with persistent native
review tabs and **one browser-based GitHub login**.

## Features

Conversation uses a chronological, GitHub-style timeline: description and comment
cards, reviews, commits, review requests, draft/ready changes, references and other
events returned by GitHub's paginated timeline API. Bodies use GitHub-rendered
HTML for tables, code blocks, images and collapsible details, in isolated web
views without an additional login. Links retain normal PR navigation.
Avatars come from GitHub's API (including bots such as Copilot, shown as
"Copilot" with an AI badge); people are round and bots square, as on GitHub.
Overview rows show the PR author's avatar.
Cross-references are grouped ("This was referenced") with Open/Draft/Merged/Closed
pills. Adjacent review requests (and request removals) from the same person within
one minute are combined into one timeline row listing all reviewers. Different
actors, request types and intervening activity stay separate.
The merge box mirrors GitHub's: review, checks and conflict rows with status
icons and a merge button. The header actions are Ready for review / Convert to
draft, Review changes, and Ready to merge. The conversation is limited to
GitHub's page width; on wide windows a sidebar shows reviewers (with
pending/approved/changes-requested state), assignees, labels, milestone and
participants, notifications and conversation locking. As on GitHub, gears open
pickers: reviewers (suggested reviewers, assignable users and Copilot; ↻
re-requests a review from someone who already reviewed), assignees (or "assign
yourself"), labels and milestone. Editing assignees, labels and the milestone
requires triage access. Projects and linked issues are not editable: they need
an extra OAuth scope or have no public API.
Vertical scrolling over HTML bodies scrolls the conversation; wide tables and
code blocks retain horizontal scrolling. A merge status summary sits above the
discussion composer. GitHub-only features such as
reaction controls and Copilot session widgets are not reproduced.

The inbox appears first, then PR reviews preload in the background with at most
two background loads at a time. Opening or selecting a review tab immediately
shows its last fetched content while refreshing it, with a visible refresh
indicator. Cached reviews are kept in memory for the current app session.

- **Personal inbox**: your open PRs and requested reviews across repositories,
  including team requests. Follow `owner/repository` entries to include every
  open PR in those repos. Overview cards and review headers lead with
  `#<PR number>`, the ticket, `owner/repository` and the target branch, without
  digit separators. Cards are sorted by repository, then PR number; groups keep
  the most recently active first.
- **Workflow**: Draft, Your review, Needs attention, Waiting, and Ready to merge.
  Filter by ownership, workflow, repository, title, PR number or branch.
- **Branch siblings**: staging/main PRs from the same feature branch and source
  repository are linked; different forks are not conflated. Explicit branch
  aliases let conflict branches such as `feature/foo-staging` join the same
  family as `feature/foo`.
- **Related PRs**: the review sidebar lists PRs from the same source branch
  and PRs for the same Linear ticket (across repositories); click one to open it.
- **Stacks**: GitHub's native stacked PRs show a layer chip (`2/3`, green when
  every layer is ready) and a stack map in the review sidebar: top layer first,
  trunk at the bottom, each layer with its status (approved, needs review, no
  reviewer, checks, conflicts, needs rebase). GitHub only merges a layer once it
  and every open PR below it meet the trunk's rules, so Mergeport flags layers
  nobody was asked to review (Needs attention), copies this PR's reviewers and
  teams to them in one click, points to GitHub's Rebase stack when the stack
  isn't linear, and only enables "Merge N PRs" when the whole stack below can
  land. Merging uses GitHub's asynchronous merge. Stack is also an overview
  and tab grouping.
- **Grouped tabs**: tabs fill the tab bar and shrink like Chrome's as more
  open: the title goes first, then the target branch, until only the PR number
  is left (beyond that the bar scrolls). New tabs open next to related tabs;
  each group shows its ticket, branch or repository once. Choose what tabs are
  grouped by in Settings › Grouping › Review tabs (default: ticket or source
  branch). Click anywhere on a tab to select it.
- **Tabs in the sidebar**: Settings › General › Review tabs (or View › Show
  Tabs in Sidebar) moves open PRs into an "Open" section above the inbox:
  one row per PR with its status, target branch and what it's waiting on,
  grouped like the tab bar, with collapsible groups and sidebar sections.
  Choose **Sidebar shows › Full inbox** to list every inbox PR without opening
  them all. Overview filters do not change this list. Clicking a PR opens its
  review; the larger × button closes only the review, leaving its inbox entry
  available. Open reviews that leave the inbox remain listed until closed.
  The default remains **Open tabs**; the choice is saved across launches.
  Full-inbox groups sort by the selected tab grouping (ticket IDs use natural
  numeric order), with stable repository/PR ordering within each group.
  Activity and sync order no longer move the rows; PRs without a grouping key
  appear last.
- **Open all**: open every PR in the current overview view (after filters and
  search), or every PR in one group, as tabs without leaving the overview. PRs
  that are already open are skipped; more than 10 asks first.
- **Tab cleanup**: optionally close tabs automatically when their PR merges or
  closes (right away or after a day; the tab you're on and tabs with unsent
  drafts stay). Right-click a tab or group to close the tab, its group, other
  tabs, or all merged and closed tabs.
- **Grouping**: repository, source branch, reusable branch groups, ticket
  identifier, GitHub stack, or an ungrouped list. Configurable suffix rules group ephemeral
  `<branch>`, `<branch>-staging` and `<branch>-test` branches without creating
  manual aliases. Ticket prefixes such as `CON-` and `ENG-` are configurable;
  ticket groups can span repositories. Filters apply before grouping.
- **Linear**: connect Linear in Settings to show issue titles and workflow
  states for ticket identifiers in ticket groups and PR headers. The ticket chip
  on cards and PRs opens the Linear issue. Read-only OAuth (PKCE) access.
- **Status**: latest-commit checks (a spinning pill while running, then passed
  or failed; review tabs show counts and the overview polls every 30 seconds
  while any checks run), GitHub review decision, unresolved threads
  and Copilot review/request status. Reviews on older commits are marked
  outdated. Prominent Copilot badges distinguish reviewed, pending, outdated,
  no review and unknown states. Pending does not claim Copilot has started.
- **Native reviews**: descriptions, discussion comments, submitted reviews,
  threaded replies and resolve/reopen controls; a collapsible changed-files
  tree (single-child folders compressed, ↑/↓ to move between files) with
  full-panel-width unified diffs and old/new line numbers; changed characters
  within replacement lines get stronger red/green highlights; checks and
  commit history.
- **Review submission**: draft inline comments by clicking a diff line number,
  then submit them together with a comment, approval or request for changes.
  Deleted lines use GitHub's LEFT side; added/context lines use RIGHT.
- **PR actions**: mark ready for review, convert to draft and merge using the
  repository's permitted squash/merge/rebase methods. The split merge button
  merges in one click with the method chosen in its menu (remembered per
  repository); draft changes apply immediately. Tabs and Overview cards show
  the new status (merged, waiting) as soon as GitHub accepts an action. GitHub
  enforces permissions and branch rules.
- **Draft safety**: unsent review summaries, inline comments, discussion
  comments and thread replies survive relaunch. Tab switching keeps local
  drafts; closing a tab with drafts requires confirmation. New commits make
  old inline-review drafts stale rather than silently moving their anchors.
- **OAuth**: authorize Mergeport in your normal browser with your existing GitHub
  login/password manager. The token lives in Keychain and authenticates both
  the overview and native reviews. There is no embedded GitHub page or second
  browser login.
- **Refresh**: configurable active polling, refresh on returning to the
  overview and explicit per-review refresh. Successful actions reload PR data.
  The sidebar shows the last successful sync time and automatic refresh cadence
  or paused state, rather than a running age timer.
  Errors are visible; failed reads retain last-known data rather than showing
  an empty inbox.
- **Status panel**: an optional always-on-top panel (View → Show Status
  Panel, ⌥⌘P) lists your PRs and review requests by lane: your review, needs
  attention, ready to merge, waiting and draft. It stays visible on every
  Space and over full-screen apps, and never takes focus. Since your last
  look, new updates are highlighted: review requested, approved, changes
  requested, conflicts, failed checks, ready to merge, Copilot finished, new
  threads. Click a row to open it in Mergeport; ⌥-click opens it on GitHub.
  A menu bar item shows how many PRs need you and toggles the panel;
  right-click it for more options. Settings → General → Status panel offers a
  filter, a global ⌃⌥⌘P hotkey, fading while idle and hiding while Mergeport
  is in front. While the panel is visible, polling continues after the main
  window is closed or in the background.
- **Preview**: sample inbox and interactive native review drafts without any
  GitHub requests or writes.

## Build and run

Requires macOS 14+ and Swift 6+ (Xcode). The only dependency is
[Sparkle](https://sparkle-project.org) 2.10.0 (pinned in `Package.resolved`).

```sh
swift test
bash scripts/bundle.sh
open dist/Mergeport.app
```

For a native review preview:

```sh
open dist/Mergeport.app --args --demo --demo-review
# Or: swift run Mergeport --demo --demo-review
```

Quit Mergeport before rebuilding, then reopen `dist/Mergeport.app`. The bundler
reuses that path after building and verifying the replacement, retaining the
previous bundle in a hidden staging directory for recovery. Login and app
preferences are preserved. `APP_OUTPUT` optionally selects another output path.
The bundler signs with your first Apple Development certificate so the Keychain
"Always Allow" grant survives rebuilds; it falls back to ad-hoc signing (which
re-prompts after every build) when none exists. Supply `CODESIGN_IDENTITY` to
choose a certificate (`-` for ad-hoc; CI always signs ad-hoc). This is not a
notarized release. `VERSION` overrides the version from `Info.plist` and
`BUILD_ARCH=arm64` limits the architecture. The bundler embeds
`Sparkle.framework` and refuses to replace a running copy. The app icon (an anchor
whose arms end in commit nodes) is drawn in [Resources/AppIcon.svg](Resources/AppIcon.svg);
after editing it, run [scripts/generate-icon.sh](scripts/generate-icon.sh) (needs
`brew install librsvg`) to regenerate the checked-in `AppIcon.png` and `AppIcon.icns`.

Builds use Xcode 27 (CI runs on the `xcode-27` runner label). Xcode 27's
`swift build` otherwise records the deployment target as the SDK version, which
makes AppKit drop the macOS 26+ window design, so the bundler links with
`-isysroot` explicitly. Verify a bundle with
`vtool -show-build dist/Mergeport.app/Contents/MacOS/Mergeport`: `sdk` must be
27.0 or later, not 14.0; CI checks this.

## Connect GitHub (users)

1. Click **Connect GitHub**. Your normal browser opens GitHub's device
   authorization page, so your existing GitHub session and password manager
   work normally.
2. Enter Mergeport's displayed code and authorize the app. Mergeport completes
   authorization automatically and brings the app back to the foreground.
3. Approve any organization/SSO access required for private repositories.
4. Open a PR and review it natively. **No second web login is needed.**

Scopes are `repo`, `read:org` and `notifications` (for subscribing to a PR).
Mergeport uses repository write access only for actions you explicitly request:
comments, reviews, thread resolution, draft changes, reviewers, assignees,
labels, milestones, conversation locks and merging. Accounts connected before
`notifications` was added must reconnect once to subscribe/unsubscribe. No password or browser cookie is copied into the app;
the OAuth token is used only with GitHub's API.

Users do not register OAuth apps or enter client IDs. An unconfigured build
reports that overview sign-in is unavailable; native sample reviews still work.

Signing out removes the local token, cached PRs, tabs and local drafts. It also
clears legacy Mergeport web cookies from the earlier embedded-browser prototype.
To revoke authorization on GitHub too, remove Mergeport from
[Authorized OAuth Apps](https://github.com/settings/applications).

## Register the shared integration (developer, once)

The standard build includes Mergeport's registered public OAuth client ID.
The steps below are for replacing that integration or configuring a fork;
normal users only need **Connect GitHub**.

1. [Register a GitHub OAuth app](https://github.com/settings/applications/new)
   under the account or organization owning Mergeport, named **Mergeport**.
2. Set the homepage to Mergeport's website (`https://github.com` is fine during
   development), and callback to `http://localhost`. Device flow does not use
   this callback.
3. Save the app, then enable **Device Flow**.
4. Copy its public **Client ID**, not a client secret.
5. Build a configured app and quit any older running copy before opening it:

   ```sh
   GITHUB_OAUTH_CLIENT_ID="YOUR_PUBLIC_CLIENT_ID" \
   APP_OUTPUT="$PWD/dist/Mergeport-configured.app" \
   bash scripts/bundle.sh
   open dist/Mergeport-configured.app
   ```

The bundler embeds the public ID in the signed app's `Info.plist`. Every user
authorizes the same integration with their own account. No authentication
server or client secret is needed.

For a persistent build default, set `MergeportGitHubClientID` in
[Resources/Info.plist](Resources/Info.plist). The public ID can be checked in;
user tokens and client secrets cannot. The build environment variable overrides
this default.

**Settings > Advanced > Custom client ID** remains available for developers and
forks. Leave it empty for the bundled integration; sign out before changing it.
Old prototype client IDs are preserved as custom overrides. `swift run` has no
app-bundle configuration, so use that advanced option when developing sign-in.

## Register the Linear integration (developer, once)

1. In a Linear workspace you administer, open
   [Settings > API > OAuth applications](https://linear.app/settings/api/applications/new)
   and create an app named **Mergeport**.
2. Add the callback URL `http://127.0.0.1:47389/linear/callback`. Mergeport
   listens there only while you connect, on the loopback interface.
3. Copy the public **Client ID**. Mergeport uses PKCE and never needs the
   client secret.
4. Set `MergeportLinearClientID` in [Resources/Info.plist](Resources/Info.plist),
   or bundle with `LINEAR_OAUTH_CLIENT_ID="…" bash scripts/bundle.sh`.

Users then choose **Settings > General > Linear > Connect Linear…**, approve in
the browser and return to Mergeport. Tokens (refreshed automatically every 24
hours) are stored in Keychain; **Disconnect Linear** revokes and removes them.

## Review and workflow semantics

### Grouping configuration

Use the overview's **Group by** picker to select Repository, Source branch,
Branch groups, Ticket identifier or No grouping. The adjacent sliders button opens grouping
configuration, also available in **Settings > Grouping**.

Enter comma-separated ticket prefixes (`CON-, ENG-`). Valid changes save on
Enter or when the field loses focus; invalid input keeps the previous saved
value and displays an error. Prefixes are
case-insensitive and normalized with a trailing hyphen. A matching ticket
number in the canonical source branch is preferred, then the actual branch,
then the PR title. Each PR appears once, under its first match. PRs without an
ID stay visible under **No ticket identifier**.

Choose **Branch groups** to use reusable family rules. In Settings > Grouping,
set **Branch suffixes**, defaulting to `-staging, -test`. For every current or
future branch, these suffixes are removed to find the family:
`feature/foo`, `feature/foo-staging` and `feature/foo-test` all become
`feature/foo`. This mode stays scoped to the same repository and source fork.
Suffixes are case-sensitive; longer matches are preferred and chained suffixes
are removed repeatedly. Empty suffix settings disable these rules. **Source
branch** mode does not apply suffix rules.

Suffix edits also save on Enter/blur, without a save button. Existing saved
configuration gains the default rules but retains its previous grouping mode.

To add a conflict branch, right-click its PR and select **Add source branch to
group**, then choose/type the original source branch. Aliases stay scoped to
the same target repository and source fork; cycles/self-aliases are rejected.
The mapping is an optional override, also updates staging/main sibling links
and can supply a ticket ID through its canonical branch. Suffixes are only
automatically stripped when Branch groups mode is selected.
Remove mappings in Settings > Grouping or the same branch-group editor.
Grouping mode, prefixes and aliases are saved between launches.

Within-line highlights compare paired deletion/addition lines using grapheme
offsets, without changing comment line anchors. Large generated/minified
replacement regions use bounded, coarser highlighting, noted in the diff view.

Drafts stay Draft even if checks pass. Non-draft review requests stay Your review
even with failing checks. Other PRs with requested changes, conflicts, failing
checks or unresolved threads need attention. Unresolved threads started by
Copilot are shown as findings but don't block Ready to merge; if the repository
requires resolved conversations, GitHub's own verdict still holds the PR back.

Merge eligibility requires GitHub's `CLEAN` or `UNSTABLE` policy verdict, known
mergeability and approved/not-required reviews. `UNSTABLE` means GitHub allows
merging despite non-passing optional checks; `BLOCKED` still prevents merging,
including when mandatory approvals or required checks are missing. Failed
checks remain prominent in Needs attention and the checks list even when Merge
is enabled. An approval alone is not enough. Merge requests include the exact loaded head SHA; GitHub rejects a
changed head or unmet policies. Review submission also checks the current head
and includes the reviewed commit ID. A failed network submission is not retried
automatically: check GitHub before retrying if the outcome is uncertain.

PRs with merge conflicts show the conflicting file paths in the conversation's
merge box, without any option to resolve them. GitHub does not provide those
paths through its API, so opening a conflicting PR runs read-only analysis of
its exact base and head commits using macOS Git (`merge-tree`, Git 2.38 or newer).
Repositories are fetched into an isolated bare cache under the app's cache
directory; no working checkout, branch or index is changed. History is fetched
without a shallow cutoff and file contents download as needed, so the first
analysis of a large repository can take longer. Credentials are supplied only
to the Git process, never saved in remote URLs or configuration. Analysis
failures appear explicitly with a retry button; resolve conflicts on GitHub or
in your normal checkout.

All open means personal queues plus followed repositories, not every accessible
repository. PR lists, comments, reviews, thread replies, checks and file lists
are paginated. Search exceeding GitHub's 1,000-result limit fails explicitly.
GitHub's 3,000-file and 250-commit API limits are displayed if encountered.
Missing/binary/truncated patches are clearly marked, with an external-browser
fallback. In Files changed, expand hidden context above or below hunks in
20-line chunks, or expand the whole gap between hunks. Content loads on demand
from the reviewed head commit and is cached until the head commit or patch changes. Expanded
lines are read-only context; inline comments remain anchored to the original
patch. Binary, oversized and incomplete diffs retain the GitHub fallback.
Copilot history beyond the latest 100 reviews is marked unknown if
no Copilot review was found in that window.

Existing pending reviews created elsewhere are displayed; finish those in your
normal browser before starting a new native review. Native inline comments are
single-line; multiline ranges, suggestions, reactions and rich GitHub Markdown
parity are not yet implemented. The **Open in browser** button in each PR's
header opens its actual GitHub URL using your normal browser session, not an
embedded browser. It is disabled for fictional sample PRs.

### Keyboard shortcuts

Hold **Command** to see shortcut hints next to sidebar items and tabs
(turn this off in Settings → General → Keyboard).

| Shortcut | Action |
| --- | --- |
| ⌘K | Quick open: jump to a PR (number, ticket, title, repository, branch, author, Linear title), a view, a repository or a Linear issue. ↑/↓ select, ↩ opens, ⌘↩ opens the PR on GitHub, Esc closes |
| ⌘1 (or ⌘0) | Overview |
| ⌘2 … ⌘8 | Review tab 1 … 7 |
| ⌘9 | Last review tab |
| ⌥⌘← / ⌥⌘→ | Previous / next tab |
| ⌘O / ⌘P / ⌘I | All open / My pull requests / Review requested |
| ⌘D / ⌘N / ⌘Y / ⌘T / ⌘G | Draft / Needs attention / Your review / Waiting / Ready to merge |
| ⌘F | Search |
| ⇧⌘R / ⌘R | Refresh overview / reload current view |
| ⌘W | Close the active review tab (confirms unsent drafts; no action on Overview) |
| ⌥⌘P | Show / hide the status panel |
| ⌃⌥⌘P | Show / hide the status panel from any app (opt-in global hotkey) |
| ⌘← / ⌘→ or ⌘[ / ⌘] | Back / forward (also the toolbar arrows and mouse buttons; text fields keep ⌘-arrows) |

Sidebar letters skip standard macOS keys (⌘A select all, ⌘M minimize,
⌘W close, ⌘R reload, ⌘F find). Shortcuts are fixed, not configurable.

## Releases and updates

Mergeport updates itself with Sparkle from
`https://github.com/wouterdebie/mergeport/releases/latest/download/appcast.xml`.
It checks once a day (Settings → General → Updates, or **Mergeport → Check for
Updates…**); installing always asks first. Updates are off in `--demo` and
smoke runs.

[ci.yml](.github/workflows/ci.yml) runs on every push to `main` and on PRs, on
the `xcode-27` (macOS 27) runner with Xcode 27.0. It tests, lints the scripts,
checks the Sparkle key preflight, builds an arm64 bundle (checking that the SDK
matches), builds and checks the DMG, and round-trips the artifact.

To release, bump `CFBundleShortVersionString` in
[Info.plist](Resources/Info.plist), merge to `main`, then tag:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

[release.yml](.github/workflows/release.yml) then:

1. Checks that the tag is `vX.Y.Z` and on `main`.
2. Tests and builds unsigned on one runner.
3. On a second runner, signs with the pinned Developer ID certificate (shared
   with Davit and Don't Miss).
4. Notarizes and staples the app.
5. Builds, signs and notarizes `Mergeport.dmg`.
6. Writes and signs the Sparkle `appcast.xml`.
7. Publishes the release with the DMG, the update ZIP, their checksums and
   the appcast.

Required repository secrets (the same values as Don't Miss):
`SPARKLE_PRIVATE_KEY` (matches `SUPublicEDKey`), `MACOS_CERT_P12`,
`MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID` and
`APPLE_APP_SPECIFIC_PASSWORD`.

The drag-to-Applications DMG is built from a prebuilt Finder layout in
[Resources/dmg](Resources/dmg) (see its README for how to regenerate it).

## Website

[mergeport.app](https://mergeport.app) is a static page in [site/](site), served
from Google Cloud Storage through a load balancer, like Don't Miss and Davit.
See [site/README.md](site/README.md) to deploy or provision it.

## Validation and current boundaries

One GitHub.com account is supported. Enterprise hosts, PR creation,
notifications, automatic draft promotion and background Copilot automation are
not implemented. Statuses are refreshed
snapshots, not a live event stream.

Unit tests use local HTTP fixtures, not your GitHub account or Keychain.
The opt-in native smoke test checks inbox filters, diff anchors, retained
drafts and close-tab confirmation, captures the app and quits:

```sh
dist/Mergeport.app/Contents/MacOS/Mergeport --demo \
  --smoke-test /tmp/mergeport-native-preview.png --smoke-native-review
```

`--expect-bundled-client-id CLIENT_ID` additionally verifies build configuration.
`--smoke-grouping` checks conflict-branch aliases and cross-repo ticket groups.
`--smoke-file-tree` checks the changed-files tree and leaves Files changed in the capture.
`--smoke-diff-context` with `--smoke-native-review` checks on-demand context
expansion, rendered line numbers, comment anchors and same-commit refreshes.
`--smoke-merge-policy` with `--smoke-native-review` checks optional-failure
warnings alongside merge eligibility, and mandatory approval and policy blocks.
`--smoke-conflicts` with `--smoke-native-review` checks the read-only conflicting
file list, disabled Merge, and clearing paths when conflicts disappear.
`--smoke-sidebar-inbox` checks full-inbox listing, closing an open review
without losing its inbox entry, draft protection and the 30-point close button.
`--smoke-shortcuts` checks every sidebar shortcut, tab numbers, ⌘K and that no two
menu items share a key equivalent.
`--smoke-linear` checks the Linear loopback callback (state validation) and
ticket-to-issue matching with sample Linear issues.
Native-review smoke tests also measure every rendered row against the actual
diff viewport width and check that within-line highlight spans are present.
The native preview is local and never submits sample comments or reviews.
