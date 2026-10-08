import MergeportCore
import SwiftUI

private struct DiffLayoutKey: PreferenceKey {
  static let defaultValue: [String: CGFloat] = [:]
  static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

private struct CommentTarget: Identifiable {
  let anchor: DiffAnchor
  var id: String { "\(anchor.path):\(anchor.side.rawValue):\(anchor.line)" }
}

struct NativeReviewView: View {
  @EnvironmentObject var app: AppModel
  let tab: ReviewTab
  @ObservedObject var review: ReviewModel
  @State private var confirmClearDraft = false
  @State private var commentTarget: CommentTarget?
  @State private var conversationWidth: CGFloat = 0
  @State private var sidebarLeading: CGFloat = 0
  @State private var activePicker: SidebarPicker?
  @State private var confirmLock = false
  @State private var scrollTarget: String?
  @State private var checksExpanded = true

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if review.isLoading { ProgressView().progressViewStyle(.linear).frame(height: 2) }
      if let error = review.error { message(error, color: .orange) }
      if let notice = review.notice { message(notice, color: .green) }
      if review.draftIsStale {
        message(
          "New commits were pushed. Pending review comments refer to an earlier commit; clear and re-add them before submitting.",
          color: .orange)
      }
      if let details = review.details {
        ForEach(details.notices, id: \.self) { message($0, color: .blue) }
        // Narrower windows first drop tab titles, then move the actions to their own row.
        ViewThatFits(in: .horizontal) {
          sectionRow(details, compact: false)
          sectionRow(details, compact: true)
          VStack(alignment: .trailing, spacing: 8) {
            ReviewActionBar(review: review)
            HStack {
              ReviewSectionTabs(review: review, details: details, compact: false)
              Spacer(minLength: 0)
            }
          }
        }.padding(.horizontal, 14).padding(.top, 10)
        Divider()
        switch review.section {
        case .files: files(details)
        case .conversation: conversation(details)
        case .checks: checks(details)
        case .commits: commits(details)
        }
      } else if review.isLoading {
        ProgressView("Loading PR review").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView(
          "Could not load this review", systemImage: "exclamationmark.triangle",
          description: Text("Connect GitHub and check repository access, then refresh.")
        )
        .fixedSize(horizontal: false, vertical: true).padding(.top, 24)
        Spacer()
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .task(id: review.reference.id) {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        if review.hasRunningChecks { await review.refreshChecks() }
      }
    }
    .onChange(of: tab.location) {
      review.section = ReviewSection(rawValue: tab.location.lastPathComponent) ?? .conversation
    }
    .sheet(isPresented: $review.isComposingReview) { reviewSheet }
    .sheet(item: $commentTarget) { target in
      InlineCommentSheet(review: review, anchor: target.anchor)
    }
    .confirmationDialog(
      "Discard the pending review summary and inline comments?", isPresented: $confirmClearDraft
    ) {
      Button("Discard review draft", role: .destructive) { review.clearReviewDraft() }
    } message: {
      Text(
        "Discussion comments and thread replies are kept. Submitted GitHub comments are not changed."
      )
    }
    .environment(
      \.openURL,
      OpenURLAction { url in
        if let target = conversationTarget(url) {
          review.selectSection(.conversation)
          scrollTarget = target
        } else if GitHubNavigation.pullRequestIdentity(url) != nil {
          app.openLinkedPR(url)
        } else {
          app.openExternal(url)
        }
        return .handled
      })
  }

