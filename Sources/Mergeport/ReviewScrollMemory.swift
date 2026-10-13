import AppKit
import SwiftUI

/// Keeps offsets in the cached review, not in the view recreated on every tab switch.
@MainActor
final class ReviewScrollMemory: NSObject {
    private weak var scroll: NSScrollView?
    private var review: ReviewModel?
    private var key = ReviewSection.conversation
    private var pending: CGPoint?
    private var restoring = false
    private var ready = false

    func attach(to scroll: NSScrollView, review: ReviewModel, key: ReviewSection) {
        guard self.scroll !== scroll else { return }
        detach()
        self.scroll = scroll
        self.review = review
        self.key = key
        pending = review.scrollOffsets[key]
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        scroll.documentView?.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(boundsChanged),
                           name: NSView.boundsDidChangeNotification, object: clip)
        center.addObserver(self, selector: #selector(restore),
                           name: NSView.frameDidChangeNotification, object: clip)
        center.addObserver(self, selector: #selector(restore),
                           name: NSView.frameDidChangeNotification, object: scroll.documentView)
        center.addObserver(self, selector: #selector(userStartedScrolling),
                           name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        DispatchQueue.main.async { [weak self, weak scroll] in
            guard let self, let scroll, self.scroll === scroll else { return }
            self.ready = true
            self.restore()
        }
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        scroll = nil
        review = nil
        pending = nil
        ready = false
    }

    /// Explicit file/anchor navigation takes precedence over an offset still awaiting layout.
    func cancelRestoration() { pending = nil }

    @objc private func userStartedScrolling() { cancelRestoration() }

    @objc private func boundsChanged() {
        guard ready, !restoring, let scroll else { return }
        if pending != nil {
            restore()
        } else {
            review?.scrollOffsets[key] = scroll.contentView.bounds.origin
        }
    }

    @objc func restore() {
        guard ready, !restoring, let target = pending, let scroll,
              let document = scroll.documentView else { return }
        let clip = scroll.contentView
        guard clip.bounds.width > 0, clip.bounds.height > 0 else { return }
        let maximum = CGPoint(
            x: max(0, document.frame.width - clip.bounds.width),
            y: max(0, document.frame.height - clip.bounds.height))
        let offset = CGPoint(x: min(max(0, target.x), maximum.x),
                             y: min(max(0, target.y), maximum.y))
        restoring = true
        clip.scroll(to: offset)
        scroll.reflectScrolledClipView(clip)
        restoring = false
        // HTML cards can grow after the initial layout. Do not replace the saved offset
        // with a temporarily clamped one while their heights are being restored.
        if target.x <= maximum.x, target.y <= maximum.y {
            pending = nil
            review?.scrollOffsets[key] = offset
        }
    }
}

struct ReviewScrollProbe: NSViewRepresentable {
    let review: ReviewModel
    let key: ReviewSection
    var navigating = false

    func makeNSView(context: Context) -> Probe {
        Probe(review: review, key: key)
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.connect()
        if navigating { view.memory.cancelRestoration() }
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) {
        view.memory.detach()
    }

    final class Probe: NSView {
        let memory = ReviewScrollMemory()
        private let review: ReviewModel
        private let key: ReviewSection

        init(review: ReviewModel, key: ReviewSection) {
            self.review = review
            self.key = key
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            connect()
        }

        override func layout() {
            super.layout()
            connect()
            memory.restore()
        }

        func connect() {
            guard window != nil, let scroll = enclosingScrollView else { return }
            memory.attach(to: scroll, review: review, key: key)
        }
    }
}
