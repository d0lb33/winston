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

enum RedditForwardRoute: Hashable {
  case contentColumn
  case detail(Router.NavDest)
  case destination(Router.NavDest)

  @MainActor
  var diagnosticsName: String {
    switch self {
    case .contentColumn:
      return "contentColumn"
    case .detail(let destination):
      return "detail.\(destination.diagnosticsName)"
    case .destination(let destination):
      return "destination.\(destination.diagnosticsName)"
    }
  }
}

extension RedditNavigationOrigin {
  var diagnosticsName: String {
    switch self {
    case .content: return "content"
    case .detail: return "detail"
    }
  }
}

extension NavigationSplitViewColumn {
  var diagnosticsName: String {
    switch self {
    case .sidebar: return "sidebar"
    case .content: return "content"
    case .detail: return "detail"
    default: return "unknown"
    }
  }
}

extension NavigationSplitViewVisibility {
  var diagnosticsName: String {
    switch self {
    case .automatic: return "automatic"
    case .all: return "all"
    case .doubleColumn: return "doubleColumn"
    case .detailOnly: return "detailOnly"
    default: return "unknown"
    }
  }
}

/// Abstraction over a surface's navigation sink. Link/card taps route destinations
/// through `navigateRedditDestination`, which calls into whichever navigator the surface
/// injected via `.redditNavigation(_:origin:)` — the legacy `RedditSplitNavigationModel`
/// (Me/Search/Settings) or the native `PostsNav` (Posts). This keeps the ~44 link call
/// sites decoupled from any concrete model, so the implementation can be swapped per
/// surface without touching them.
@MainActor
protocol RedditNavigator: AnyObject {
  func navigate(_ destination: Router.NavDest, from origin: RedditNavigationOrigin)
}

extension RedditSplitNavigationModel: RedditNavigator {}

@Observable
@MainActor
final class RedditSplitNavigationModel {
  var columnVisibility: NavigationSplitViewVisibility = .all
  var preferredColumn: NavigationSplitViewColumn
  var selectedPostID: String?
  var detailPost: Post?
  var detailHighlightID: String?
  var contentPath: [Router.NavDest] = []
  private(set) var forwardRoutes: [RedditForwardRoute] = []

  var nextForwardRoute: RedditForwardRoute? {
    forwardRoutes.last
  }