  /// GitHub's "author wants to merge N commits into base from head", with the target branch emphasized.
  private var branchLine: some View {
    let count = review.details?.commits.count
    return HStack(spacing: 6) {
      Text(ReviewDetails.displayName(review.pr.author)).fontWeight(.semibold)
      Text(count.map { "wants to merge \($0) commit\($0 == 1 ? "" : "s") into" } ?? "wants to merge into")
        .foregroundStyle(.secondary)
      Text(review.pr.base).font(.callout.monospaced().weight(.semibold)).foregroundStyle(Color.branchBlue)
      Text("from").foregroundStyle(.secondary)
      Text(review.pr.head).font(.callout.monospaced()).foregroundStyle(Color.branchBlue.opacity(0.85))
        .lineLimit(1).truncationMode(.middle)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.branchBlue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(review.pr.head, forType: .string)
      } label: {
        Image(systemName: "doc.on.doc")
      }.buttonStyle(.plain).foregroundStyle(.secondary).help("Copy branch name")
    }.font(.callout).lineLimit(1)
  }

  /// Identity, the title, who/where, the Linear issue, then a strip of statuses.
  /// The actions sit next to the section picker (`ReviewActionBar`).
  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      keyFacts
      Text(review.pr.title).font(.system(size: 22, weight: .bold)).lineLimit(2)
        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      branchLine
      if let issue = app.linearIssue(for: review.pr) {
        LinearIssueLine(issue: issue) { app.openExternal(issue.url) }
      }
      HStack(spacing: 8) {
        statusStrip
        Spacer(minLength: 12)
        if review.draft.hasReviewContent {
          Text("\(review.draft.comments.count) pending inline comments").font(.caption)
            .foregroundStyle(.secondary)
          Button("Clear review draft") { confirmClearDraft = true }.font(.caption).disabled(
            review.isPerforming)
        }
      }.padding(.top, 2)
    }.padding(18)
  }

  private var keyFacts: some View {
    PRKeyFacts(
      pr: review.pr, ticket: app.ticket(for: review.pr), issue: app.linearIssue(for: review.pr),
      large: true, openIssue: { app.openExternal($0) })
  }

  private var statusStrip: some View {
    HStack(spacing: 8) {
      HStack(spacing: 6) {
        Text("+\(review.pr.additions)").foregroundStyle(.green)
        Text("−\(review.pr.deletions)").foregroundStyle(.red)
        if let sha = review.details?.headSHA {
          Text(String(sha.prefix(7))).foregroundStyle(.secondary).font(.caption.monospaced())
            .help("Head commit \(sha)")
        }
      }
      .font(.system(size: 12, weight: .semibold).monospacedDigit())
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12)))
      .help("Lines added and removed")
      Button { review.selectSection(.checks) } label: {
        ChecksStatusBadge(state: review.pr.checks, summary: review.details?.checkSummary)
      }
      .buttonStyle(.plain)
      CopilotStatusBadge(state: review.pr.copilot)
      mergeStatusPill
    }.fixedSize()
  }

  /// Where the PR stands in the workflow, styled like the Copilot pill next to it.
  private var mergeStatusPill: some View {
    let pr = review.pr
    let (title, symbol, color): (String, String, Color) =
      pr.state == "OPEN"
      ? (pr.stage.title, pr.stage.symbol, YardPalette.color(pr.stage))
      : (pr.state == "MERGED" ? "Merged" : "Closed", YardPalette.status(pr).symbol, YardPalette.status(pr).color)
    return Label(title, systemImage: symbol)
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(0.4)))
      .help(pr.state == "OPEN" ? pr.waitingReason : title)
  }

  private func sectionRow(_ details: ReviewDetails, compact: Bool) -> some View {
    HStack(alignment: .center) {
      ReviewSectionTabs(review: review, details: details, compact: compact)
      Spacer(minLength: 12)
      ReviewActionBar(review: review).padding(.bottom, 4)
    }
  }

  private func message(_ text: String, color: Color) -> some View {
    HStack {
      Text(text).font(.callout).textSelection(.enabled)
      Spacer()
    }.padding(10).background(color.opacity(0.1))
  }

  private func files(_ details: ReviewDetails) -> some View {
    HSplitView {
      ChangedFilesTree(review: review, files: details.files)
        .frame(minWidth: 210, idealWidth: 260, maxWidth: 420)
      VStack(alignment: .leading, spacing: 0) {
        if let file = review.file {
          VStack(alignment: .leading, spacing: 4) {
            Text(file.filename).font(.headline).textSelection(.enabled)
            if let previous = file.previousFilename {
              Text("Renamed from \(previous)").font(.caption).foregroundStyle(.secondary)
            }
            Text(
              "Click a line number to draft an inline comment. Comments are posted together when you submit the review."
            )
            .font(.caption).foregroundStyle(.secondary)
          }.padding(14)
          Divider()
          switch review.diffs[file.filename] {
          case .available(let diff, let complete):
            if let error = review.contextErrors[file.filename] {
              message("Context expansion unavailable: \(error)", color: .orange)
            }
            if !complete {
              message(
                "GitHub's patch is incomplete. Open GitHub for the entire file before approving.",
                color: .orange)
            }
            if diff.lines.contains(where: \.coarseHighlights) {
              message(
                "Very long replacement lines use coarser within-line highlights.", color: .blue)
            }
            GeometryReader { viewport in
              ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                  if let context = review.diffContexts[file.filename] {
                    ForEach(context.rows) { row in
                      switch row {
                      case .line(let line): diffRow(line, path: file.filename)
                      case .gap(let gap): contextGap(gap, path: file.filename)
                      }
                    }
                  } else {
                    ForEach(diff.lines) { line in diffRow(line, path: file.filename) }
                  }
                }.frame(minWidth: viewport.size.width, alignment: .leading).padding(.vertical, 6)
              }
              .background {
                Color.clear.preference(
                  key: DiffLayoutKey.self, value: ["viewport": viewport.size.width])
              }
            }
            .onPreferenceChange(DiffLayoutKey.self) { values in
              if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                review.diffLayoutMeasurements = values
              }
            }
          case .unavailable(let reason):
            Text(reason).foregroundStyle(.secondary).padding(20)
            Button("Open files on GitHub") {
              if let url = URL(string: review.pr.url.absoluteString + "/files") {
                app.openExternal(url)
              }
            }.padding(.horizontal, 20).disabled(review.isDemo)
            Spacer()
          case nil:
            Text("Choose a file").foregroundStyle(.secondary).padding(20)
            Spacer()
          }
        } else {
          ContentUnavailableView(
            "Choose a changed file", systemImage: "doc",
            description: Text("Outdated threads can refer to paths no longer present in this diff.")
          )
        }
      }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private func contextGap(_ gap: DiffContextGap, path: String) -> some View {
    HStack(spacing: 12) {
      if review.loadingContext.contains(path) {
        ProgressView().controlSize(.small)
      } else {
        if gap.canExpandUp {
          Button { Task { await review.expandContext(path: path, gap: gap.id, direction: .up) } } label: {
            Label("Expand up", systemImage: "arrow.up")
          }.help("Show up to 20 lines above the next hunk")
        }
        if gap.canExpandDown {
          Button { Task { await review.expandContext(path: path, gap: gap.id, direction: .down) } } label: {
            Label("Expand down", systemImage: "arrow.down")
          }.help("Show up to 20 lines below the previous hunk")
        }
        if gap.canExpandUp && gap.canExpandDown {
          Button("Expand all") {
            Task { await review.expandContext(path: path, gap: gap.id, direction: .all) }
          }
        }
      }
      Text(gap.count.map { "\($0) hidden lines" } ?? "More context")
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .font(.caption).buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.blue.opacity(0.08))
  }

  private func diffRow(_ line: DiffLine, path: String) -> some View {
    HStack(alignment: .top, spacing: 0) {
      Button {
        if let anchor = line.anchor(path: path) { commentTarget = CommentTarget(anchor: anchor) }
      } label: {
        HStack(spacing: 0) {
          Text(line.oldLine.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
          Text(line.newLine.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
          Image(systemName: "plus.bubble").font(.system(size: 9)).frame(width: 24)
            .opacity(line.anchor(path: path) == nil ? 0 : 1)
        }.foregroundStyle(.secondary).padding(.trailing, 8)
          .frame(maxHeight: .infinity).background(DiffColors.gutter(line.kind))
      }.buttonStyle(.plain).disabled(
        line.anchor(path: path) == nil || review.draftIsStale || review.isPerforming)
      Text(line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " ").frame(width: 16)
        .padding(.vertical, 3)
      Text(intralineText(line)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
        .padding(.trailing, 16).padding(.vertical, 3)
      Spacer(minLength: 0)
    }
    .font(.system(size: 12, design: .monospaced))
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DiffColors.code(line.kind))
    .background {
      if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
        GeometryReader { geometry in
          Color.clear.preference(
            key: DiffLayoutKey.self, value: ["row-\(line.id)": geometry.size.width])
        }
      }
    }
  }

  private func intralineText(_ line: DiffLine) -> AttributedString {
    var text = AttributedString(line.text)
    for span in line.highlights {
      let start = text.characters.index(text.characters.startIndex, offsetBy: span.lowerBound)
      let end = text.characters.index(text.characters.startIndex, offsetBy: span.upperBound)
      text[start..<end].backgroundColor =
        line.kind == .addition ? Color.green.opacity(0.32) : Color.red.opacity(0.32)
    }
    return text
  }

  /// The conversation row for a `#discussion_r<id>` link, such as Copilot's finding links.
  private func conversationTarget(_ url: URL) -> String? {
    guard let fragment = url.fragment, fragment.hasPrefix("discussion_r"),
      let id = Int(fragment.dropFirst("discussion_r".count)),
      let details = review.details,
      let thread = details.threads.first(where: { $0.comments.contains { $0.databaseID == id } })
    else { return nil }
    if let reviewID = thread.reviewID,
      details.reviews.contains(where: { $0.id == reviewID && $0.state != "PENDING" })
    {
      return ConversationItem.review(details.reviews.first { $0.id == reviewID }!).id
    }
    return ConversationItem.thread(thread).id
  }

  private func conversation(_ details: ReviewDetails) -> some View {
    ScrollViewReader { proxy in
    ScrollView {
      HStack(alignment: .top, spacing: 32) {
      // Eager on purpose: a lazy stack tears down each comment's web view when it scrolls
      // off screen and rebuilds it on the way back, which made scrolling stutter.
      VStack(alignment: .leading, spacing: 18) {
        timelineRow(author: review.pr.author, symbol: "text.bubble") {
          conversationCard(
            author: review.pr.author, action: "opened this pull request", date: details.createdAt
          ) {
            RenderedBody(
              text: details.body.isEmpty ? "No description." : details.body, html: details.bodyHTML)
          }
        }
        ForEach(details.conversation) { item in
          switch item {
          case .comment(let comment):
            timelineRow(author: comment.author, symbol: "text.bubble") {
              conversationCard(author: comment.author, action: "commented", date: comment.date) {
                RenderedBody(text: comment.body, html: comment.bodyHTML)
              }
            }
          case .review(let submitted):
            timelineRow(
              author: nil, symbol: reviewSymbol(submitted.state), tint: reviewTint(submitted.state)
            ) {
              VStack(alignment: .leading, spacing: 10) {
                eventLine(
                  author: submitted.author, action: reviewAction(submitted.state),
                  date: submitted.date)
                if !submitted.body.isEmpty {
                  conversationCard(author: submitted.author, action: "left a comment", date: nil) {
                    RenderedBody(text: submitted.body, html: submitted.bodyHTML)
                  }
                }
                ForEach(details.threads(in: submitted)) { thread in
                  threadCard(thread, details).padding(.leading, 20)
                }
              }
            }
          case .commit(let commit):
            timelineRow(author: nil, symbol: "point.topleft.down.curvedto.point.bottomright.up") {
              Button {
                app.openExternal(commit.url)
              } label: {
                HStack(spacing: 8) {
                  avatar(commit.author, size: 20)
                  Text(String(commit.message.split(separator: "\n").first ?? ""))
                    .font(.callout.monospaced()).lineLimit(1)
                  Spacer()
                }.frame(minHeight: 32).contentShape(Rectangle())
              }.buttonStyle(.plain).disabled(review.isDemo)
                .help("\(ReviewDetails.displayName(commit.author)) committed \(commit.date.formatted())")
                .overlay(alignment: .trailing) {
                  HStack(spacing: 8) {
                    if commit.verified == true { VerifiedBadge() }
                    CommitChecksBadge(checks: commit.checks, open: openLink)
                    Text(String(commit.id.prefix(7))).font(.callout.monospaced()).foregroundStyle(.secondary)
                  }.padding(.leading, 12).background(Color(nsColor: .windowBackgroundColor))
                }
            }
          case .event(let event):
            timelineRow(author: nil, symbol: event.symbol) {
              VStack(alignment: .leading, spacing: 6) {
                eventLine(author: event.actor, action: event.action, date: event.date)
                if let title = event.title, let url = event.url {
                  Link(title, destination: url).font(.callout.weight(.semibold))
                }
              }
            }
          case .references(let events):
            timelineRow(author: nil, symbol: "arrow.up.forward.square") {
              VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                  if events.count == 1, let event = events.first {
                    avatar(event.actor, size: 20).padding(.trailing, 1)
                    actorName(event.actor)
                    Text("mentioned this pull request")
                  } else {
                    Text("This was referenced").foregroundStyle(.secondary)
                  }
                  if let date = events.first?.date {
                    Text(date, style: .relative).foregroundStyle(.secondary)
                  }
                }.font(.callout).frame(minHeight: 32)
                ForEach(events) { event in
                  if let reference = event.reference { referenceRow(reference) }
                }
              }
            }
          case .thread(let thread):
            timelineRow(author: thread.comments.first?.author, symbol: "text.bubble") {
              threadCard(thread, details)
            }
          }
        }
        if review.pr.state == "OPEN" {
          mergeStatus(details)
        } else {
          let status = YardPalette.status(review.pr)
          timelineRow(author: nil, symbol: status.symbol, tint: status.color) {
            Text(review.pr.state == "MERGED"
              ? "Merged into \(review.pr.base)" : "Closed without merging")
              .font(.body.weight(.semibold)).frame(minHeight: 32)
          }
        }
        card("Add a discussion comment") {
          TextEditor(text: $review.draft.discussion).font(.body).frame(minHeight: 90).disabled(
            review.isPerforming)
          HStack {
            Spacer()
            Button("Post comment") { Task { await review.postDiscussion() } }
              .disabled(
                review.isDemo || review.isPerforming
                  || review.draft.discussion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              )
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
        // Reserves the sidebar's column; the sidebar itself floats in an overlay so it stays on screen.
        if conversationWidth >= 900 {
          Color.clear.frame(width: Self.sidebarWidth, height: 1)
            .onGeometryChange(for: CGFloat.self) {
              $0.frame(in: .named(Self.conversationSpace)).minX
            } action: { sidebarLeading = $0 }
        }
      }
      .padding(22).frame(maxWidth: Self.pageWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .coordinateSpace(name: Self.conversationSpace)
    .overlay(alignment: .topLeading) {
      if conversationWidth >= 900 {
        ViewThatFits(in: .vertical) {
          prSidebar(details)
          ScrollView { prSidebar(details) }.scrollIndicators(.automatic)
        }
        .frame(width: Self.sidebarWidth, alignment: .topLeading)
        .padding(.vertical, 22).padding(.leading, sidebarLeading)
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { conversationWidth = $0 }
    .onAppear { scroll(proxy) }
    .onChange(of: scrollTarget) { scroll(proxy) }
    }
  }

  private func scroll(_ proxy: ScrollViewProxy) {
    guard let target = scrollTarget else { return }
    DispatchQueue.main.async {
      withAnimation { proxy.scrollTo(target, anchor: .top) }
      scrollTarget = nil
    }
  }

  /// Comparable to github.com's maximum content width.
  static let pageWidth: CGFloat = 1280
  static let sidebarWidth: CGFloat = 280
  private static let conversationSpace = "conversation"

  private func prSidebar(_ details: ReviewDetails) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      let related = app.relatedPRs(review.pr)
      if !related.isEmpty || review.pr.stack != nil {
        sidebarSection("Related PRs") {
          if let stack = review.pr.stack {
            StackMap(review: review, pr: review.pr, stack: stack)
          }
          if !related.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
              ForEach(related) { pr in RelatedPRRow(pr: pr, current: review.pr) { app.open(pr) } }
            }.padding(.horizontal, -6)
          }
        }
      }
      sidebarSection(
        "Reviewers", accessory: canRequestReviews(details) ? pickerButton(.reviewers, details) : nil
      ) {
        if details.sidebarReviewers.isEmpty {
          Text("No reviews").foregroundStyle(.secondary)
        }
        ForEach(details.sidebarReviewers) { reviewer in
          HStack(spacing: 8) {
            if reviewer.isTeam {
              Image(systemName: "person.2.fill").font(.system(size: 10))
                .foregroundStyle(.secondary).frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            } else {
              avatar(reviewer.login, size: 20)
            }
            Text(reviewer.isTeam ? reviewer.login : ReviewDetails.displayName(reviewer.login))
              .fontWeight(.semibold).lineLimit(1)
            Spacer()
            if canRerequest(reviewer, details) {
              Button {
                Task { await review.requestReview(from: [reviewer.login]) }
              } label: {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11, weight: .semibold))
              }
              .buttonStyle(.borderless).foregroundStyle(.secondary)
              .disabled(review.isPerforming)
              .help("Re-request review from \(ReviewDetails.displayName(reviewer.login))")
            }
            reviewerStatus(reviewer.status)
          }
        }
        if details.canUpdate && review.pr.state == "OPEN" {
          HStack(spacing: 4) {
            Text(review.pr.isDraft ? "Ready?" : "Still in progress?").foregroundStyle(.secondary)
            Button(review.pr.isDraft ? "Mark ready for review" : "Convert to draft") {
              Task { await review.setDraft() }
            }.buttonStyle(.link).disabled(review.isDemo || review.isPerforming)
          }.padding(.top, 4)
        }
      }
      sidebarSection(
        "Assignees", accessory: details.sidebar.canTriage ? pickerButton(.assignees, details) : nil
      ) {
        if details.sidebar.assignees.isEmpty {
          HStack(spacing: 0) {
            Text("No one").foregroundStyle(.secondary)
            if details.sidebar.canTriage && !app.login.isEmpty {
              Text("—").foregroundStyle(.secondary)
              Button("assign yourself") { Task { await review.setAssignees([app.login]) } }
                .buttonStyle(.link).disabled(review.isPerforming)
            }
          }
        }
        ForEach(details.sidebar.assignees, id: \.self) { login in
          HStack(spacing: 8) {
            avatar(login, size: 20)
            Text(ReviewDetails.displayName(login)).fontWeight(.semibold)
          }
        }
      }
      sidebarSection(
        "Labels", accessory: details.sidebar.canTriage ? pickerButton(.labels, details) : nil
      ) {
        if details.sidebar.labels.isEmpty {
          Text("None yet").foregroundStyle(.secondary)
        } else {
          FlowLayout(spacing: 6) {
            ForEach(details.sidebar.labels) { LabelPill(label: $0) }
          }
        }
      }
      sidebarSection(
        "Milestone", accessory: details.sidebar.canTriage ? pickerButton(.milestone, details) : nil
      ) {
        Text(details.sidebar.milestone ?? "No milestone")
          .foregroundStyle(details.sidebar.milestone == nil ? .secondary : .primary)
      }
      if details.sidebar.subscription != nil {
        sidebarSection("Notifications") {
          let subscribed = details.sidebar.isSubscribed
          Button {
            Task { await review.setSubscribed(!subscribed) }
          } label: {
            Label(subscribed ? "Unsubscribe" : "Subscribe", systemImage: subscribed ? "bell.slash" : "bell")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(ActionButtonStyle()).disabled(review.isPerforming)
          Text(
            subscribed
              ? "You’re receiving notifications from this thread."
              : details.sidebar.subscription == "IGNORED"
                ? "You’re ignoring this repository." : "You’re not receiving notifications from this thread."
          ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      sidebarSection(
        "\(details.participants.count) participant\(details.participants.count == 1 ? "" : "s")",
        divider: details.canWrite
      ) {
        FlowLayout(spacing: 4) {
          ForEach(details.participants, id: \.self) { login in
            avatar(login, size: 26).help(ReviewDetails.displayName(login))
          }
        }
      }
      if details.canWrite {
        Button {
          confirmLock = true
        } label: {
          Label(
            details.sidebar.locked ? "Unlock conversation" : "Lock conversation",
            systemImage: details.sidebar.locked ? "lock.open" : "lock"
          ).fontWeight(.semibold)
        }
        .buttonStyle(.plain).padding(.vertical, 14).disabled(review.isPerforming)
        .confirmationDialog(
          details.sidebar.locked ? "Unlock this conversation?" : "Lock this conversation?",
          isPresented: $confirmLock
        ) {
          Button(details.sidebar.locked ? "Unlock conversation" : "Lock conversation") {
            Task { await review.setLocked(!details.sidebar.locked) }
          }
        } message: {
          Text(
            details.sidebar.locked
              ? "Everyone will be able to comment on this pull request again."
              : "Only collaborators will be able to comment on this pull request.")
        }
      }
    }.font(.callout)
  }

  private func canRequestReviews(_ details: ReviewDetails) -> Bool {
    details.canUpdate && review.pr.state == "OPEN"
  }

  private func canRerequest(_ reviewer: SidebarReviewer, _ details: ReviewDetails) -> Bool {
    canRequestReviews(details) && !reviewer.isTeam && reviewer.status != .requested
      && ReviewDetails.avatarKey(reviewer.login) != ReviewDetails.avatarKey(app.login)
  }

  private func pickerButton(_ kind: SidebarPicker, _ details: ReviewDetails) -> AnyView {
    AnyView(
      Button {
        activePicker = kind
      } label: {
        Image(systemName: "gearshape").font(.system(size: 13))
      }
      .buttonStyle(.borderless).foregroundStyle(.secondary).help(kind.help)
      .disabled(review.isPerforming)
      .popover(
        isPresented: Binding(
          get: { activePicker == kind }, set: { if !$0 { activePicker = nil } }),
        arrowEdge: .leading
      ) { picker(kind, details) })
  }

  @ViewBuilder private func picker(_ kind: SidebarPicker, _ details: ReviewDetails) -> some View {
    let close = { activePicker = nil }
    let url: (String) -> URL? = { login in
      if let url = details.avatarURL(for: login) { return url }
      if CopilotState.isCopilot(login) {
        return URL(string: "https://avatars.githubusercontent.com/in/946600?v=4")
      }
      return URL(string: "https://github.com/\(login).png?size=80")
    }
    switch kind {
    case .reviewers:
      SelectionPicker(
        title: "Request up to 15 reviewers", actionTitle: "Request", style: .person, limit: 15,
        pinned: [SidebarOption(id: "Copilot", title: "Copilot")],
        excluded: Set(
          [details.pr.author, app.login].map(ReviewDetails.avatarKey)
            + details.sidebar.requestedReviewers.map(ReviewDetails.avatarKey)),
        allowsCustom: true, avatarURL: url, load: { try await review.reviewerCandidates() },
        apply: { logins in Task { await review.requestReview(from: logins) } }, dismiss: close)
    case .assignees:
      SelectionPicker(
        title: "Assign up to 10 people", actionTitle: "Apply", style: .person, limit: 10,
        initial: details.sidebar.assignees, avatarURL: url,
        load: { try await review.sidebarOptions(.assignees) },
        apply: { logins in Task { await review.setAssignees(logins) } }, dismiss: close)
    case .labels:
      SelectionPicker(
        title: "Apply labels", actionTitle: "Apply", style: .label, limit: 100,
        initial: details.sidebar.labels.map(\.name), avatarURL: url,
        load: { try await review.sidebarOptions(.labels) },
        apply: { names in Task { await review.setLabels(names) } }, dismiss: close)
    case .milestone:
      SelectionPicker(
        title: "Set milestone", actionTitle: "Apply", style: .plain, limit: 1,
        initial: details.sidebar.milestoneNumber.map { [String($0)] } ?? [], avatarURL: url,
        load: { try await review.sidebarOptions(.milestones) },
        apply: { ids in Task { await review.setMilestone(ids.first.flatMap { Int($0) }) } },
        dismiss: close)
    }
  }

  private func sidebarSection<Content: View>(
    _ title: String, divider: Bool = true, accessory: AnyView? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
          Spacer()
          if let accessory { accessory }
        }
        content()
      }.padding(.vertical, 14)
      if divider { Divider() }
    }
  }

  @ViewBuilder private func reviewerStatus(_ status: SidebarReviewer.Status) -> some View {
    switch status {
    case .requested:
      Circle().fill(Color.orange).frame(width: 8, height: 8).help("Awaiting review")
    case .approved:
      Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.green)
        .help("Approved these changes")
    case .changesRequested:
      Image(systemName: "plus.forwardslash.minus").foregroundStyle(.red)
        .help("Requested changes")
    case .commented:
      Image(systemName: "text.bubble").foregroundStyle(.secondary).help("Left review comments")
    case .dismissed:
      Image(systemName: "xmark").foregroundStyle(.secondary).help("Review dismissed")
    }
  }

  private func reviewSymbol(_ state: String) -> String {
    switch state {
    case "APPROVED": "checkmark"
    case "CHANGES_REQUESTED": "plus.forwardslash.minus"
    default: "eye"
    }
  }

  private func reviewTint(_ state: String) -> Color? {
    switch state {
    case "APPROVED": .green
    case "CHANGES_REQUESTED": .red
    default: nil
    }
  }

  private func referenceRow(_ reference: ConversationEvent.Reference) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Button {
        app.openExternal(reference.url)
      } label: {
        (Text(reference.title).foregroundStyle(Color.primary)
          + Text(" " + (reference.repository.map { "\($0)" } ?? "") + "#" + String(reference.number))
          .foregroundStyle(.secondary))
          .font(.callout.weight(.semibold)).multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }.buttonStyle(.plain).disabled(review.isDemo)
        .help(reference.url.absoluteString)
      StatePill(state: reference.state, isPullRequest: reference.isPullRequest)
    }
  }

  private func reviewAction(_ state: String) -> String {
    switch state {
    case "APPROVED": "approved these changes"
    case "CHANGES_REQUESTED": "requested changes"
    case "DISMISSED": "had their review dismissed"
    default: "reviewed these changes"
    }
  }

  private func eventLabel(author: String, action: String, date: Date?, showAvatar: Bool = false)
    -> some View
  {
    HStack(spacing: 5) {
      if showAvatar { avatar(author, size: 20).padding(.trailing, 1) }
      actorName(author)
      Text(action)
      if let date { Text(date, style: .relative).foregroundStyle(.secondary) }
    }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
  }

  /// A standalone event line, vertically centered on the 32pt timeline icon.
  private func eventLine(author: String, action: String, date: Date?) -> some View {
    eventLabel(author: author, action: action, date: date, showAvatar: true).frame(minHeight: 32)
  }

  private func actorName(_ login: String) -> some View { ActorName(login: login) }

  /// GitHub-style avatar: circles for people, rounded squares for bots and apps.
  private func avatar(_ login: String, size: CGFloat) -> some View {
    AvatarView(login: login, url: review.details?.avatarURL(for: login), size: size)
  }

  private func timelineRow<Content: View>(
    author: String?, symbol: String, tint: Color? = nil, @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(spacing: 8) {
        if let author {
          avatar(author, size: 32)
        } else {
          Image(systemName: symbol).font(.system(size: 14, weight: tint == nil ? .regular : .bold))
            .foregroundStyle(tint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
            .frame(width: 32, height: 32)
            .background(tint ?? Color.primary.opacity(0.06), in: Circle())
        }
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 2).frame(maxHeight: .infinity)
      }.frame(width: 32)
      content().frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
    }.fixedSize(horizontal: false, vertical: true)
  }

  private func conversationCard<Content: View>(
    author: String, action: String, date: Date?,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      eventLabel(author: author, action: action, date: date)
        .padding(.horizontal, 12).frame(minHeight: 32).background(Color.primary.opacity(0.045))
      Divider()
      content().padding(16)
    }
    .background(Color.primary.opacity(0.015), in: RoundedRectangle(cornerRadius: 7))
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.15)))
  }

  private func mergeStatus(_ details: ReviewDetails) -> some View {
    let states = details.latestReviewStates.values
    let approvals = states.filter { $0 == "APPROVED" }.count
    let changes = states.filter { $0 == "CHANGES_REQUESTED" }.count
    let summary = details.checkSummary
    let ready = review.pr.stage == .ready && details.canMerge
    return HStack(alignment: .top, spacing: 14) {
      Image(systemName: "arrow.triangle.merge").font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white).frame(width: 32, height: 32)
        .background(
          ready ? Color.githubGreen : Color.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
      VStack(alignment: .leading, spacing: 0) {
        mergeSection(
          status: review.pr.reviewDecision == "APPROVED"
            ? .success : review.pr.reviewDecision == "CHANGES_REQUESTED" ? .failure : .waiting,
          title: review.pr.reviewDecision == "APPROVED"
            ? "Changes approved"
            : review.pr.reviewDecision == "CHANGES_REQUESTED"
              ? "Changes requested" : "Review required",
          detail: [
            approvals > 0 ? "\(approvals) approving review\(approvals == 1 ? "" : "s")" : nil,
            changes > 0 ? "\(changes) requesting changes" : nil,
          ].compactMap { $0 }.joined(separator: ", ").nonEmpty
            ?? "At least one approving review may be required to merge.")
        Divider()
        Button {
          withAnimation(.easeInOut(duration: 0.15)) { checksExpanded.toggle() }
        } label: {
          mergeSection(
            status: summary.failed > 0
              ? .failure
              : summary.pending > 0 ? .pending : summary.total == 0 ? .neutral : .success,
            title: summary.title, detail: summary.detail,
            chevron: summary.total > 0, expanded: checksExpanded)
        }.buttonStyle(.plain).disabled(summary.total == 0)
        if checksExpanded && summary.total > 0 {
          ChecksList(checks: details.checks, open: openLink)
            .padding(.horizontal, 12).padding(.bottom, 10)
            .background(Color.primary.opacity(0.03))
        }
        Divider()
        mergeSection(
          status: review.pr.mergeable == "MERGEABLE"
            ? .success : review.pr.mergeable == "CONFLICTING" ? .failure : .pending,
          title: review.pr.mergeable == "CONFLICTING"
            ? "This branch has conflicts that must be resolved"
            : review.pr.mergeable == "MERGEABLE"
              ? "No conflicts with base branch" : "Checking for the ability to merge automatically…",
          detail: review.pr.mergeable == "MERGEABLE"
            ? "Merging can be performed automatically."
            : review.pr.mergeable == "CONFLICTING"
              ? "Resolve conflicts on GitHub or locally." : "GitHub is still computing mergeability.")
        if let stack = review.pr.stack {
          Divider()
          let blocked = stack.blocker
          mergeSection(
            status: blocked != nil ? .waiting : .success,
            title: blocked.map { "Can't merge yet: \($0.displayNumber) below — \(($0.problem ?? "not ready").lowercased())" }
              ?? (stack.openBelow.isEmpty
                ? "Bottom of stack #\(stack.number)"
                : "Merges \(PRStack.list(stack.mergedTogether(with: review.pr.number))) together"),
            detail: blocked != nil
              ? "GitHub only merges a stacked PR when it and every open PR below it meet \(stack.base)'s rules."
              : "Layer \(stack.position) of \(stack.size) into \(stack.base). Merging also merges every open PR below; PRs above are retargeted to \(stack.base).")
        }
        Divider()
        HStack(spacing: 12) {
          MergeButton(review: review, prominent: ready)
          Text(review.pr.waitingReason).font(.callout).foregroundStyle(.secondary)
        }.padding(16)
      }
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.15)))
    }
  }

  private enum MergeSectionStatus { case success, failure, pending, waiting, neutral }

  private func mergeSection(
    status: MergeSectionStatus, title: String, detail: String, chevron: Bool = false,
    expanded: Bool = false
  ) -> some View {
    HStack(spacing: 12) {
      Group {
        switch status {
        case .success:
          Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white).frame(width: 28, height: 28)
            .background(Color.githubGreen, in: Circle())
        case .failure:
          Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white).frame(width: 28, height: 28).background(.red, in: Circle())
        case .pending:
          Circle().trim(from: 0, to: 0.75).stroke(Color.orange, lineWidth: 3)
            .rotationEffect(.degrees(-90)).padding(3)
            .background(Circle().stroke(Color.green.opacity(0.7), lineWidth: 3).padding(3))
            .frame(width: 28, height: 28)
        case .waiting:
          Image(systemName: "exclamationmark").font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white).frame(width: 28, height: 28).background(.orange, in: Circle())
        case .neutral:
          Image(systemName: "minus").font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white).frame(width: 28, height: 28)
            .background(Color.secondary, in: Circle())
        }
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.body.weight(.semibold))
        Text(detail).font(.callout).foregroundStyle(.secondary)
      }
      Spacer()
      if chevron {
        Image(systemName: "chevron.down").foregroundStyle(.secondary)
          .rotationEffect(.degrees(expanded ? 180 : 0))
      }
    }.padding(16).contentShape(Rectangle())
  }

  private var openLink: ((URL) -> Void)? {
    review.isDemo ? nil : { app.openExternal($0) }
  }

  private func checks(_ details: ReviewDetails) -> some View {
    let summary = details.checkSummary
    return ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(summary.title).font(.title3.bold())
          Text(summary.detail).foregroundStyle(.secondary)
        }
        if details.checks.isEmpty {
          Text("GitHub returned no check runs or commit statuses.").foregroundStyle(.secondary)
        } else {
          ChecksList(checks: details.checks, open: openLink).padding(8)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
        }
      }.padding(22).frame(maxWidth: Self.pageWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func commits(_ details: ReviewDetails) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        ForEach(details.commits) { commit in
          card(String(commit.message.split(separator: "\n").first ?? "")) {
            HStack(spacing: 8) {
              avatar(commit.author, size: 18)
              Text(ReviewDetails.displayName(commit.author)).font(.caption.weight(.semibold))
              Text("committed \(commit.date, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
              Spacer()
              if commit.verified == true { VerifiedBadge() }
              CommitChecksBadge(checks: commit.checks, open: openLink)
              Button(String(commit.id.prefix(7))) { app.openExternal(commit.url) }
                .buttonStyle(.link).font(.callout.monospaced()).disabled(review.isDemo)
            }
          }
        }
      }.padding(22).frame(maxWidth: Self.pageWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.headline)
      content()
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
  }

  private var reviewSheet: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Submit review").font(.title2.bold())
      Text("Reviewing \(review.details?.headSHA.prefix(8) ?? "")").font(.caption.monospaced())
        .foregroundStyle(.secondary)
      Picker("Decision", selection: $review.draft.event) {
        ForEach(ReviewEvent.allCases, id: \.self) { event in
          Text(event.title).tag(event)
        }
      }.pickerStyle(.segmented).disabled(review.isPerforming)
      TextEditor(text: $review.draft.body).font(.body).frame(height: 130).disabled(
        review.isPerforming)
      if !review.draft.comments.isEmpty {
        Text("\(review.draft.comments.count) inline comments").font(.headline)
        ScrollView {
          ForEach(review.draft.comments) { comment in
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 4) {
                Text(
                  "\(comment.anchor.path):\(comment.anchor.line) (\(comment.anchor.side.rawValue))"
                ).font(.caption.monospaced())
                Text(comment.body).font(.callout)
              }
              Spacer()
              Button {
                review.draft.comments.removeAll { $0.id == comment.id }
              } label: {
                Image(systemName: "trash")
              }
              .disabled(review.isPerforming)
            }.padding(.vertical, 5)
          }
        }.frame(maxHeight: 150)
      }
      if review.details?.hasPendingGitHubReview == true {
        Text(
          "You already have a pending review on GitHub. Finish it in your normal browser before submitting a new review here."
        ).font(.callout).foregroundStyle(.orange)
      }
      if review.isDemo {
        Text("Sample review: submission is disabled.").foregroundStyle(.secondary).font(.caption)
      }
      if let error = review.error { Text(error).font(.callout).foregroundStyle(.orange) }
      HStack {
        Button("Keep draft") { review.isComposingReview = false }.keyboardShortcut(.cancelAction)
        Spacer()
        if review.isPerforming { ProgressView().controlSize(.small) }
        Button("Submit \(review.draft.event.title.lowercased())") {
          Task { if await review.submitReview() { review.isComposingReview = false } }
        }.buttonStyle(.borderedProminent)
          .disabled(
            review.isDemo || review.isPerforming || review.draftIsStale
              || review.details?.hasPendingGitHubReview == true
              || review.draft.event != .comment
                && (review.pr.isDraft || review.pr.isMine(review.details?.viewer.login ?? ""))
          )
      }
    }.padding(24).frame(width: 590)
  }

  private func threadCard(_ thread: ReviewThread, _ details: ReviewDetails) -> some View {
    ReviewThreadCard(
      review: review, thread: thread, findings: details.findings,
      avatarURL: { details.avatarURL(for: $0) }, viewer: details.viewer.login
    ) {
      review.selectedFile = thread.path
      review.selectSection(.files)
    }
  }
}

