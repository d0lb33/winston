//
//  RedditSplitNavigation.swift
//  winston
//
//  Shared routing state for Reddit split-view surfaces. Content-column taps keep
//  browsing destinations in the content stack and send posts/comments to detail;
//  detail-column taps stay in the detail stack.
//

import SwiftUI

enum RedditNavigationOrigin: Equatable {
  case content
  case detail
}

@Observable
@MainActor
final class RedditSplitNavigationModel {
  var columnVisibility: NavigationSplitViewVisibility = .all
  var preferredColumn: NavigationSplitViewColumn
  var selectedPostID: String?
  var detailPost: Post?
  var detailHighlightID: String?
  var contentPath: [Router.NavDest] = []

  @ObservationIgnored private weak var router: Router?
  private let contentColumn: NavigationSplitViewColumn

  init(contentColumn: NavigationSplitViewColumn) {
    self.contentColumn = contentColumn
    self.preferredColumn = contentColumn
  }

  func attach(router: Router) {
    self.router = router
  }

  private var targetRouter: Router {
    router ?? Nav.shared.activeRouter
  }

  func navigate(_ destination: Router.NavDest, from origin: RedditNavigationOrigin) {
    switch origin {
    case .content:
      navigateFromContent(destination)
    case .detail:
      targetRouter.navigateTo(destination)
      focusDetail()
    }
  }

  func navigateFromContent(_ destination: Router.NavDest) {
    switch postDetail(from: destination) {
    case .some(let detail):
      openPostInDetail(detail.post, highlightID: detail.highlightID)
    case .none:
      contentPath.append(destination)
      focusContent()
    }
  }

  @discardableResult
  func absorbRootNavigationPathIfNeeded(router: Router) -> Bool {
    guard selectedPostID == nil,
          detailPost == nil,
          let destination = router.fullPath.first
    else { return false }

    if let detail = postDetail(from: destination) {
      detailPost = detail.post
      detailHighlightID = detail.highlightID
      router.fullPath = Array(router.fullPath.dropFirst())
      focusDetail()
      return true
    }

    guard isContentDestination(destination) else { return false }
    contentPath.append(destination)
    router.fullPath = Array(router.fullPath.dropFirst())
    focusContent()
    return true
  }

  func openPostInDetail(_ post: Post, highlightID: String? = nil) {
    selectedPostID = nil
    detailPost = post
    detailHighlightID = highlightID
    if !targetRouter.fullPath.isEmpty {
      targetRouter.fullPath = []
    }
    focusDetail()
  }

  func selectFeedPost(_ post: Post?) {
    guard let post else { return }
    detailPost = post
    detailHighlightID = nil
    if !targetRouter.fullPath.isEmpty {
      targetRouter.fullPath = []
    }
    focusDetail()
  }

  func resetDetail() {
    selectedPostID = nil
    detailPost = nil
    detailHighlightID = nil
    if !targetRouter.fullPath.isEmpty {
      targetRouter.fullPath = []
    }
  }

  func resetContentPathAndDetail() {
    contentPath = []
    resetDetail()
    focusContent()
  }

  func focusContent() {
    withAnimation {
      preferredColumn = contentColumn
      columnVisibility = .doubleColumn
    }
  }

  func focusDetail() {
    preferredColumn = .detail
  }

  func postDetail(from destination: Router.NavDest) -> (post: Post, highlightID: String?)? {
    guard case .reddit(let reddit) = destination else { return nil }
    switch reddit {
    case .post(let post):
      return (post, nil)
    case .postHighlighted(let post, let highlightID):
      return (post, highlightID)
    default:
      return nil
    }
  }

  private func isContentDestination(_ destination: Router.NavDest) -> Bool {
    guard case .reddit(let reddit) = destination else { return false }
    switch reddit {
    case .post, .postHighlighted:
      return false
    case .subFeed, .subInfo, .multiFeed, .multiInfo, .user:
      return true
    }
  }
}

private struct RedditNavigationModelKey: EnvironmentKey {
  static let defaultValue: RedditSplitNavigationModel? = nil
}

private struct RedditNavigationOriginKey: EnvironmentKey {
  static let defaultValue: RedditNavigationOrigin = .detail
}

extension EnvironmentValues {
  var redditNavigationModel: RedditSplitNavigationModel? {
    get { self[RedditNavigationModelKey.self] }
    set { self[RedditNavigationModelKey.self] = newValue }
  }

  var redditNavigationOrigin: RedditNavigationOrigin {
    get { self[RedditNavigationOriginKey.self] }
    set { self[RedditNavigationOriginKey.self] = newValue }
  }
}

extension View {
  func redditNavigation(_ model: RedditSplitNavigationModel, origin: RedditNavigationOrigin) -> some View {
    self
      .environment(\.redditNavigationModel, model)
      .environment(\.redditNavigationOrigin, origin)
  }
}

@MainActor
func navigateRedditDestination(
  _ destination: Router.NavDest,
  model: RedditSplitNavigationModel?,
  origin: RedditNavigationOrigin
) {
  if let model {
    model.navigate(destination, from: origin)
  } else {
    Nav.to(destination)
  }
}
