//
//  RedditForwardNavigationGesture.swift
//  winston
//
//  Restores recently popped Reddit detail destinations from the trailing screen
//  edge. This mirrors the existing leading-edge back interaction without making
//  the rest of the screen compete with post/comment swipe actions.
//

import SwiftUI

private struct RedditForwardNavigationGestureModifier<ContentPreview: View>: ViewModifier {
  let navigation: RedditSplitNavigationModel
  @ViewBuilder var contentPreview: () -> ContentPreview

  @State private var activeRoute: RedditForwardRoute?
  @State private var dragTranslation: CGFloat = 0

  private let edgeWidth: CGFloat = 32
  private let horizontalThreshold: CGFloat = 72
  private let verticalTolerance: CGFloat = 80

  private var canNavigateForward: Bool {
    navigation.nextForwardRoute != nil
  }

  func body(content: Content) -> some View {
    GeometryReader { proxy in
      ZStack(alignment: .trailing) {
        content
          .offset(x: activeRoute == nil ? 0 : dragTranslation * 0.28)

        if let route = activeRoute, dragTranslation < 0 {
          preview(for: route)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(.background)
            .clipShape(Rectangle())
            .shadow(color: .black.opacity(0.22), radius: 18, x: -8, y: 0)
            .offset(x: max(0, proxy.size.width + dragTranslation))
            .allowsHitTesting(false)
        }

        if canNavigateForward {
          Color.clear
            .contentShape(Rectangle())
            .frame(width: edgeWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .ignoresSafeArea(.container, edges: .trailing)
            .highPriorityGesture(forwardGesture(screenWidth: proxy.size.width))
        }
      }
    }
  }

  private func forwardGesture(screenWidth: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 24, coordinateSpace: .local)
      .onChanged { value in
        guard let route = activeRoute ?? navigation.nextForwardRoute else { return }
        activeRoute = route
        dragTranslation = max(-screenWidth, min(0, value.translation.width))
      }
      .onEnded { value in
        let route = activeRoute ?? navigation.nextForwardRoute
        guard value.translation.width <= -horizontalThreshold,
              abs(value.translation.height) <= verticalTolerance,
              route != nil
        else {
          cancelDrag()
          return
        }

        _ = navigation.restoreNextForwardRoute()
        clearDragStateWithoutAnimation()
      }
  }

  @ViewBuilder private func preview(for route: RedditForwardRoute) -> some View {
    switch route {
    case .contentColumn:
      contentPreview()
    case .detail:
      RedditForwardDetailPreview(navigation: navigation)
    case .destination(let destination):
      RouterDestinationView(destination: destination)
        .redditNavigation(navigation, origin: .detail)
    }
  }

  private func cancelDrag() {
    withAnimation(.easeOut(duration: 0.16)) {
      dragTranslation = 0
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
      if dragTranslation == 0 {
        activeRoute = nil
      }
    }
  }

  private func clearDragStateWithoutAnimation() {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      activeRoute = nil
      dragTranslation = 0
    }
  }
}

extension View {
  func redditForwardNavigationGesture<ContentPreview: View>(
    navigation: RedditSplitNavigationModel,
    @ViewBuilder contentPreview: @escaping () -> ContentPreview
  ) -> some View {
    modifier(RedditForwardNavigationGestureModifier(navigation: navigation, contentPreview: contentPreview))
  }
}

private struct RedditForwardDetailPreview: View {
  let navigation: RedditSplitNavigationModel

  var body: some View {
    if let post = navigation.detailPost {
      AuroraPostDetail(
        post: post,
        subreddit: detailSubreddit(for: post),
        highlightID: navigation.detailHighlightID
      )
      .redditNavigation(navigation, origin: .detail)
    } else {
      AuroraDetailPlaceholder()
    }
  }

  private func detailSubreddit(for post: Post) -> Subreddit {
    if let name = post.data?.subreddit, !name.isEmpty {
      return Subreddit(id: name)
    }
    return post.winstonData?.subreddit ?? Subreddit(id: "")
  }
}