private struct InlineCommentSheet: View {
  @ObservedObject var review: ReviewModel
  let anchor: DiffAnchor
  @Environment(\.dismiss) private var dismiss
  @State private var bodyText = ""
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Draft inline comment").font(.title2.bold())
      Text("\(anchor.path):\(anchor.line) · \(anchor.side.rawValue)").font(.caption.monospaced())
      TextEditor(text: $bodyText).font(.body).frame(height: 130).disabled(review.isPerforming)
      Text("This stays local until you submit the review.").font(.caption).foregroundStyle(
        .secondary)
      if let error { Text(error).foregroundStyle(.orange).font(.callout) }
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Add to review") {
          do {
            try review.addComment(anchor: anchor, body: bodyText)
            dismiss()
          } catch { self.error = error.localizedDescription }
        }.buttonStyle(.borderedProminent).disabled(
          review.isPerforming || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: 550)
  }
}

private struct StatePill: View {
  let state: ConversationEvent.Reference.State
  let isPullRequest: Bool

  var body: some View {
    Label(title, systemImage: symbol)
      .font(.callout.weight(.medium)).foregroundStyle(.white)
      .padding(.horizontal, 10).padding(.vertical, 4)
      .background(color, in: Capsule())
      .fixedSize()
  }

  private var title: String {
    switch state {
    case .open: "Open"
    case .draft: "Draft"
    case .merged: "Merged"
    case .closed: "Closed"
    }
  }

