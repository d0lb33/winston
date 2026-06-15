//
//  ForwardEdgeSwipe.swift
//  winston
//
//  Trailing-edge swipe to "go forward" with a bitmap preview of the screen the user
//  just backed away from. The swipe is visual only until commit; the final navigation
//  uses the same `goForward()` path as the toolbar button, preserving SwiftUI's retained
//  detail/scroll state instead of rebuilding a duplicate preview tree.
//

import SwiftUI

private struct ForwardEdgeSwipeModifier: ViewModifier {
  /// Only the compact (phone / fold-closed) layout shows the full-screen interactive
  /// preview — in regular width the columns are already visible, so forward is the button.
  let isActive: Bool
  let canGoForward: () -> Bool
  let previewSnapshot: () -> UIImage?
  let goForward: () -> Void

  /// Live drag translation (negative = dragging left toward the incoming screen).
  @State private var dragX: CGFloat = 0
  @State private var activePreview: UIImage?
  @State private var activeTransitionID: UUID?
  @State private var isCommitting = false
  @GestureState private var gestureIsActive = false

  private let edgeWidth: CGFloat = 28
  private let commitThreshold: CGFloat = 80
  private let verticalTolerance: CGFloat = 80
  private let commitHoldDuration: TimeInterval = 0.46

  func body(content: Content) -> some View {
    if isActive {
      GeometryReader { proxy in
        let width = max(1, proxy.size.width)

        ZStack(alignment: .leading) {
          content
            .offset(x: activePreview == nil ? 0 : dragX * 0.28)

          if let activePreview {
            Image(uiImage: activePreview)
              .resizable()
              .scaledToFill()
              .frame(width: width, height: proxy.size.height)
              .clipped()
              .background(.background)
              .shadow(color: .black.opacity(0.18), radius: 16, x: -6, y: 0)
              .offset(x: max(0, width + dragX))
              .allowsHitTesting(false)
              .zIndex(1)
          }

          if canGoForward() || activePreview != nil {
            HStack(spacing: 0) {
              Spacer(minLength: 0)
              Color.clear
                .frame(width: edgeWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(dragGesture(width: width))
            }
            .zIndex(2)
          }
        }
        .onChange(of: gestureIsActive) { wasActive, isActive in
          if wasActive, !isActive {
            DispatchQueue.main.async {
              if activePreview != nil, !isCommitting {
                cancelDrag()
              }
            }
          }
        }
        .onDisappear {
          clearDragStateWithoutAnimation(matching: activeTransitionID)
        }
      }
    } else {
      content
    }
  }

  private func dragGesture(width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 12, coordinateSpace: .local)
      .updating($gestureIsActive) { _, state, _ in
        state = true
      }
      .onChanged { value in
        guard abs(value.translation.height) < 200 else { return }
        if activePreview == nil {
          guard let preview = previewSnapshot() else { return }
          activePreview = preview
          activeTransitionID = UUID()
        }
        dragX = max(-width, min(0, value.translation.width))
      }
      .onEnded { value in
        guard activePreview != nil else {
          cancelDrag()
          return
        }

        let passed = value.translation.width <= -commitThreshold
          && abs(value.translation.height) <= verticalTolerance

        if passed {
          commitDrag(width: width)
        } else {
          cancelDrag()
        }
      }
  }

  private func commitDrag(width: CGFloat) {
    let transitionID = activeTransitionID
    isCommitting = true

    withAnimation(.snappy(duration: 0.22)) {
      dragX = -width
    } completion: {
      goForward()
      scheduleCommitCleanup(matching: transitionID)
    }
    scheduleCommitCleanup(matching: transitionID, delay: 0.74)
  }

  private func cancelDrag() {
    let transitionID = activeTransitionID
    withAnimation(.snappy(duration: 0.18)) {
      dragX = 0
    } completion: {
      clearDragStateWithoutAnimation(matching: transitionID)
    }
    scheduleCommitCleanup(matching: transitionID, delay: 0.30)
  }

  private func clearDragState() {
    activePreview = nil
    activeTransitionID = nil
    isCommitting = false
    dragX = 0
  }

  private func clearDragStateWithoutAnimation(matching transitionID: UUID?) {
    guard activeTransitionID == transitionID else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      clearDragState()
    }
  }

  private func scheduleCommitCleanup(matching transitionID: UUID?, delay: TimeInterval? = nil) {
    DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? commitHoldDuration)) {
      clearDragStateWithoutAnimation(matching: transitionID)
    }
  }
}

extension View {
  /// Adds a trailing-edge "go forward" swipe using a retained bitmap of the screen that
  /// will be restored. Navigation is committed only after the swipe finishes.
  func forwardEdgeSwipe(
    isActive: Bool,
    canGoForward: @escaping () -> Bool,
    previewSnapshot: @escaping () -> UIImage?,
    goForward: @escaping () -> Void
  ) -> some View {
    modifier(ForwardEdgeSwipeModifier(isActive: isActive, canGoForward: canGoForward, previewSnapshot: previewSnapshot, goForward: goForward))
  }
}

final class ForwardEdgeSnapshotHost {
  weak var view: UIView?

  @MainActor
  func snapshot() -> UIImage? {
    guard let view,
          let target = view.window?.rootViewController?.view
    else { return nil }

    let rectInTarget = view.convert(view.bounds, to: target)
    let snapshotRect = rectInTarget.isEmpty ? target.bounds : rectInTarget.intersection(target.bounds)
    guard !snapshotRect.isEmpty else { return nil }

    let format = UIGraphicsImageRendererFormat()
    format.scale = target.window?.screen.scale ?? UIScreen.main.scale
    let renderer = UIGraphicsImageRenderer(size: snapshotRect.size, format: format)
    return renderer.image { _ in
      let drawRect = CGRect(
        x: -snapshotRect.minX,
        y: -snapshotRect.minY,
        width: target.bounds.width,
        height: target.bounds.height
      )
      target.drawHierarchy(in: drawRect, afterScreenUpdates: false)
    }
  }
}

struct ForwardEdgeSnapshotAccessor: UIViewRepresentable {
  let host: ForwardEdgeSnapshotHost

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.isUserInteractionEnabled = false
    host.view = view
    return view
  }

  func updateUIView(_ uiView: UIView, context: Context) {
    host.view = uiView
  }
}
