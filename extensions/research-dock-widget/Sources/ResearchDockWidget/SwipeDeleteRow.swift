import AppKit
import SwiftUI

private typealias SwipeState<Value> = SwiftUI.State<Value>

/// Owns the action's rendering instead of relying on AppKit's swipe-action tinting.
struct SwipeDeleteRow<Content: View>: View {
    let remove: () -> Void
    @ViewBuilder let content: () -> Content
    @SwipeState<CGFloat> private var distance: CGFloat
    @SwipeState<CGFloat?> private var dragStart: CGFloat?
    private let actionWidth: CGFloat = 88

    init(revealed: Bool = false, remove: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.remove = remove; self.content = content
        _distance = SwipeState(wrappedValue: revealed ? 88 : 0)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if distance > 0 {
                Button(action: remove) {
                    Text("Delete")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .frame(width: 76, height: 34)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .frame(width: min(distance, actionWidth), alignment: .trailing)
                .clipped()
                .accessibilityLabel("Delete article")
            }
            content()
                .allowsHitTesting(distance == 0)
                .offset(x: -distance)
                .mask(Rectangle().padding(.trailing, min(distance, actionWidth)))
        }
        .clipped()
        .background(TrackpadSwipeRegion(changed: { delta in
            distance = min(actionWidth, max(0, distance - delta))
        }, ended: { cancelled in
            settle(cancelled: cancelled)
        }))
        .simultaneousGesture(DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if dragStart == nil { dragStart = distance }
                distance = min(actionWidth, max(0, (dragStart ?? 0) - value.translation.width))
            }
            .onEnded { _ in
                guard dragStart != nil else { return }
                dragStart = nil
                settle(cancelled: false)
            })
        .accessibilityAction(named: "Delete article", remove)
    }

    private func settle(cancelled: Bool) {
        withAnimation(.easeOut(duration: 0.16)) {
            distance = !cancelled && distance >= actionWidth / 3 ? actionWidth : 0
        }
    }
}

/// Trackpad swipes arrive as scroll-wheel events on macOS, not DragGesture events.
/// Vertical scrolling is always passed through to the enclosing list.
private struct TrackpadSwipeRegion: NSViewRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (Bool) -> Void
    func makeNSView(context: Context) -> Region { Region() }
    func updateNSView(_ view: Region, context: Context) {
        view.changed = changed; view.ended = ended
    }
    static func dismantleNSView(_ view: Region, coordinator: ()) { view.uninstall() }

    final class Region: NSView {
        var changed: ((CGFloat) -> Void)?
        var ended: ((Bool) -> Void)?
        private var monitor: Any?
        private var tracking = false
        private var vertical = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            uninstall()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(event) == nil
                }
                return consumed ? nil : event
            }
        }
        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil; tracking = false; vertical = false
        }
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.window === window, window != nil else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard tracking || visibleRect.contains(point) else { return event }
            if event.phase.contains(.began) { vertical = false }
            if !tracking && !vertical {
                let x = abs(event.scrollingDeltaX), y = abs(event.scrollingDeltaY)
                if y > x && y > 0 { vertical = true }
                else if x > y && x > 0 && event.momentumPhase.isEmpty { tracking = true }
            }
            guard tracking else { return event }
            if event.phase.contains(.cancelled) || event.phase.contains(.ended) {
                tracking = false
                ended?(event.phase.contains(.cancelled))
            } else if event.momentumPhase.isEmpty {
                changed?(event.scrollingDeltaX)
                // Non-phase wheel devices can still reveal the action.
                if event.phase.isEmpty { tracking = false; ended?(false) }
            }
            return nil
        }
    }
}