  private var symbol: String {
    switch state {
    case .merged: "arrow.triangle.merge"
    case .closed: isPullRequest ? "xmark.circle" : "checkmark.circle"
    case .draft: "pencil.circle"
    case .open: isPullRequest ? "arrow.triangle.pull" : "circle.circle"
    }
  }

  private var color: Color {
    let green = Color(red: 0.14, green: 0.53, blue: 0.21)
    let purple = Color(red: 0.54, green: 0.34, blue: 0.9)
    let red = Color(red: 0.85, green: 0.21, blue: 0.2)
    return switch state {
    case .open: green
    case .draft: Color.gray
    case .merged: purple
    case .closed: isPullRequest ? red : purple
    }
  }
}

extension String {
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

/// GitHub-like action button: rounded, bordered, icon + label; `tint` makes it prominent.
struct ActionButtonStyle: ButtonStyle {
  var tint: Color? = nil
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    let prominent = tint != nil && isEnabled
    configuration.label
      .labelStyle(ActionLabelStyle())
      .font(.callout.weight(.medium))
      .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      .padding(.horizontal, 12).frame(height: 28)
      .background(
        RoundedRectangle(cornerRadius: 7)
          .fill(
            prominent
              ? (tint ?? .accentColor).opacity(configuration.isPressed ? 0.75 : hovering ? 0.9 : 1)
              : Color.primary.opacity(
                configuration.isPressed ? 0.14 : hovering && isEnabled ? 0.1 : 0.06))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 7)
          .stroke(prominent ? Color.black.opacity(0.15) : Color.primary.opacity(0.14))
      )
      .opacity(isEnabled ? 1 : 0.5)
      .contentShape(RoundedRectangle(cornerRadius: 7))
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.12), value: hovering)
  }
}

