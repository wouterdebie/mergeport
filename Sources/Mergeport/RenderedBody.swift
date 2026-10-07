import SwiftUI
import WebKit

final class ConversationWebView: WKWebView {
  private var scrollMonitor: Any?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stopMonitoringScroll()
    guard window != nil else { return }
    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      guard let self, let window = self.window, event.window === window,
        self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
        abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
        let scrollView = self.enclosingScrollView
      else { return event }
      scrollView.scrollWheel(with: event)
      return nil
    }
  }

  override func scrollWheel(with event: NSEvent) {
    if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
      let scrollView = enclosingScrollView {
      scrollView.scrollWheel(with: event)
    } else {
      super.scrollWheel(with: event)
    }
  }

  func stopMonitoringScroll() {
    if let scrollMonitor {
      NSEvent.removeMonitor(scrollMonitor)
      self.scrollMonitor = nil
    }
  }
}

/// Last measured height per rendered body, so a rebuilt view starts at its real size
/// instead of 80pt and doesn't make the conversation jump while it re-renders.
@MainActor
enum RenderedBodyHeights {
  private static var heights: [String: CGFloat] = [:]
  static func height(for html: String) -> CGFloat? { heights[html] }
  static func store(_ height: CGFloat, for html: String) {
    if heights.count > 2000 { heights.removeAll(keepingCapacity: true) }
    heights[html] = height
  }
}

struct RenderedBody: View {
  let text: String
  let html: String?
  @Environment(\.openURL) private var openURL
  @State private var height: CGFloat
  @State private var renderingError: String?

  init(text: String, html: String?) {
    self.text = text
    self.html = html
    _height = State(initialValue: html.flatMap(RenderedBodyHeights.height(for:)) ?? 80)
  }