  @ObservationIgnored private weak var router: Router?
  @ObservationIgnored private var suppressNextRouterPopRecord = false
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
    AppDiagnostics.asyncBreadcrumb(
      "RedditSplitNavigation.navigate",
      metadata: diagnosticsMetadata(extra: [
        "destination": destination.diagnosticsName,
        "origin": origin.diagnosticsName
      ])
    )
    switch origin {
    case .content:
      navigateFromContent(destination)
    case .detail:
      clearForwardRoutes()
      targetRouter.navigateTo(destination)
      focusDetail()
    }
  }

  func navigateFromContent(_ destination: Router.NavDest) {
    switch postDetail(from: destination) {
    case .some(let detail):
      openPostInDetail(detail.post, highlightID: detail.highlightID)
    case .none:
      clearForwardRoutes()
      clearDetailForContentNavigation(to: destination)
      contentPath.append(destination)
      AppDiagnostics.asyncBreadcrumb(
        "RedditSplitNavigation.contentPath.append",
        metadata: diagnosticsMetadata(extra: ["destination": destination.diagnosticsName])
      )
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
      replaceRouterPathWithoutForwardRecording(Array(router.fullPath.dropFirst()))
      focusDetail()
      return true
    }

    guard isContentDestination(destination) else { return false }
    contentPath.append(destination)
    replaceRouterPathWithoutForwardRecording(Array(router.fullPath.dropFirst()))
    focusContent()
    return true
  }

  func openPostInDetail(_ post: Post, highlightID: String? = nil) {
    AppDiagnostics.asyncBreadcrumb(
      "RedditSplitNavigation.openPostInDetail",
      metadata: diagnosticsMetadata(extra: [
        "post": post.id,
        "highlightID": highlightID ?? "nil"
      ])
    )
    clearForwardRoutes()
    selectedPostID = nil
    detailPost = post
    detailHighlightID = highlightID
    resetRouterPathWithoutForwardRecording()
    focusDetail()
  }

  func selectFeedPost(_ post: Post?) {
    guard let post else { return }
    AppDiagnostics.asyncBreadcrumb(
      "RedditSplitNavigation.selectFeedPost",
      metadata: diagnosticsMetadata(extra: ["post": post.id])
    )
    clearForwardRoutes()
    detailPost = post
    detailHighlightID = nil
    resetRouterPathWithoutForwardRecording()
    focusDetail()
  }

  func resetDetail() {
    AppDiagnostics.asyncBreadcrumb(
      "RedditSplitNavigation.resetDetail",
      metadata: diagnosticsMetadata()
    )
    selectedPostID = nil
    detailPost = nil
    detailHighlightID = nil
    clearForwardRoutes()
    resetRouterPathWithoutForwardRecording()
  }

  func recordRouterPathChange(from oldPath: [Router.NavDest], to newPath: [Router.NavDest]) {
    if suppressNextRouterPopRecord {
      suppressNextRouterPopRecord = false
      return
    }

    guard oldPath.count > newPath.count,
          Array(oldPath.prefix(newPath.count)) == newPath
    else { return }

    let poppedRoutes = oldPath
      .dropFirst(newPath.count)
      .reversed()
      .map { RedditForwardRoute.destination($0) }
    appendForwardRoutes(poppedRoutes)
  }

  func recordPreferredColumnChange(from oldColumn: NavigationSplitViewColumn, to newColumn: NavigationSplitViewColumn) {
    if oldColumn == contentColumn,
       newColumn == .sidebar,
       contentColumn == .content,
       targetRouter.fullPath.isEmpty {
      appendForwardRoutes([.contentColumn])
      return
    }

    guard oldColumn == .detail,
          newColumn != .detail,
          targetRouter.fullPath.isEmpty,
          let destination = currentDetailDestination()
    else { return }

    appendForwardRoutes([.detail(destination)])
  }

  @discardableResult
  func restoreNextForwardRoute(animated: Bool = true) -> Bool {
    guard let route = forwardRoutes.popLast() else { return false }

    AppDiagnostics.asyncBreadcrumb(
      "RedditSplitNavigation.restoreForwardRoute",
      metadata: diagnosticsMetadata(extra: ["route": route.diagnosticsName])
    )

    switch route {
    case .contentColumn:
      focusContent(animated: animated)
      return true
    case .detail(let destination):
      guard let detail = postDetail(from: destination) else { return false }
      selectedPostID = nil
      detailPost = detail.post
      detailHighlightID = detail.highlightID
      focusDetail(animated: animated)
      return true
    case .destination(let destination):
      targetRouter.navigateTo(destination, animated: animated)
      focusDetail(animated: animated)
      return true
    }
  }

  func resetContentPathAndDetail() {
    contentPath = []
    resetDetail()
    focusContent()
  }

  func clearForwardHistoryForNewBranch() {
    clearForwardRoutes()
  }

  func focusContent(animated: Bool = true) {
    if animated {
      withAnimation {
        preferredColumn = contentColumn
        columnVisibility = .doubleColumn
      }
    } else {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        preferredColumn = contentColumn
        columnVisibility = .doubleColumn
      }
    }
  }

  func focusDetail(animated: Bool = true) {
    if animated {
      withAnimation {
        preferredColumn = .detail
      }
    } else {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        preferredColumn = .detail
      }
    }
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

  private func clearDetailForContentNavigation(to destination: Router.NavDest) {
    guard selectedPostID != nil || detailPost != nil || detailHighlightID != nil || !targetRouter.fullPath.isEmpty else { return }
    AppDiagnostics.asyncBreadcrumb(
      "RedditSplitNavigation.clearDetailForContentNavigation",
      metadata: diagnosticsMetadata(extra: ["destination": destination.diagnosticsName])
    )
    selectedPostID = nil
    detailPost = nil
    detailHighlightID = nil
    if !targetRouter.fullPath.isEmpty {
      resetRouterPathWithoutForwardRecording()
    }
  }

  private func currentDetailDestination() -> Router.NavDest? {
    if let selectedPostID, let detailPost, detailPost.id == selectedPostID {
      if let detailHighlightID {
        return .reddit(.postHighlighted(detailPost, detailHighlightID))
      }
      return .reddit(.post(detailPost))
    }

    guard let detailPost else { return nil }
    if let detailHighlightID {
      return .reddit(.postHighlighted(detailPost, detailHighlightID))
    }
    return .reddit(.post(detailPost))
  }

  private func appendForwardRoutes(_ routes: [RedditForwardRoute]) {
    guard !routes.isEmpty else { return }
    forwardRoutes.append(contentsOf: routes)
    AppDiagnostics.asyncBreadcrumb(
      "RedditSplitNavigation.forwardRoutes.append",
      metadata: diagnosticsMetadata(extra: ["routes": routes.map(\.diagnosticsName).joined(separator: ",")])
    )
  }

  private func clearForwardRoutes() {
    guard !forwardRoutes.isEmpty else { return }
    AppDiagnostics.asyncBreadcrumb(
      "RedditSplitNavigation.forwardRoutes.clear",
      metadata: diagnosticsMetadata(extra: ["forwardRouteCount": "\(forwardRoutes.count)"])
    )
    forwardRoutes = []
  }

  private func resetRouterPathWithoutForwardRecording() {
    guard !targetRouter.fullPath.isEmpty else { return }
    suppressNextRouterPopRecord = true
    targetRouter.resetNavPath()
  }

  func replaceRouterPathWithoutForwardRecording(_ newPath: [Router.NavDest]) {
    suppressNextRouterPopRecord = true
    targetRouter.replacePath(newPath)
  }

  private func diagnosticsMetadata(extra: [String: String] = [:]) -> [String: String] {
    [
      "selectedPostID": selectedPostID ?? "nil",
      "detailPostID": detailPost?.id ?? "nil",
      "detailHighlightID": detailHighlightID ?? "nil",
      "contentPathCount": "\(contentPath.count)",
      "routerPathCount": "\(targetRouter.fullPath.count)",
      "forwardRouteCount": "\(forwardRoutes.count)",
      "preferredColumn": preferredColumn.diagnosticsName,
      "columnVisibility": columnVisibility.diagnosticsName
    ].merging(extra) { _, new in new }
  }
}