private struct ActionLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon.imageScale(.medium)
      configuration.title
    }
  }
}

private struct LabelPill: View {
  let label: PullRequestLabel

  var body: some View {
    let color = Color(hex: label.color) ?? .secondary
    Text(label.name).font(.caption.weight(.semibold))
      .padding(.horizontal, 8).padding(.vertical, 2)
      .background(color.opacity(0.25), in: Capsule())
      .overlay(Capsule().stroke(color.opacity(0.6)))
  }
}

extension Color {
  /// Linear-style neutral gray, so tickets don't compete with the repository and target branch.
  static let ticketInk = Color(nsColor: .secondaryLabelColor)
  /// github.com's muted merge green; the system green is too bright for large surfaces.
  static let githubGreen = Color(red: 0x23 / 255, green: 0x86 / 255, blue: 0x36 / 255)
  static let reviewPurple = Color(red: 0.51, green: 0.36, blue: 0.86)
  static let branchBlue = Color(red: 0x4c / 255, green: 0x8d / 255, blue: 0xf6 / 255)

  fileprivate init?(hex: String) {
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
    self.init(
      red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255)
  }
}

/// Wraps children onto multiple lines, like labels and participant avatars on GitHub.
private struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(subviews, width: proposal.width ?? .infinity).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for (index, point) in arrange(subviews, width: bounds.width).points.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
    }
  }

  private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, points: [CGPoint]) {
    var points: [CGPoint] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0
    var maxX: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        x = 0
        y += lineHeight + spacing
        lineHeight = 0
      }
      points.append(CGPoint(x: x, y: y))
      x += size.width + spacing
      maxX = max(maxX, x - spacing)
      lineHeight = max(lineHeight, size.height)
    }
    return (CGSize(width: maxX, height: y + lineHeight), points)
  }
}

/// GitHub-style avatar: circles for people, rounded squares for bots.
struct AvatarView: View {
  let login: String
  let url: URL?
  let size: CGFloat

  var body: some View {
    let bot = ReviewDetails.isBot(login)
    let shape = RoundedRectangle(cornerRadius: bot ? size * 0.2 : size / 2)
    Group {
      if let url {
        CachedImage(url: ImageCache.sized(url, points: size)) {
          Color.primary.opacity(0.08)
        }
      } else {
        Image(systemName: bot ? "cpu" : "person.fill").font(.system(size: size * 0.5))
          .foregroundStyle(.secondary).frame(width: size, height: size)
          .background(Color.primary.opacity(0.08))
      }
    }
    .frame(width: size, height: size).clipShape(shape)
    .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
  }
}

enum SidebarPicker: Hashable {
  case reviewers, assignees, labels, milestone

  var help: String {
    switch self {
    case .reviewers: "Request reviewers"
    case .assignees: "Edit assignees"
    case .labels: "Edit labels"
    case .milestone: "Set milestone"
    }
  }
}

/// GitHub-like sidebar picker: filterable list with selected entries first.
private struct SelectionPicker: View {
  enum Style { case person, label, plain }

  let title: String
  let actionTitle: String
  let style: Style
  let limit: Int
  var initial: [String] = []
  var pinned: [SidebarOption] = []
  var excluded: Set<String> = []
  var allowsCustom = false
  let avatarURL: (String) -> URL?
  let load: () async throws -> [SidebarOption]
  let apply: ([String]) -> Void
  let dismiss: () -> Void

  @State private var search = ""
  @State private var options: [SidebarOption] = []
  @State private var loading = true
  @State private var error: String?
  @State private var selected: [String] = []

  private var filtered: [SidebarOption] {
    let query = search.trimmingCharacters(in: .whitespaces)
    var result = options
    if !query.isEmpty {
      let needle = query.lowercased()
      result = result.filter {
        $0.title.lowercased().contains(needle)
          || ReviewDetails.displayName($0.title).lowercased().contains(needle)
          || ($0.detail?.lowercased().contains(needle) ?? false)
      }
      if allowsCustom, !result.contains(where: { $0.id.lowercased() == needle }),
        query.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil
      {
        result.append(SidebarOption(id: query, title: query))
      }
    }
    return result
  }

