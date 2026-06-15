//
//  ForwardEdgeSwipe.swift
//  winston
//
//  Trailing-edge swipe to "go forward". The gesture commits through the same
//  `goForward()` path as the toolbar button.
//

import SwiftUI

@MainActor
protocol ForwardEdgeNavigating: AnyObject {
  var canGoForward: Bool { get }
  func goForward()
}

private struct ForwardEdgeSwipeModifier: ViewModifier {
  /// Only the compact (phone / fold-closed) layout shows the trailing-edge forward
  /// gesture. In regular width the columns are already visible, so forward is the button.
  let isActive: Bool
  let canGoForward: () -> Bool
  let goForward: () -> Void

  private let edgeWidth: CGFloat = 28
  private let commitThreshold: CGFloat = 80
  private let verticalTolerance: CGFloat = 80

  func body(content: Content) -> some View {
    if isActive {
      ZStack(alignment: .leading) {
        content

        if canGoForward() {
          HStack(spacing: 0) {
            Spacer(minLength: 0)
            Color.clear
              .frame(width: edgeWidth)
              .frame(maxHeight: .infinity)
              .contentShape(Rectangle())
              .gesture(dragGesture)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .zIndex(1)
        }
      }
    } else {
      content
    }
  }

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 12, coordinateSpace: .local)
      .onEnded { value in
        guard value.translation.width <= -commitThreshold,
              abs(value.translation.height) <= verticalTolerance
        else { return }
        goForward()
      }
  }
}

extension View {
  /// Adds a trailing-edge "go forward" swipe. Navigation is committed only after the
  /// swipe finishes.
  func forwardEdgeSwipe(
    isActive: Bool,
    canGoForward: @escaping () -> Bool,
    goForward: @escaping () -> Void
  ) -> some View {
    modifier(ForwardEdgeSwipeModifier(isActive: isActive, canGoForward: canGoForward, goForward: goForward))
  }

  func forwardEdgeSwipe<Navigation: ForwardEdgeNavigating>(
    isActive: Bool,
    navigation: Navigation
  ) -> some View {
    forwardEdgeSwipe(
      isActive: isActive,
      canGoForward: { navigation.canGoForward },
      goForward: { navigation.goForward() }
    )
  }
}