private struct RedditNavigationModelKey: EnvironmentKey {
  static let defaultValue: (any RedditNavigator)? = nil
}

private struct RedditNavigationOriginKey: EnvironmentKey {
  static let defaultValue: RedditNavigationOrigin = .detail
}

extension EnvironmentValues {
  var redditNavigationModel: (any RedditNavigator)? {
    get { self[RedditNavigationModelKey.self] }
    set { self[RedditNavigationModelKey.self] = newValue }
  }

  var redditNavigationOrigin: RedditNavigationOrigin {
    get { self[RedditNavigationOriginKey.self] }
    set { self[RedditNavigationOriginKey.self] = newValue }
  }
}

extension View {
  func redditNavigation(_ model: any RedditNavigator, origin: RedditNavigationOrigin) -> some View {
    self
      .environment(\.redditNavigationModel, model)
      .environment(\.redditNavigationOrigin, origin)
  }
}

@MainActor
func navigateRedditDestination(
  _ destination: Router.NavDest,
  model: (any RedditNavigator)?,
  origin: RedditNavigationOrigin
) {
  AppDiagnostics.asyncBreadcrumb(
    "navigateRedditDestination",
    metadata: [
      "destination": destination.diagnosticsName,
      "origin": origin.diagnosticsName,
      "hasSplitModel": "\(model != nil)"
    ]
  )
  if let model {
    model.navigate(destination, from: origin)
  } else {
    Nav.to(destination)
  }
}