  private var changed: Bool { Set(selected) != Set(initial) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title).font(.callout.weight(.semibold)).padding(12)
      Divider()
      TextField("Filter", text: $search).textFieldStyle(.roundedBorder).padding(10)
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if loading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(12)
          }
          if let error { Text(error).font(.caption).foregroundStyle(.red).padding(10) }
          if !loading && error == nil && filtered.isEmpty {
            Text("Nothing found").foregroundStyle(.secondary).padding(10)
          }
          ForEach(filtered) { option in row(option) }
        }
      }.frame(height: 300)
      Divider()
      HStack {
        Text(limit == 1 ? (selected.isEmpty ? "None" : "") : "\(selected.count) selected")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
        Button(actionTitle) {
          let ids = selected
          dismiss()
          apply(ids)
        }
        .keyboardShortcut(.defaultAction).disabled(!changed)
      }.padding(10)
    }
    .frame(width: 320)
    .font(.callout)
    .task {
      selected = initial
      do {
        let loaded = try await load()
        var seen = Set<String>()
        let initialOptions = initial.map { id in
          loaded.first { $0.id.lowercased() == id.lowercased() } ?? SidebarOption(id: id, title: id)
        }
        options = (initialOptions + pinned + loaded).filter {
          !excluded.contains(ReviewDetails.avatarKey($0.id)) && seen.insert($0.id.lowercased()).inserted
        }
      } catch {
        self.error = error.localizedDescription
        options = initial.map { SidebarOption(id: $0, title: $0) } + pinned
      }
      loading = false
    }
  }

  private func row(_ option: SidebarOption) -> some View {
    let isSelected = selected.contains { $0.lowercased() == option.id.lowercased() }
    return Button {
      if isSelected {
        selected.removeAll { $0.lowercased() == option.id.lowercased() }
      } else if limit == 1 {
        selected = [option.id]
      } else if selected.count < limit {
        selected.append(option.id)
      }
    } label: {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
          .opacity(isSelected ? 1 : 0).frame(width: 14).padding(.top, 3)
        switch style {
        case .person:
          AvatarView(login: option.id, url: avatarURL(option.id), size: 20)
        case .label:
          Circle().fill(Color(hex: option.color ?? "") ?? .secondary).frame(width: 14, height: 14)
            .padding(.top, 2)
        case .plain:
          EmptyView()
        }
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(style == .person ? ReviewDetails.displayName(option.title) : option.title)
              .fontWeight(.semibold).lineLimit(1)
            if style == .person && ReviewDetails.isBot(option.id) {
              Text("AI").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(Capsule().stroke(Color.secondary.opacity(0.5)))
            }
            if style == .person, let detail = option.detail {
              Text(detail).foregroundStyle(.secondary).lineLimit(1)
            }
          }
          if style != .person, let detail = option.detail, !detail.isEmpty {
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// A review thread like GitHub's conversation tab: the commented lines, the comments and a reply bar.
private struct ReviewThreadCard: View {
  @ObservedObject var review: ReviewModel
  let thread: ReviewThread
  let findings: [Int: ReviewFinding]
  let avatarURL: (String) -> URL?
  let viewer: String
  let showFile: () -> Void
  @State private var expanded: Bool?
  @State private var replying = false
  @FocusState private var replyFocused: Bool

  private var isExpanded: Bool { expanded ?? !(thread.isResolved || thread.isOutdated) }
  private var replyText: Binding<String> {
    Binding(
      get: { review.draft.replies[thread.id] ?? "" },
      set: { review.draft.replies[thread.id] = $0 })
  }
  private var canReply: Bool {
    thread.canReply && (thread.comments.first?.databaseID != nil || review.isDemo)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if isExpanded {
        let snippet = thread.snippet
        if !snippet.isEmpty {
          Divider()
          VStack(spacing: 0) { ForEach(snippet) { snippetRow($0) } }
        }
        ForEach(thread.comments) { comment in
          Divider()
          commentView(comment)
        }
        Divider()
        replyBar
        if thread.isResolved ? thread.canUnresolve : thread.canResolve {
          Divider()
          HStack {
            Button(thread.isResolved ? "Unresolve conversation" : "Resolve conversation") {
              Task { await review.resolve(thread) }
            }
            .buttonStyle(ActionButtonStyle())
            .disabled(review.isDemo || review.isPerforming)
            Spacer()
          }.padding(12).background(Color.primary.opacity(0.03))
        }
      }
    }
    .background(Color.primary.opacity(0.015))
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.15)))
    .onAppear { if !replyText.wrappedValue.isEmpty { replying = true } }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Button {
        withAnimation(.easeOut(duration: 0.15)) { expanded = !isExpanded }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            .rotationEffect(.degrees(isExpanded ? 0 : -90)).foregroundStyle(.secondary)
          Text(thread.path).font(.system(size: 12, design: .monospaced)).lineLimit(1)
            .truncationMode(.head)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain)
      if thread.isOutdated { tag("Outdated", color: .orange) }
      if thread.isResolved { tag("Resolved", color: .purple) }
      Spacer()
      Button(action: showFile) { Image(systemName: "doc.text.magnifyingglass") }
        .buttonStyle(.borderless).help("Show in Files changed")
    }.padding(.horizontal, 12).frame(minHeight: 36).background(Color.primary.opacity(0.045))
  }

  private func tag(_ title: String, color: Color) -> some View {
    Text(title).font(.caption2.weight(.medium)).foregroundStyle(color)
      .padding(.horizontal, 7).padding(.vertical, 1)
      .overlay(Capsule().stroke(color.opacity(0.5)))
  }

  private func snippetRow(_ line: DiffLine) -> some View {
    HStack(alignment: .top, spacing: 0) {
      HStack(alignment: .top, spacing: 0) {
        Text(line.oldLine.map(String.init) ?? "").frame(width: 40, alignment: .trailing)
        Text(line.newLine.map(String.init) ?? "").frame(width: 40, alignment: .trailing)
      }
      .foregroundStyle(.secondary).padding(.vertical, 2).padding(.trailing, 8)
      .frame(maxHeight: .infinity, alignment: .top).background(DiffColors.gutter(line.kind))
      Text(line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " ")
        .frame(width: 22).padding(.vertical, 2)
      Text(line.text).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        .padding(.vertical, 2).padding(.trailing, 10)
    }
    .font(.system(size: 12, design: .monospaced))
    .fixedSize(horizontal: false, vertical: true)
    .background(DiffColors.code(line.kind))
  }

  private func commentView(_ comment: DiscussionComment) -> some View {
    let finding = comment.databaseID.flatMap { findings[$0] }
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        AvatarView(login: comment.author, url: avatarURL(comment.author), size: 20)
        ActorName(login: comment.author)
        Text(comment.date, style: .relative).foregroundStyle(.secondary)
        Spacer()
        if let severity = finding?.severity { SeverityPill(severity: severity) }
        if let url = comment.url {
          Button {
            NSWorkspace.shared.open(url)
          } label: {
            Image(systemName: "arrow.up.right.square")
          }.buttonStyle(.borderless).foregroundStyle(.secondary).help("Open comment on GitHub")
        }
      }.font(.callout)
      if let title = finding?.title {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      }
      RenderedBody(text: comment.body, html: comment.bodyHTML)
      if CopilotState.isCopilot(comment.author), !comment.body.contains("```suggestion"),
        let url = comment.url
      {
        Button {
          NSWorkspace.shared.open(url)
        } label: {
          Label("View Copilot's suggested changeset on GitHub", systemImage: "arrow.up.right.square")
            .font(.caption)
        }
        .buttonStyle(.link)
        .help("GitHub doesn't return Copilot's suggested changesets through its API, so they only show on github.com.")
      }
    }.padding(12)
  }

  @ViewBuilder private var replyBar: some View {
    HStack(alignment: .top, spacing: 10) {
      AvatarView(login: viewer, url: avatarURL(viewer), size: 24)
      if replying {
        VStack(alignment: .trailing, spacing: 8) {
          TextEditor(text: replyText).font(.body).frame(minHeight: 70)
            .scrollContentBackground(.hidden).padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.6)))
            .focused($replyFocused).disabled(review.isPerforming)
          HStack {
            Button("Cancel") {
              review.draft.replies.removeValue(forKey: thread.id)
              replying = false
            }.buttonStyle(ActionButtonStyle())
            Button("Comment") {
              Task { if await review.reply(to: thread) { replying = false } }
            }
            .buttonStyle(ActionButtonStyle(tint: .githubGreen))
            .disabled(
              review.isDemo || review.isPerforming
                || replyText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
      } else {
        Button {
          replying = true
          DispatchQueue.main.async { replyFocused = true }
        } label: {
          Text("Reply…").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.18)))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!canReply)
          .help(canReply ? "Reply to this conversation" : "You cannot reply to this conversation")
      }
    }.padding(12).background(Color.primary.opacity(0.03))
  }
}

private struct SeverityPill: View {
  let severity: String
  private var color: Color {
    switch severity.lowercased() {
    case "critical", "high": .red
    case "medium": .orange
    default: .blue
    }
  }
  var body: some View {
    Text(severity.capitalized).font(.caption.weight(.medium)).foregroundStyle(color)
      .padding(.horizontal, 8).padding(.vertical, 1)
      .overlay(Capsule().stroke(color.opacity(0.7)))
      .help("\(severity.capitalized) severity finding")
  }
}

/// A login with GitHub's "AI"/"bot" badge for automated accounts.
struct ActorName: View {
  let login: String
  var body: some View {
    HStack(spacing: 4) {
      Text(ReviewDetails.displayName(login)).fontWeight(.semibold)
      if ReviewDetails.isBot(login) {
        Text(CopilotState.isCopilot(login) ? "AI" : "bot")
          .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
          .padding(.horizontal, 5).padding(.vertical, 1)
          .overlay(Capsule().stroke(Color.secondary.opacity(0.5)))
      }
    }
  }
}

/// GitHub's diff colors: the line-number gutter is a stronger tint than the code beside it.
enum DiffColors {
  static func gutter(_ kind: DiffLineKind) -> Color {
    switch kind {
    case .addition: Color(red: 0.25, green: 0.73, blue: 0.31).opacity(0.3)
    case .deletion: Color(red: 0.97, green: 0.32, blue: 0.29).opacity(0.3)
    case .hunk: Color(red: 0.27, green: 0.58, blue: 0.97).opacity(0.25)
    case .context, .note: .clear
    }
  }

  static func code(_ kind: DiffLineKind) -> Color {
    switch kind {
    case .addition: Color(red: 0.18, green: 0.63, blue: 0.26).opacity(0.15)
    case .deletion: Color(red: 0.97, green: 0.32, blue: 0.29).opacity(0.15)
    case .hunk: Color(red: 0.27, green: 0.58, blue: 0.97).opacity(0.1)
    case .context, .note: .clear
    }
  }
}

/// GitHub's per-check status glyph.
struct CheckIcon: View {
  let outcome: PullRequestCheck.Outcome
  var size: CGFloat = 13

  var body: some View {
    switch outcome {
    case .successful:
      Image(systemName: "checkmark").font(.system(size: size, weight: .bold)).foregroundStyle(Color.githubGreen)
    case .failing:
      Image(systemName: "xmark").font(.system(size: size, weight: .bold)).foregroundStyle(.red)
    case .skipped:
      Image(systemName: "slash.circle").font(.system(size: size + 1)).foregroundStyle(.secondary)
    case .pending:
      PendingDot(size: size)
    }
  }
}

private struct PendingDot: View {
  let size: CGFloat
  @State private var pulse = false

  var body: some View {
    Circle().fill(Color.orange).frame(width: size * 0.7, height: size * 0.7)
      .opacity(pulse ? 0.35 : 1)
      .frame(width: size + 2, height: size + 2)
      .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
  }
}

