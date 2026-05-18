import AppKit
import SwiftUI

struct EnclosingNSScrollViewReader: NSViewRepresentable {
    var onResolve: (NSScrollView) -> Void
    var onScroll: ((NSScrollView) -> Void)?

    func makeNSView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.onResolve = onResolve
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        nsView.onResolve = onResolve
        nsView.onScroll = onScroll
        nsView.resolveIfPossible()
    }

    @MainActor
    final class ResolverView: NSView {
        var onResolve: ((NSScrollView) -> Void)?
        var onScroll: ((NSScrollView) -> Void)?
        private weak var lastResolvedScrollView: NSScrollView?
        private weak var observedContentView: NSClipView?
        private var pendingResolveRetry = false
        private var resolveRetryCount = 0

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveRetryCount = 0
            resolveIfPossible()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            resolveRetryCount = 0
            resolveIfPossible()
        }

        func resolveIfPossible() {
            guard let scrollView = resolveScrollView() else {
                scheduleResolveRetry()
                return
            }
            pendingResolveRetry = false
            resolveRetryCount = 0
            if scrollView === lastResolvedScrollView { return }
            lastResolvedScrollView = scrollView
            observeBoundsChanges(in: scrollView)
            onResolve?(scrollView)
        }

        private func scheduleResolveRetry() {
            guard window != nil else { return }
            guard !pendingResolveRetry else { return }
            guard resolveRetryCount < 8 else { return }
            resolveRetryCount += 1
            pendingResolveRetry = true
            DispatchQueue.main.async { [weak self] in
                self?.pendingResolveRetry = false
                self?.resolveIfPossible()
            }
        }

        private func observeBoundsChanges(in scrollView: NSScrollView) {
            removeBoundsObservers()

            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.contentView.postsFrameChangedNotifications = true
            observedContentView = scrollView.contentView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(contentViewBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(contentViewFrameDidChange),
                name: NSView.frameDidChangeNotification,
                object: scrollView.contentView
            )
        }

        private func removeBoundsObservers() {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedContentView
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.frameDidChangeNotification,
                object: observedContentView
            )
            observedContentView = nil
        }

        @objc
        private func contentViewBoundsDidChange() {
            guard let scrollView = lastResolvedScrollView else { return }
            onScroll?(scrollView)
        }

        @objc
        private func contentViewFrameDidChange() {
            guard let scrollView = lastResolvedScrollView else { return }
            onScroll?(scrollView)
        }

        private func resolveScrollView() -> NSScrollView? {
            if let enclosing = enclosingScrollView() {
                return enclosing
            }
            return overlappingScrollViewInWindow()
        }

        private func enclosingScrollView() -> NSScrollView? {
            var current: NSView? = superview
            while let view = current {
                if let scrollView = view as? NSScrollView {
                    return scrollView
                }
                current = view.superview
            }
            return nil
        }

        private func overlappingScrollViewInWindow() -> NSScrollView? {
            guard let contentView = window?.contentView else { return nil }
            let probeRect = convert(bounds.isEmpty ? NSRect(origin: .zero, size: CGSize(width: 1, height: 1)) : bounds, to: nil)
            let probePoint = NSPoint(x: probeRect.midX, y: probeRect.midY)

            let candidates = scrollViews(in: contentView).filter { scrollView in
                guard scrollView.window === window, !scrollView.isHidden else { return false }
                let rectInWindow = scrollView.convert(scrollView.bounds, to: nil)
                return rectInWindow.contains(probePoint)
            }

            return candidates.min { lhs, rhs in
                let lhsArea = lhs.bounds.width * lhs.bounds.height
                let rhsArea = rhs.bounds.width * rhs.bounds.height
                return lhsArea < rhsArea
            }
        }

        private func scrollViews(in root: NSView) -> [NSScrollView] {
            var matches: [NSScrollView] = []
            if let scrollView = root as? NSScrollView {
                matches.append(scrollView)
            }
            for subview in root.subviews {
                matches.append(contentsOf: scrollViews(in: subview))
            }
            return matches
        }
    }
}