  var bodyView: some View {
    Group {
      if let html, !html.isEmpty {
        HTMLBody(html: html, height: $height, error: $renderingError) { openURL($0) }
          .frame(height: height)
        if let renderingError {
          Text("Could not render this body: \(renderingError)").font(.caption).foregroundStyle(
            .orange)
          Text(text).font(.callout).textSelection(.enabled)
        }
      } else {
        Text(.init(text)).font(.callout).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  var body: some View { bodyView }
}

private struct HTMLBody: NSViewRepresentable {
  let html: String
  @Binding var height: CGFloat
  @Binding var error: String?
  let openLink: (URL) -> Void

  /// One ephemeral store for every body instead of a fresh one per comment.
  @MainActor private static let dataStore = WKWebsiteDataStore.nonPersistent()

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = Self.dataStore
    configuration.userContentController.add(context.coordinator, name: "bodyHeight")
    let view = ConversationWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.setValue(false, forKey: "drawsBackground")
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    context.coordinator.parent = self
    guard context.coordinator.html != html else { return }
    context.coordinator.html = html
    context.coordinator.isLoadingDocument = true
    if error != nil {
      DispatchQueue.main.async { context.coordinator.parent.error = nil }
    }
    let nonce = UUID().uuidString
    view.loadHTMLString(
      Self.document(html, nonce: nonce), baseURL: URL(string: "https://github.com"))
  }

  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    (view as? ConversationWebView)?.stopMonitoringScroll()
    view.configuration.userContentController.removeScriptMessageHandler(forName: "bodyHeight")
    view.navigationDelegate = nil
  }

  private static func document(_ html: String, nonce: String) -> String {
    """
    <!doctype html><html><head><meta name="viewport" content="width=device-width">
    <meta name="color-scheme" content="light dark">
    <meta name="referrer" content="no-referrer">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; script-src 'nonce-\(nonce)'; base-uri 'none'; form-action 'none';">
    <style>
    :root { color-scheme: light dark; --fg:#1f2328; --border:#d1d9e0; --code:#eff2f5; --link:#0969da; }
    @media(prefers-color-scheme:dark) {
      :root { --fg:#d1d7e0; --border:#3d444d; --code:#252c35; --link:#4493f8; }
    }
    * { box-sizing:border-box } html,body { margin:0; padding:0; overflow:hidden; background:transparent; }
    body { color:var(--fg); font:13px/1.6 -apple-system,BlinkMacSystemFont,sans-serif; overflow-wrap:anywhere; }
    #content { display:flow-root; }
    #content>:first-child { margin-top:0 } #content>:last-child { margin-bottom:0 }
    p,ul,ol,pre,table,blockquote,details { margin:0 0 16px }
    h1,h2 { border-bottom:1px solid var(--border); padding-bottom:8px }
    h1 { font-size:24px } h2 { font-size:20px } h3 { font-size:16px }
    a { color:var(--link); text-decoration:none } a:hover { text-decoration:underline }
    code,pre { font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; background:var(--code); border-radius:5px }
    code { padding:2px 5px } pre { padding:16px; overflow:auto; white-space:pre }
    pre code { padding:0; background:none }
    table { display:block; width:100%; overflow:auto; border-collapse:collapse }
    th,td { padding:8px 12px; border:1px solid var(--border) } th { font-weight:600 }
    tr:nth-child(2n) { background:var(--code) }
    blockquote { border-left:4px solid var(--border); padding:0 16px; opacity:.8 }
    img,video { max-width:100%; height:auto } hr { border:0; border-top:1px solid var(--border); margin:20px 0 }
    summary { cursor:pointer; font-weight:600 } details>summary { margin-bottom:8px }
    .task-list-item { list-style:none } input { pointer-events:none }
    .js-suggested-changes-blob { border:1px solid var(--border); border-radius:6px; overflow:hidden; margin:8px 0 16px }
    .js-suggested-changes-blob .border-bottom { border-bottom:1px solid var(--border); padding:6px 10px; font-size:12px; opacity:.75 }
    .js-suggested-changes-blob table { display:table; width:100%; margin:0; border-collapse:collapse }
    .js-suggested-changes-blob tr { background:none !important }
    .js-suggested-changes-blob td { border:0; padding:2px 8px; font:12px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace; white-space:pre-wrap; vertical-align:top }
    .blob-num { width:1%; min-width:44px; text-align:right; opacity:.65; user-select:none }
    .blob-num::before { content:attr(data-line-number) }
    .blob-num-deletion { background:rgba(248,81,73,.3) } .blob-code-deletion { background:rgba(248,81,73,.15) }
    .blob-num-addition { background:rgba(63,185,80,.3) } .blob-code-addition { background:rgba(46,160,67,.15) }
    .blob-code-marker-deletion::before { content:"- "; opacity:.7 } .blob-code-marker-addition::before { content:"+ "; opacity:.7 }
    .blob-code-deletion .x { background:rgba(255,129,130,.4); border-radius:2px }
    .blob-code-addition .x { background:rgba(46,160,67,.4); border-radius:2px }
    .pl-k { color:#cf222e } .pl-c1 { color:#0550ae } .pl-s,.pl-pds { color:#0a3069 } .pl-en { color:#6639ba } .pl-c { color:#59636e }
    @media(prefers-color-scheme:dark) {
      .pl-k { color:#ff7b72 } .pl-c1 { color:#79c0ff } .pl-s,.pl-pds { color:#a5d6ff } .pl-en { color:#d2a8ff } .pl-c { color:#9198a1 }
    }
    </style></head><body><div id="content">\(html)</div>
    <script nonce="\(nonce)">
    const content=document.getElementById('content');
    const resize=()=>window.webkit.messageHandlers.bodyHeight.postMessage(Math.ceil(content.getBoundingClientRect().height));
    new ResizeObserver(resize).observe(content);
    window.addEventListener('load',resize); resize();
    </script></body></html>
    """
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var parent: HTMLBody
    var html: String?
    var isLoadingDocument = true

    init(parent: HTMLBody) { self.parent = parent }

    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard message.frameInfo.isMainFrame, let number = message.body as? NSNumber,
        number.doubleValue.isFinite, number.doubleValue >= 0
      else { return }
      let height = max(1, CGFloat(number.doubleValue))
      if let html { RenderedBodyHeights.store(height, for: html) }
      if abs(parent.height - height) > 0.5 { parent.height = height }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
      -> WKNavigationActionPolicy
    {
      if navigationAction.navigationType == .linkActivated {
        if let url = navigationAction.request.url,
          ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
        {
          parent.openLink(url)
        }
        return .cancel
      } else {
        let url = navigationAction.request.url
        let initialDocument =
          url?.host == "github.com" && (url?.path.isEmpty == true || url?.path == "/")
        return isLoadingDocument && navigationAction.targetFrame?.isMainFrame != false
          && (url == nil || url?.scheme == "about" || initialDocument) ? .allow : .cancel
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      isLoadingDocument = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      NSLog("Mergeport HTML rendering: %@", error.localizedDescription)
      parent.error = error.localizedDescription
    }

    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      NSLog("Mergeport HTML rendering: %@", error.localizedDescription)
      parent.error = error.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      let message = "The HTML renderer stopped. Reload this review to try again."
      NSLog("Mergeport HTML rendering: %@", message)
      parent.error = message
    }
  }
}