/// Checks grouped like GitHub's merge box: failing, in progress, skipped, then successful.
struct ChecksList: View {
  let checks: [PullRequestCheck]
  let open: ((URL) -> Void)?
  @State private var collapsed: Set<PullRequestCheck.Outcome> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(PullRequestCheck.Outcome.allCases, id: \.self) { outcome in
        let group = checks.filter { $0.outcome == outcome }
        if !group.isEmpty {
          Button {
            if collapsed.contains(outcome) { collapsed.remove(outcome) } else { collapsed.insert(outcome) }
          } label: {
            HStack(spacing: 4) {
              Text("\(group.count) \(outcome.title) check\(group.count == 1 ? "" : "s")")
              Image(systemName: collapsed.contains(outcome) ? "chevron.right" : "chevron.down")
                .font(.caption2.weight(.semibold))
            }
            .font(.callout.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4).contentShape(Rectangle())
          }.buttonStyle(.plain)
          if !collapsed.contains(outcome) {
            ForEach(group) { CheckRow(check: $0, open: open) }
          }
        }
      }
    }
  }
}

struct CheckRow: View {
  let check: PullRequestCheck
  let open: ((URL) -> Void)?
  var compact = false
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 10) {
      CheckIcon(outcome: check.outcome).frame(width: 18)
      Image(systemName: check.workflow == nil ? "circle.hexagongrid" : "gearshape.2")
        .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
      Text(check.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.tail)
        .layoutPriority(1)
      TimelineView(.periodic(from: .now, by: check.outcome == .pending ? 1 : 60)) { context in
        Text(check.status(now: context.date)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 8)
      if let url = check.url, let open {
        Button("Details") { open(url) }.buttonStyle(.link).font(.callout)
      }
    }
    .padding(.horizontal, 8).padding(.vertical, compact ? 6 : 8)
    .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
    .onHover { hovering = $0 }
    .help(check.summary ?? check.title)
  }
}

/// The ✓/✗/● next to a commit; clicking shows that commit's checks like GitHub's popover.
struct CommitChecksBadge: View {
  let checks: [PullRequestCheck]
  let open: ((URL) -> Void)?
  @State private var showing = false

  var body: some View {
    let summary = CheckSummary(checks)
    if summary.total > 0 {
      Button { showing.toggle() } label: {
        CheckIcon(outcome: outcome(summary)).frame(width: 18, height: 18).contentShape(Rectangle())
      }
      .buttonStyle(.plain).help(summary.title)
      .popover(isPresented: $showing, arrowEdge: .bottom) {
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: 2) {
            Text(summary.title).font(.headline)
            Text(summary.detail).font(.callout).foregroundStyle(.secondary)
          }.padding(14)
          Divider()
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(checks.sorted { $0.outcome.rawValue < $1.outcome.rawValue }) { check in
                CheckRow(check: check, open: open.map { open in { showing = false; open($0) } }, compact: true)
                Divider().opacity(0.5)
              }
            }.padding(6)
          }.frame(maxHeight: 320)
        }.frame(width: 480)
      }
    }
  }

  private func outcome(_ summary: CheckSummary) -> PullRequestCheck.Outcome {
    summary.failed > 0 ? .failing : summary.pending > 0 ? .pending : summary.successful > 0 ? .successful : .skipped
  }
}

struct VerifiedBadge: View {
  var body: some View {
    Text("Verified").font(.caption.weight(.medium)).foregroundStyle(Color.githubGreen)
      .padding(.horizontal, 7).padding(.vertical, 2)
      .overlay(Capsule().stroke(Color.primary.opacity(0.25)))
      .help("This commit was signed with a verified signature.")
  }
}

/// GitHub's split merge button: the main part merges right away with the selected method,
/// the menu switches method. The merge runs in the background so you can keep working.
struct MergeButton: View {
  @ObservedObject var review: ReviewModel
  var prominent = true
  private var mergeHelp: String {
    let stack = review.pr.stack
    if let blocker = stack?.blocker, let problem = blocker.problem {
      return "Can't merge yet: \(blocker.displayNumber) below — \(problem.lowercased())"
    }
    let numbers = stack?.mergedTogether(with: review.pr.number) ?? [review.pr.number]
    let target = stack?.base ?? review.pr.base
    return numbers.count > 1
      ? "\(review.mergeMethod.title) \(PRStack.list(numbers)) into \(target)"
      : "\(review.mergeMethod.title) into \(target)"
  }

  var body: some View {
    let methods = review.details?.mergeMethods ?? []
    // GitHub rejects a stacked merge while any open PR below fails the trunk's rules.
    let enabled = !review.isDemo && !review.isPerforming && review.details?.canMerge == true
      && review.pr.stack?.blocker == nil
    let stackCount = review.pr.stack.map { $0.openBelow.count + 1 } ?? 1
    HStack(spacing: 0) {
      Button {
        Task { await review.merge() }
      } label: {
        HStack(spacing: 6) {
          if review.isMerging {
            ProgressView().controlSize(.small).tint(.white)
            Text("Merging…")
          } else {
            Image(systemName: "arrow.triangle.merge")
            Text(stackCount > 1 ? "\(review.mergeMethod.title) \(stackCount) PRs" : review.mergeMethod.title)
          }
        }.padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 6)
      }
      .buttonStyle(.plain)
      .disabled(!enabled)
      .help(mergeHelp)
      if methods.count > 1 {
        Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1).padding(.vertical, 4)
        Menu {
          Picker("Merge method", selection: $review.mergeMethod) {
            ForEach(methods, id: \.self) { Text($0.title).tag($0) }
          }.pickerStyle(.inline).labelsHidden()
        } label: {
          Image(systemName: "chevron.down").font(.caption.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(!enabled)
        .help("Choose merge method")
      }
    }
    .font(.callout.weight(.semibold))
    .foregroundStyle(prominent ? .white : .primary)
    .background(
      prominent ? Color.githubGreen.opacity(enabled || review.isMerging ? 1 : 0.5) : Color.primary.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 7))
    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(prominent ? 0 : 0.15)))
    .fixedSize()
  }
}

/// Reload, open in browser, draft toggle, review and merge, on the section picker's row.
struct ReviewActionBar: View {
  @EnvironmentObject var app: AppModel
  @ObservedObject var review: ReviewModel

  var body: some View {
    HStack(spacing: 8) {
      Button {
        Task { await review.load(force: true) }
      } label: {
        if review.isLoading {
          ProgressView().controlSize(.small).frame(width: 14, height: 14)
        } else {
          Image(systemName: "arrow.clockwise").frame(width: 14, height: 14)
        }
      }
      .buttonStyle(ActionButtonStyle())
      .disabled(review.isLoading)
      .help(review.isLoading ? (review.details == nil ? "Loading…" : "Refreshing…") : "Reload this review (⌘R)")
      Button {
        app.openExternal(review.pr.url)
      } label: {
        Image(systemName: "arrow.up.right.square").frame(width: 14, height: 14)
      }
      .buttonStyle(ActionButtonStyle())
      .disabled(review.isDemo)
      .help(review.isDemo ? "Sample PRs do not link to real GitHub pull requests." : "Open in browser")
      Divider().frame(height: 20).padding(.horizontal, 2)
      if review.details?.canUpdate == true {
        Button {
          Task { await review.setDraft() }
        } label: {
          Label(
            review.pr.isDraft ? "Ready for review" : "Convert to draft",
            systemImage: review.pr.isDraft ? "eye" : "pencil.circle")
        }
        .buttonStyle(ActionButtonStyle(tint: review.pr.isDraft ? .branchBlue : nil))
        .disabled(review.isDemo || review.isPerforming || review.pr.state != "OPEN")
      }
      Button {
        review.prepareReview()
        review.isComposingReview = true
      } label: {
        Label("Review changes", systemImage: "text.bubble")
      }
      .buttonStyle(ActionButtonStyle(tint: review.pr.needsMyReview ? .githubGreen : .reviewPurple))
      .disabled(review.details == nil || review.pr.state != "OPEN" || review.isPerforming)
      let canMerge = review.details?.canMerge == true
      if review.pr.state != "OPEN" {
        let status = YardPalette.status(review.pr)
        Label(review.pr.state == "MERGED" ? "Merged" : "Closed", systemImage: status.symbol)
          .font(.callout.weight(.semibold)).foregroundStyle(.white)
          .padding(.horizontal, 12).frame(height: 28)
          .background(status.color, in: RoundedRectangle(cornerRadius: 7))
      } else if canMerge || review.isMerging {
        MergeButton(review: review)
      } else {
        Label("Not ready to merge", systemImage: "circle.dashed")
          .padding(.horizontal, 12).frame(height: 28)
          .foregroundStyle(.secondary)
          .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12)))
          .help(review.pr.waitingReason)
      }
    }.font(.callout).fixedSize()
  }
}

/// GitHub-style section tabs: icon, title and a count, with the selected tab underlined.
struct ReviewSectionTabs: View {
  @ObservedObject var review: ReviewModel
  let details: ReviewDetails
  var compact = false
  @State private var hovered: ReviewSection?

