import SwiftUI

#if os(iOS)
  import UIKit
#endif

/// A screen-edge recognizer avoids competing with the transcript's vertical ScrollView drag.
struct HistoryEdgeSwipe: ViewModifier {
  let enabled: Bool
  let open: () -> Void
  func body(content: Content) -> some View {
    #if os(iOS)
      content.background(HistoryEdgeHost(enabled: enabled, open: open).frame(width: 0, height: 0))
    #else
      content
    #endif
  }
}

#if os(iOS)
  private struct HistoryEdgeHost: UIViewRepresentable {
    let enabled: Bool
    let open: () -> Void
    func makeUIView(context: Context) -> EdgeView { EdgeView() }
    func updateUIView(_ view: EdgeView, context: Context) {
      view.open = open
      view.edge.isEnabled = enabled
    }
    static func dismantleUIView(_ view: EdgeView, coordinator: ()) { view.detach() }

    final class EdgeView: UIView, UIGestureRecognizerDelegate {
      var open: (() -> Void)?
      private weak var attachedWindow: UIWindow?
      lazy var edge: UIScreenEdgePanGestureRecognizer = {
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(dragged))
        edge.edges = .left
        edge.cancelsTouchesInView = false
        edge.delegate = self
        return edge
      }()
      override func didMoveToWindow() {
        super.didMoveToWindow()
        detach()
        attachedWindow = window
        window?.addGestureRecognizer(edge)
      }
      func detach() {
        attachedWindow?.removeGestureRecognizer(edge)
        attachedWindow = nil
      }
      @objc private func dragged() {
        guard edge.state == .began || edge.state == .changed else { return }
        let offset = edge.translation(in: attachedWindow)
        if offset.x > 30, offset.x > abs(offset.y) * 1.5 { open?() }
      }
      override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        attachedWindow?.rootViewController?.presentedViewController == nil
      }
      func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
      ) -> Bool { true }
    }
  }
#endif
