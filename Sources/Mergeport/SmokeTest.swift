import AppKit
import Foundation
import MergeportCore
import WebKit

@MainActor
enum SmokeTest {
  static func runIfRequested(model: AppModel) async {
    let args = ProcessInfo.processInfo.arguments
    guard let flag = args.firstIndex(of: "--smoke-test") else { return }
    do {
      guard model.isDemo, args.count > flag + 1 else {
        throw MergeportError.message("Use --demo --smoke-test /absolute/path/to/preview.png.")
      }
      NSApp.activate(ignoringOtherApps: true)
      try await Task.sleep(for: .seconds(1))
      guard let window = NSApp.windows.first(where: { $0.title == "Mergeport" && $0.isVisible }),
        let content = window.contentView, window.frame.width >= 980, window.frame.height >= 640
      else {
        throw MergeportError.message("The main window did not become visible.")
      }
      model.showOverview(scope: .mine)
      guard model.filteredPRs.count == 8 else { throw MergeportError.message("My PR filter failed.") }
      model.stageFilter = .ready
      guard model.filteredPRs.count == 3 else { throw MergeportError.message("Ready filter failed.") }
      model.showOverview(scope: .review)
      guard model.filteredPRs.count == 2 else {
        throw MergeportError.message("Review filter failed.")
      }
      model.showOverview(scope: .all)
      model.search = "workload"
      guard model.filteredPRs.count == 1 else {
        throw MergeportError.message("Search filter failed.")
      }
      model.search = ""
      if args.contains("--smoke-linear") {
        let state = LinearOAuth.verifier()
        let server = try LinearCallbackServer(state: state)
        async let code = server.code()
        try await Task.sleep(for: .milliseconds(200))
        let wrong = URL(string: LinearOAuth.redirectURI + "?code=x&state=forged")!
        _ = try? await URLSession(configuration: .ephemeral).data(from: wrong)
        do {
          _ = try await code
          throw MergeportError.message("Linear callback accepted a forged state.")
        } catch let error as MergeportError where error.localizedDescription.contains("unexpected state") {}
        let second = try LinearCallbackServer(state: state)
        async let accepted = second.code()
        try await Task.sleep(for: .milliseconds(200))
        let redirect = URL(string: LinearOAuth.redirectURI + "?code=abc123&state=\(state)")!
        let (page, _) = try await URLSession(configuration: .ephemeral).data(from: redirect)
        guard try await accepted == "abc123", String(decoding: page, as: UTF8.self).contains("connected") else {
          throw MergeportError.message("Linear loopback callback did not deliver the authorization code.")
        }
        guard let pr = model.pullRequests.first(where: { model.ticket(for: $0) == "CON-108" }),
          model.linearIssue(for: pr)?.title == "Email delivery via the Rust service"
        else { throw MergeportError.message("Linear issues are not matched to PR tickets.") }
        print("PASS: Linear loopback callback validates state and PRs resolve their Linear issues.")
      }
      if args.contains("--smoke-review-cache") {

        model.preloadReviews()
        let reviews = model.pullRequests.map {
          model.reviewModel(for: ReviewTab(pr: $0, location: $0.url))
        }
        for _ in 0..<100 {
          if reviews.allSatisfy({ $0.details != nil && !$0.isLoading }) { break }
          try await Task.sleep(for: .milliseconds(50))
        }
        guard reviews.allSatisfy({ $0.details != nil && !$0.diffs.isEmpty }),
          let cached = reviews.first
        else {
          throw MergeportError.message(
            "Background preloading did not populate every inbox review and its parsed diffs.")
        }
        model.open(cached.pr)
        guard let tab = model.activeTab, model.reviewModel(for: tab) === cached,
          cached.details != nil
        else {
          throw MergeportError.message(
            "Opening a preloaded PR did not immediately reuse its cached content.")
        }
        await cached.load(force: true)
        model.closeTab(tab.id)
        model.open(cached.pr)
        guard let reopened = model.activeTab, model.reviewModel(for: reopened) === cached else {
          throw MergeportError.message("Closing and reopening a tab discarded its cached content.")
        }
        await cached.load(force: true)
        model.closeTab(reopened.id)
        print(
          "PASS: every inbox review preloads; opening and reopening reuse cached details and parsed diffs."
        )
      }
      if args.contains("--smoke-grouping") {
        var preferences = GroupingPreferences()
        preferences.mode = .branchGroups
        try model.applyGrouping(preferences)
        guard
          let conflict = model.pullRequests.first(where: { $0.head == "feature/pubsub-staging" }),
          model.siblings(conflict).contains(where: { $0.head == "feature/pubsub" })
        else {
          throw MergeportError.message(
            "Reusable branch-group rules did not group the staging variant.")
        }
        preferences.mode = .branch
        try model.applyGrouping(preferences)
        guard let staging = model.pullRequests.first(where: { $0.head == "feature/pubsub-staging" })
        else {
          throw MergeportError.message("No conflict-branch grouping fixture.")
        }
        try model.attachBranch(staging, to: "feature/pubsub")
        guard model.siblings(staging).contains(where: { $0.head == "feature/pubsub" }) else {
          throw MergeportError.message("Branch aliases were not applied to sibling links.")
        }
        model.setGroupingMode(.ticket)
        guard case .success(let groups) = model.groupingResult,
          let ticket = groups.first(where: { $0.title == "CON-205" }),
          Set(ticket.pullRequests.map(\.repository)).count == 2,
          groups.flatMap(\.pullRequests).count == model.filteredPRs.count
        else {
          throw MergeportError.message(
            "Ticket grouping lost PRs or failed to group across repositories.")
        }
        guard let staging451 = model.pullRequests.first(where: { $0.number == 451 }),
          model.relatedPRs(staging451).map(\.number) == [452],
          let routing = model.pullRequests.first(where: { $0.number == 440 }),
          model.relatedPRs(routing).map(\.number) == [87]
        else {
          throw MergeportError.message("Related PRs should come from the source branch and the Linear ticket.")
        }
        let before = model.tabs.map(\.id)
        model.open(staging451)
        model.open(routing)
        guard let main452 = model.pullRequests.first(where: { $0.number == 452 }) else {
          throw MergeportError.message("No #452 fixture.")
        }
        model.open(main452)
        let opened = model.tabs.map(\.pr.number).filter { [451, 440, 452].contains($0) }
        guard opened == [451, 452, 440] else {
          throw MergeportError.message("Related tabs were not kept together: \(opened).")
        }
        let layout = model.tabLayout
        model.tabLayout = .sidebar
        try await Task.sleep(for: .milliseconds(300))
        model.closeGroup(of: staging451.id)
        guard !model.tabs.contains(where: { [451, 452].contains($0.pr.number) }),
          model.tabs.contains(where: { $0.pr.number == 440 })
        else {
          throw MergeportError.message("Close Group did not close exactly the related tabs.")
        }
        model.open(staging451)
        model.closeOtherTabs(staging451.id)
        guard model.tabs.map(\.pr.number) == [451], model.selectedTab == staging451.id else {
          throw MergeportError.message("Close Other Tabs left the wrong tabs: \(model.tabs.map(\.pr.number)).")
        }
        model.setGroupingMode(.ticket)
        guard case .success(let ticketGroups) = model.groupingResult,
          let routingGroup = ticketGroups.first(where: { $0.title == "CON-205" })
        else { throw MergeportError.message("No CON-205 group fixture.") }
        let selectedBefore = model.selectedTab
        let added = model.openAll(routingGroup.pullRequests)
        guard added == routingGroup.pullRequests.count, added == 2,
          model.unopened(routingGroup.pullRequests).isEmpty, model.selectedTab == selectedBefore,
          model.openAll(routingGroup.pullRequests) == 0
        else {
          throw MergeportError.message("Open all should open each group PR once and keep the current view.")
        }
        model.tabLayout = layout
        for tab in model.tabs where !before.contains(tab.id) { model.closeTab(tab.id) }
        model.selectTab(nil)
        guard let top = model.pullRequests.first(where: { $0.number == 457 }),
          let stack = top.stack, stack.blocker?.number == 456, top.stage == .attention,
          stack.needingReviewer.map(\.number) == [456], stack.readinessLabel == "2 of 3 ready",
          stack.mergedTogether(with: 457) == [455, 456, 457],
          let middle = stack.entries.first(where: { $0.number == 456 }),
          model.pullRequest(for: middle, stackOf: top).author == "sam",
          !model.relatedPRs(top).contains(where: { $0.stack != nil })
        else {
          throw MergeportError.message("The demo stack should wait on #456 and merge #455–#457 together.")
        }
        model.setGroupingMode(.stack)
        guard case .success(let stackGroups) = model.groupingResult,
          stackGroups.first(where: { $0.title == "Stack #7" })?.pullRequests.map(\.number) == [455, 457]
        else {
          throw MergeportError.message("Stack grouping did not order the stack's layers.")
        }
        model.setGroupingMode(.ticket)
        print(
          "PASS: reusable branch rules, explicit aliases, sibling links, related PRs, stacks, tab group actions, open all and cross-repository ticket grouping."
        )
      }
      if let expected = args.firstIndex(of: "--expect-bundled-client-id") {
        guard args.count > expected + 1 else {
          throw MergeportError.message("Expected client ID is missing.")
        }
        model.customClientID = ""
        guard model.oauthConfiguration.clientID == args[expected + 1] else {
          throw MergeportError.message("Bundled client ID is not used.")
        }
      }
      if args.contains("--smoke-native-review") {
        guard let pr = model.pullRequests.first(where: { $0.reviewRequested }) else {
          throw MergeportError.message("No review fixture.")
        }
        model.open(pr)
        guard let tab = model.activeTab else {
          throw MergeportError.message("Native review tab did not open.")
        }
        let review = model.reviewModel(for: tab)
        await review.load(force: true)
        guard let file = review.details?.files.first,
          case .available(let diff, true) = review.diffs[file.filename],
          let anchor = diff.lines.first(where: { $0.kind == .addition })?.anchor(
            path: file.filename)
        else {
          throw MergeportError.message("The native file diff did not load with valid line anchors.")
        }
        review.selectSection(.files)
        try review.addComment(anchor: anchor, body: "Local fixture comment")
        review.draft.discussion = "Local fixture discussion draft"
        model.selectTab(nil)
        model.selectTab(tab.id)
        guard model.reviewModel(for: tab) === review, review.draft.comments.count == 1 else {
          throw MergeportError.message("Switching tabs lost the native review draft.")
        }
        try await Task.sleep(for: .milliseconds(100))
        try closeTabUsingShortcut(window: window)
        try await Task.sleep(for: .milliseconds(100))
        guard model.tabToClose?.id == tab.id, model.tabs.contains(where: { $0.id == tab.id }) else {
          throw MergeportError.message(
            "Command-W draft confirmation failed: pending=\(model.tabToClose?.id ?? "nil"), tabExists=\(model.tabs.contains(where: { $0.id == tab.id })), windowVisible=\(window.isVisible)."
          )
        }
        model.tabToClose = nil
        review.draft = ReviewDraft()
        try await Task.sleep(for: .milliseconds(400))
        let metrics = review.diffLayoutMeasurements
        let widths = metrics.filter { $0.key.hasPrefix("row-") }.map(\.value)
        guard let viewport = metrics["viewport"], viewport > 0, !widths.isEmpty,
          widths.allSatisfy({ $0 >= viewport - 1 }),
          diff.lines.contains(where: { !$0.highlights.isEmpty })
        else {
          throw MergeportError.message(
            "Diff rows did not fill the viewport or replacement highlights were missing. Metrics: \(metrics)"
          )
        }
        print(
          "PASS: every rendered diff row fills the \(viewport)-point viewport; intraline spans are present."
        )
        print("PASS: native diff, line anchors, retained review drafts and close-tab confirmation.")
        try closeTabUsingShortcut(window: window)
        try await Task.sleep(for: .milliseconds(100))
        guard !model.tabs.contains(where: { $0.id == tab.id }), window.isVisible else {
          throw MergeportError.message(
            "Command-W did not close the review tab while preserving the window.")
        }
        model.selectTab(nil)
        try await Task.sleep(for: .milliseconds(100))
        try closeTabUsingShortcut(window: window)
        try await Task.sleep(for: .milliseconds(100))
        guard window.isVisible else {
          throw MergeportError.message("Command-W closed the window on Overview.")
        }
        model.open(pr)
        print("PASS: Command-W closes review tabs, confirms unsent drafts and keeps Overview open.")
      }
      if args.contains("--smoke-conversation") {
        guard let pr = model.pullRequests.first else {
          throw MergeportError.message("No conversation fixture.")
        }
        model.open(pr)
        guard let tab = model.activeTab else {
          throw MergeportError.message("Conversation tab did not open.")
        }
        let review = model.reviewModel(for: tab)
        await review.load(force: true)
        if let html = review.details?.bodyHTML {
          review.details?.bodyHTML = html + "<script>window.mergeportUntrustedScript = true;</script>"
        }
        review.selectSection(.conversation)
        try await Task.sleep(for: .seconds(1))
        let bodies = webViews(in: content)
        guard let body = bodies.first else {
          throw MergeportError.message("No HTML body rendered in Conversation.")
        }
        let table = try await evaluate(body, 
          "document.querySelectorAll('table tr').length")
        guard table.flatMap(Int.init) == 3,
          !body.configuration.websiteDataStore.isPersistent
        else {
          throw MergeportError.message(
            "Conversation HTML table count=\(String(describing: table)), url=\(String(describing: body.url)), persistent=\(body.configuration.websiteDataStore.isPersistent)."
          )
        }
        let originalHeight = body.frame.height
        let untrustedScript = try await evaluate(body, 
          "typeof window.mergeportUntrustedScript")
        guard untrustedScript == "undefined" else {
          throw MergeportError.message("Untrusted HTML scripts were not blocked.")
        }
        _ = try await evaluate(body, "document.querySelector('details').open = true")
        try await Task.sleep(for: .milliseconds(400))
        guard body.frame.height > originalHeight else {
          throw MergeportError.message(
            "Expanding HTML details did not resize its native comment card.")
        }
        guard body is ConversationWebView, let scrollView = body.enclosingScrollView,
          let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: -150, wheel2: 0, wheel3: 0),
          let event = NSEvent(cgEvent: wheel),
          let sideways = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                 wheel1: 0, wheel2: -150, wheel3: 0).flatMap(NSEvent.init(cgEvent:))
        else {
          throw MergeportError.message("Cannot exercise conversation scrolling over an HTML body.")
        }
        // Vertical gestures skip the body so AppKit hands them, momentum included, to the
        // timeline's own scroll view; horizontal ones still reach wide tables and code.
        guard ConversationWebView.leavesToConversation(event),
          !ConversationWebView.leavesToConversation(sideways)
        else {
          throw MergeportError.message("HTML bodies capture vertical scrolling or drop horizontal scrolling.")
        }
        let previousOffset = scrollView.contentView.bounds.origin.y
        scrollView.scrollWheel(with: event)
        try await Task.sleep(for: .milliseconds(300))
        guard scrollView.contentView.bounds.origin.y > previousOffset else {
          throw MergeportError.message("Scrolling over an HTML body did not move the conversation timeline.")
        }
        for _ in 0..<6 { scrollView.scrollWheel(with: event) }
        try await Task.sleep(for: .milliseconds(400))
        if let view = scrollView.window?.contentView,
          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        {
          view.cacheDisplay(in: view.bounds, to: bitmap)
          try bitmap.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: args[flag + 1].replacingOccurrences(of: ".png", with: "-scrolled.png")))
        }
        scrollView.contentView.scroll(to: .zero)
        var suggestion: String?
        for candidate in webViews(in: content) {
          suggestion = try await evaluate(candidate,
            "(() => { const row = document.querySelector('.blob-code-addition'); return row ? getComputedStyle(row).backgroundColor : null })()")
          if suggestion != nil { break }
        }
        guard let suggestion, suggestion != "rgba(0, 0, 0, 0)" else {
          throw MergeportError.message("Suggested changes did not render as a diff (\(String(describing: suggestion))).")
        }
        let tabID = tab.id
        try await Task.sleep(for: .milliseconds(200))
        model.goBack()
        try await Task.sleep(for: .milliseconds(200))
        guard model.selectedTab == nil, model.canGoForward else {
          throw MergeportError.message("Back did not return to Overview.")
        }
        model.goForward()
        try await Task.sleep(for: .milliseconds(200))
        guard model.selectedTab == tabID else {
          throw MergeportError.message("Forward did not return to the review tab.")
        }
        review.selectSection(.files)
        try await Task.sleep(for: .milliseconds(200))
        model.goBack()
        try await Task.sleep(for: .milliseconds(200))
        guard model.selectedTab == tabID, review.section == .conversation else {
          throw MergeportError.message("Back did not return to the Conversation section (\(review.section)).")
        }
        model.goForward()
        try await Task.sleep(for: .milliseconds(200))
        guard review.section == .files else {
          throw MergeportError.message("Forward did not return to Files changed (\(review.section)).")
        }
        review.selectSection(.conversation)
        try await Task.sleep(for: .milliseconds(200))
        model.selectAdjacentTab(1)
        let switched = model.selectedTab
        model.selectAdjacentTab(-1)
        guard switched != tabID, model.selectedTab == tabID else {
          throw MergeportError.message("Option-Command arrows did not cycle review tabs.")
        }
        try await Task.sleep(for: .milliseconds(200))
        print(
          "PASS: Conversation renders HTML tables and expandable details with automatic card height and isolated storage."
        )
        print("PASS: Review threads render suggested changes; back/forward navigate between Overview and tabs.")
      }
      if args.contains("--smoke-shortcuts") {
        model.showPalette = false
        model.selectTab(nil)
        model.searchFocusRequested = true
        try await Task.sleep(for: .milliseconds(300))
        try checkShortcuts(model: model, window: window)
        try await Task.sleep(for: .milliseconds(500))
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
          (editor.delegate as? NSTextField)?.placeholderString?.hasPrefix("Jump to") == true
        else { throw MergeportError.message("⌘K did not focus the palette field (\(String(describing: window.firstResponder))).") }
        func escape() -> NSEvent {
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        }
        guard AppDelegate.handlesEscape(escape()), !model.showPalette else {
          throw MergeportError.message("Esc did not close the palette.")
        }
        try await Task.sleep(for: .milliseconds(200))
        guard AppDelegate.handlesEscape(escape()) else {
          throw MergeportError.message("Esc on Overview falls through to the beeping responder chain.")
        }
        model.showPalette = true
        try await Task.sleep(for: .milliseconds(500))
        for code: UInt16 in [125, 125] {
          let arrow = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: String(UnicodeScalar(NSDownArrowFunctionKey)!), charactersIgnoringModifiers: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            isARepeat: false, keyCode: code)!
          window.sendEvent(arrow)
          try await Task.sleep(for: .milliseconds(150))
        }
        print("PASS: ⌘K palette, ⌘-letter sidebar shortcuts, ⌘0/⌘2…⌘9 tabs and no duplicate key equivalents.")
      }
      if args.contains("--smoke-file-tree") {
        guard let pr = model.pullRequests.first(where: { $0.reviewRequested }) else {
          throw MergeportError.message("No review fixture.")
        }
        model.open(pr)
        guard let tab = model.activeTab else { throw MergeportError.message("Review tab did not open.") }
        let review = model.reviewModel(for: tab)
        await review.load(force: true)
        review.selectSection(.files)
        let files = review.details?.files ?? []
        let names = FileTree.rows(for: files).map(\.name)
        guard names == ["services/routing", "src", "routing.ts", "tests", "routing.test.ts"],
          review.selectedFile == "services/routing/src/routing.ts"
        else { throw MergeportError.message("Changed files tree is wrong: \(names).") }
        review.collapsedFolders = ["services/routing/tests"]
        review.selectedFile = "services/routing/tests/routing.test.ts"
        guard review.collapsedFolders.isEmpty else {
          throw MergeportError.message("Selecting a file did not reveal it in the tree.")
        }
        review.selectedFile = "services/routing/src/routing.ts"
        try await Task.sleep(for: .milliseconds(300))
        print("PASS: Changed files render as a compressed, collapsible tree that reveals selected files.")
      }
      if args.contains("--smoke-status-panel") {
        let wasShowing = model.showStatusPanel
        model.resetDemoChanges()
        model.showStatusPanel = true
        try await Task.sleep(for: .milliseconds(600))
        guard let panel = StatusPanelController.shared.panel, panel.isVisible, panel.level == .floating,
          panel.collectionBehavior.contains(.canJoinAllSpaces), panel.styleMask.contains(.nonactivatingPanel),
          let panelContent = panel.contentView
        else {
          throw MergeportError.message("The status panel did not float on every Space.")
        }
        guard model.unseenChanges.count == DemoInbox.changes.count else {
          throw MergeportError.message("Status panel updates were not loaded.")
        }
        panelContent.layoutSubtreeIfNeeded()
        if let bitmap = panelContent.bitmapImageRepForCachingDisplay(in: panelContent.bounds) {
          panelContent.cacheDisplay(in: panelContent.bounds, to: bitmap)
          let path = args[flag + 1].replacingOccurrences(of: ".png", with: "-panel.png")
          try bitmap.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        }
        guard let changed = model.pullRequests.first(where: { model.unseenChanges[$0.id] != nil }) else {
          throw MergeportError.message("No status panel update to open.")
        }
        model.open(changed)
        guard model.unseenChanges[changed.id] == nil,
          model.unseenChanges.count == DemoInbox.changes.count - 1
        else {
          throw MergeportError.message("Opening a PR did not mark its update as seen.")
        }
        model.closeTab(changed.id)
        model.showStatusPanel = false
        try await Task.sleep(for: .milliseconds(200))
        guard !panel.isVisible else { throw MergeportError.message("The status panel did not hide.") }
        model.showStatusPanel = wasShowing
        let windowsBefore = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        StatusPanelController.shared.openSettings()
        try await Task.sleep(for: .milliseconds(800))
        guard let settings = NSApp.windows.first(where: {
          $0.isVisible && !windowsBefore.contains(ObjectIdentifier($0)) && !($0 is NSPanel)
        }) else {
          throw MergeportError.message("The menu bar Settings… item did not open Settings.")
        }
        settings.close()
        let logo = MergeportLogo.template(height: 64)
        if let tiff = logo.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
        {
          try png.write(to: URL(fileURLWithPath: args[flag + 1].replacingOccurrences(of: ".png", with: "-logo.png")))
        }
        print("PASS: Status panel floats on every Space, highlights updates and opening a PR marks it seen.")
      }
      guard let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
        NSImage(contentsOf: icon)?.isValid == true
      else {
        throw MergeportError.message("Bundled app icon is missing.")
      }
      try await Task.sleep(for: .milliseconds(400))
      content.layoutSubtreeIfNeeded()
      guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
        throw MergeportError.message("Cannot capture app preview.")
      }
      content.cacheDisplay(in: content.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw MergeportError.message("Cannot encode app preview.")
      }
      try png.write(to: URL(fileURLWithPath: args[flag + 1]), options: .withoutOverwriting)
      print("PASS: native window, inbox filters and bundled icon.")
      print("Preview: \(args[flag + 1])")
      if args.contains("--smoke-hold") { try await Task.sleep(for: .seconds(5)) }
      NSApp.terminate(nil)
    } catch {
      FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  /// WebKit suspends JavaScript in occluded windows; time out instead of hanging the smoke test.
  private static func evaluate(_ webView: WKWebView, _ script: String) async throws -> String? {
    try await withCheckedThrowingContinuation { continuation in
      var finished = false
      webView.evaluateJavaScript(script) { result, error in
        guard !finished else { return }
        finished = true
        if let error { continuation.resume(throwing: error) } else {
          continuation.resume(returning: result.map { "\($0)" })
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
        guard !finished else { return }
        finished = true
        continuation.resume(
          throwing: MergeportError.message(
            "Web view JavaScript timed out; keep the smoke-test window visible."))
      }
    }
  }

  private static func webViews(in view: NSView) -> [WKWebView] {
    if let webView = view as? WKWebView { return [webView] }
    return view.subviews.flatMap { webViews(in: $0) }
  }

  private static func checkShortcuts(model: AppModel, window: NSWindow) throws {
    guard let menu = NSApp.mainMenu else { throw MergeportError.message("No main menu.") }
    menu.update()
    var seen: [String: String] = [:]
    func walk(_ menu: NSMenu) throws {
      for item in menu.items {
        if let submenu = item.submenu, submenu != NSApp.servicesMenu { try walk(submenu) }
        guard !item.keyEquivalent.isEmpty, !item.isHidden else { continue }
        let key = "\(item.keyEquivalentModifierMask.rawValue)-\(item.keyEquivalent)"
        if let other = seen[key] {
          throw MergeportError.message("“\(item.title)” and “\(other)” share ⌘\(item.keyEquivalent).")
        }
        seen[key] = item.title
      }
    }
    try walk(menu)
    func press(_ key: String) throws {
      guard let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)
      else { throw MergeportError.message("Cannot create ⌘\(key).") }
      menu.update()
      guard menu.performKeyEquivalent(with: event) else { throw MergeportError.message("⌘\(key) is not bound.") }
    }
    for destination in SidebarDestination.allCases {
      model.selectTab(nil)
      model.showOverview(scope: .mine, stage: .draft, repository: "x")
      try press(String(destination.key))
      guard model.stageFilter == destination.stage, model.repositoryFilter == nil,
        destination.scope == nil || model.scope == destination.scope
      else { throw MergeportError.message("\(destination.keyLabel) did not show \(destination.title).") }
    }
    for pr in model.pullRequests.prefix(3) { model.open(pr) }
    model.selectTab(number: 2)
    guard model.selectedTab == model.tabs.first?.id else { throw MergeportError.message("⌘2 did not select tab 1.") }
    model.selectTab(number: 9)
    guard model.selectedTab == model.tabs.last?.id else { throw MergeportError.message("⌘9 did not select the last tab.") }
    model.selectTab(number: 8)
    guard model.selectedTab == model.tabs.last?.id else { throw MergeportError.message("⌘8 changed a missing tab.") }
    try press("1")
    guard model.selectedTab == nil else { throw MergeportError.message("⌘1 did not show Overview.") }
    try press("k")
    guard model.showPalette else { throw MergeportError.message("⌘K did not open the palette.") }
    model.showShortcutHints = true
  }

  private static func closeTabUsingShortcut(window: NSWindow) throws {
    window.makeKeyAndOrderFront(nil)
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "w", charactersIgnoringModifiers: "w",
        isARepeat: false, keyCode: 13
      ), let menu = NSApp.mainMenu
    else {
      throw MergeportError.message("Cannot create the Command-W menu shortcut test.")
    }
    menu.update()
    _ = menu.performKeyEquivalent(with: event)
  }
}