  var body: some View {
    HStack(spacing: 2) {
      ForEach(ReviewSection.allCases, id: \.self) { section in
        let selected = review.section == section
        Button {
          review.selectSection(section)
        } label: {
          HStack(spacing: 7) {
            Image(systemName: section.symbol).font(.system(size: 13)).foregroundStyle(
              selected ? .primary : .secondary)
            if !compact { Text(section.title).fontWeight(selected ? .semibold : .regular) }
            if let count = count(section) {
              Text("\(count)").font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(badgeColor(section) ?? .secondary)
                .padding(.horizontal, 7).padding(.vertical, 1.5)
                .background(
                  (badgeColor(section) ?? .primary).opacity(badgeColor(section) == nil ? 0.1 : 0.16),
                  in: Capsule())
            }
          }
          .font(.callout)
          .padding(.horizontal, 12).padding(.vertical, 8)
          .background(
            hovered == section && !selected ? Color.primary.opacity(0.06) : .clear,
            in: RoundedRectangle(cornerRadius: 7)
          )
          .padding(.bottom, 6)
          .overlay(alignment: .bottom) {
            Rectangle().fill(selected ? Color.orange : .clear).frame(height: 2)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? section : (hovered == section ? nil : hovered) }
        .help(section.title)
      }
    }.fixedSize()
  }

  private func count(_ section: ReviewSection) -> Int? {
    switch section {
    case .conversation:
      details.comments.count + details.threads.count + details.reviews.filter { !$0.body.isEmpty }.count
    case .files: details.files.count
    case .checks: details.checks.isEmpty ? nil : details.checks.count
    case .commits: details.commits.count
    }
  }

  /// Checks turn red or yellow when something failed or is still running.
  private func badgeColor(_ section: ReviewSection) -> Color? {
    guard section == .checks else { return nil }
    let summary = details.checkSummary
    if summary.failed > 0 { return .red }
    if summary.pending > 0 { return .yellow }
    return nil
  }
}

/// GitHub-style changed-files tree: collapsible folders, indent guides and status icons.
struct ChangedFilesTree: View {
  @ObservedObject var review: ReviewModel
  let files: [PullRequestFile]
  @FocusState private var focused: Bool
  private let indent: CGFloat = 16
  private let rowHeight: CGFloat = 26

  var body: some View {
    let rows = FileTree.rows(for: files, collapsed: review.collapsedFolders)
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(rows) { row in
            rowView(row).id(row.id)
          }
        }
        .padding(.vertical, 6)
      }
      .background(Color(nsColor: .controlBackgroundColor))
      .focusable()
      .focusEffectDisabled()
      .focused($focused)
      .onKeyPress(.downArrow) { move(1, rows: rows, proxy: proxy) }
      .onKeyPress(.upArrow) { move(-1, rows: rows, proxy: proxy) }
    }
  }

  private func rowView(_ row: FileTreeRow) -> some View {
    let selected = !row.isFolder && review.selectedFile == row.path
    return HStack(spacing: 6) {
      switch row.kind {
      case .folder(let expanded):
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(expanded ? 90 : 0))
          .frame(width: 12)
        Image(systemName: "folder.fill").foregroundStyle(.secondary)
        Text(row.name).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 0)
      case .file(let file):
        Color.clear.frame(width: 12)
        statusIcon(file.status)
        Text(row.name).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 4)
        if file.additions > 0 { Text("+\(file.additions)").foregroundStyle(.green) }
        if file.deletions > 0 { Text("-\(file.deletions)").foregroundStyle(.red) }
      }
    }
    .font(.system(size: 12.5))
    .monospacedDigit()
    .padding(.leading, 8 + CGFloat(row.depth) * indent)
    .padding(.trailing, 10)
    .frame(height: rowHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(alignment: .leading) { guides(depth: row.depth) }
    .background {
      RoundedRectangle(cornerRadius: 6)
        .fill(selected ? Color.accentColor.opacity(focused ? 0.35 : 0.2) : .clear)
        .padding(.horizontal, 4)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      focused = true
      if row.isFolder {
        withAnimation(.easeOut(duration: 0.12)) {
          if review.collapsedFolders.contains(row.path) {
            review.collapsedFolders.remove(row.path)
          } else {
            review.collapsedFolders.insert(row.path)
          }
        }
      } else {
        review.selectedFile = row.path
      }
    }
    .help(row.path)
  }

  /// One vertical line per ancestor folder, aligned under its chevron.
  private func guides(depth: Int) -> some View {
    ZStack(alignment: .leading) {
      ForEach(0..<depth, id: \.self) { level in
        Rectangle()
          .fill(Color.primary.opacity(0.12))
          .frame(width: 1)
          .offset(x: 8 + 6 + CGFloat(level) * indent)
      }
    }
    .frame(maxHeight: .infinity)
  }

  private func statusIcon(_ status: String) -> some View {
    let (symbol, color): (String, Color) =
      switch status {
      case "added": ("plus.square", .green)
      case "removed": ("minus.square", .red)
      case "renamed": ("arrow.right.square", .blue)
      default: ("dot.square", .orange)
      }
    return Image(systemName: symbol).foregroundStyle(color).help(status.capitalized)
  }

  private func move(_ delta: Int, rows: [FileTreeRow], proxy: ScrollViewProxy) -> KeyPress.Result {
    let paths = rows.filter { !$0.isFolder }.map(\.path)
    guard !paths.isEmpty else { return .ignored }
    let current = review.selectedFile.flatMap { paths.firstIndex(of: $0) } ?? (delta > 0 ? -1 : paths.count)
    let next = paths[min(max(current + delta, 0), paths.count - 1)]
    review.selectedFile = next
    proxy.scrollTo("file:" + next)
    return .handled
  }
}

/// One line per related PR, like Linear's linked-diff list: stage icon, target branch, title.
struct RelatedPRRow: View {
  let pr: PullRequest
  let current: PullRequest
  let open: () -> Void
  @State private var hovering = false

  var body: some View {
    let status = YardPalette.status(pr)
    Button(action: open) {
      HStack(spacing: 7) {
        Image(systemName: status.symbol).foregroundStyle(status.color).frame(width: 16)
        Text(pr.base).font(.caption.monospaced().weight(.semibold))
          .foregroundStyle(Color.branchBlue)
          .padding(.horizontal, 5).padding(.vertical, 1)
          .background(Color.branchBlue.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
        if pr.repository != current.repository {
          Text(pr.repository.split(separator: "/").last.map(String.init) ?? pr.repository)
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        Text(pr.title).lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 6).padding(.vertical, 5)
      .background(Color.primary.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 6))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help("\(pr.displayTitle)\n\(pr.state == "OPEN" ? pr.stage.title : pr.state.capitalized) · into \(pr.base)")
  }
}

/// GitHub's stack map: top layer first, the trunk at the bottom, the current PR highlighted.
struct StackMap: View {
  @EnvironmentObject var app: AppModel
  @ObservedObject var review: ReviewModel
  let pr: PullRequest
  let stack: PRStack

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 5) {
        Image(systemName: "square.stack.3d.up.fill")
        Text("Stack #\(stack.number) · \(stack.readinessLabel)")
      }
      .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      .padding(.horizontal, 6).padding(.bottom, 2)
      ForEach(stack.entries.reversed()) { entry in
        row(entry, member: app.pullRequest(for: entry, stackOf: pr))
      }
      HStack(spacing: 7) {
        Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).frame(width: 16)
        Text(stack.base).font(.caption.monospaced().weight(.semibold)).foregroundStyle(Color.branchBlue)
      }.padding(.horizontal, 6).padding(.vertical, 4)
      let unrequested = stack.needingReviewer
      if !unrequested.isEmpty { reviewerCallout(unrequested) }
      if stack.needsRebase { rebaseCallout }
    }
    .padding(.horizontal, -6)
    .padding(.bottom, 4)
  }

  private func reviewerCallout(_ layers: [PRStack.Entry]) -> some View {
    let names = review.stackReviewerNames
    let none = names.isEmpty
    return callout(
      symbol: "person.crop.circle.badge.exclamationmark", color: .orange,
      text: layers.count == 1
        ? "\(layers[0].displayNumber) has no reviewer. GitHub won't merge the stack until every layer is approved."
        : "\(PRStack.list(layers.map(\.number))) have no reviewer. GitHub won't merge the stack until every layer is approved."
    ) {
      Button(none ? "Add reviewers here first" : "Request \(names)") {
        Task { await review.requestStackReviewers() }
      }
      .disabled(none || review.isDemo || review.isPerforming)
      .help(none
        ? "Request reviewers on this PR, then copy them to the other layers."
        : "Request review from \(names) on \(PRStack.list(layers.map(\.number))).")
    }
  }

  private var rebaseCallout: some View {
    callout(
      symbol: "arrow.triangle.2.circlepath", color: .orange,
      text: "The stack isn't linear anymore. GitHub needs a rebase before it can merge."
    ) {
      Link("Rebase stack on GitHub", destination: pr.url)
    }
  }

  private func callout<Action: View>(
    symbol: String, color: Color, text: String, @ViewBuilder action: () -> Action
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: symbol).foregroundStyle(color)
        Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
      }
      action().controlSize(.small)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.3)))
    .padding(.horizontal, 6).padding(.top, 4)
  }

  static func status(_ entry: PRStack.Entry) -> (symbol: String, color: Color) {
    switch entry.state {
    case "MERGED": return ("arrow.triangle.merge", YardPalette.merged)
    case "CLOSED": return ("xmark.circle", YardPalette.closed)
    default: break
    }
    if entry.isDraft { return ("pencil.circle", .secondary) }
    switch entry.problem {
    case nil: return ("checkmark.circle.fill", .green)
    case "Merge conflicts", "Changes requested", "Checks failing": return ("exclamationmark.circle.fill", .red)
    case "No reviewer", "Needs rebase": return ("exclamationmark.circle", .orange)
    default: return ("clock", YardPalette.blue)
    }
  }

  private func row(_ entry: PRStack.Entry, member: PullRequest) -> some View {
    let current = entry.number == pr.number
    let status = Self.status(entry)
    return Button {
      if !current { app.open(member) }
    } label: {
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 7) {
          Text(String(entry.position)).font(.caption2.monospacedDigit().weight(.bold))
            .foregroundStyle(current ? Color.white : .secondary)
            .frame(width: 16, height: 16)
            .background(current ? Color.accentColor : Color.primary.opacity(0.08), in: Circle())
          Image(systemName: status.symbol).foregroundStyle(status.color)
          Text(entry.displayNumber).monospacedDigit().foregroundStyle(.secondary)
          Text(entry.title).lineLimit(1).truncationMode(.tail)
            .fontWeight(current ? .semibold : .regular)
          Spacer(minLength: 0)
        }
        Text("\(entry.statusLabel) · \(entry.author)")
          .font(.caption).foregroundStyle(entry.problem == nil ? Color.secondary : status.color)
          .padding(.leading, 23 + 7 + 16)
      }
      .padding(.horizontal, 6).padding(.vertical, 5)
      .background(current ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("\(entry.displayNumber) \(entry.title)\n\(entry.head) → \(entry.base) · \(entry.statusLabel)")
  }
}
