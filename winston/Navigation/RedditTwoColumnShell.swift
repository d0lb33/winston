//
//  RedditTwoColumnShell.swift
//  winston
//
//  Reusable native split shell for Reddit roots whose leading column is a source view
//  (Search, Me/profile, and similar non-sidebar surfaces). Rebuilt on `ColumnNav`: the
//  detail stack is owned in the model (`detailPath`), so `NavigationSplitView` owns all
//  compact↔regular collapse/expand and there is nothing to reconcile across size-class
//  transitions. The legacy `Router` still delivers deep links (`Nav.to` / contextual);
//  this shell observes it as a write-only inbox and translates into `nav`.
//
//  The same forward-history recorder used by Posts is attached here so compact-width
//  users can swipe from the trailing edge to replay the most recent back navigation.
//

import SwiftUI

struct RedditTwoColumnShell<Source: View>: View {
  @ObservedObject var router: Router
  let tab: Nav.TabIdentifier?
  @State private var nav = ColumnNav()
  @Environment(\.auroraTheme) private var auroraTheme
  @Environment(\.horizontalSizeClass) private var hSize
  @EnvironmentObject private var tabInteractions: TabInteractionCenter

  @ViewBuilder var source: (ColumnNav) -> Source

  init(
    router: Router,
    tab: Nav.TabIdentifier? = nil,
    @ViewBuilder source: @escaping (ColumnNav) -> Source
  ) {
    self.router = router
    self.tab = tab
    self.source = source
  }

  var body: some View {
    @Bindable var nav = nav

    NavigationSplitView(preferredCompactColumn: $nav.preferredColumn) {
      NavigationStack(path: $nav.contentPath) {
        source(nav)
          .redditNavigation(nav, origin: .content)
          .navigationDestination(for: Router.NavDest.self) { destination in
            RouterDestinationView(destination: destination)
          }
          .toolbar { forwardToolbarItem }
      }
      .navigationSplitViewColumnWidth(min: 360, ideal: 440)
    } detail: {
      NavigationStack(path: $nav.detailPath) {
        ColumnDetailContent(nav: nav)
          .redditNavigation(nav, origin: .detail)
          .navigationDestination(for: Router.NavDest.self) { destination in
            RouterDestinationView(destination: destination)
          }
          .toolbar { forwardToolbarItem }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .forwardEdgeSwipe(
      isActive: hSize != .regular,
      navigation: nav
    )
    .environment(\.auroraTheme, auroraTheme)
    .tint(auroraTheme.accent)
    .fontDesign(auroraTheme.fontDesign)
    .preferredColorScheme(auroraTheme.colorScheme)
    .onAppear {
      if let tab {
        tabInteractions.setIsAtTop(tab, true)
      }
      consumeContextualDestinationIfNeeded()
      consumeRouterPathIfNeeded(router.fullPath)
    }
    .onChange(of: tab.flatMap { tabInteractions.requests[$0] }) { _, request in
      handleTabInteractionRequest(request)
    }
    .onChange(of: router.contextualDestination) { _, _ in
      consumeContextualDestinationIfNeeded()
    }
    .onChange(of: router.fullPath) { _, path in
      consumeRouterPathIfNeeded(path)
    }
    .onChange(of: router.rootResetToken) { _, _ in
      nav.reset()
    }
    .onChange(of: nav.forwardSnapshot) { old, new in
      nav.recordForwardTransition(from: old, to: new)
    }
  }

  private func handleTabInteractionRequest(_ request: TabInteractionRequest?) {
    guard let request else { return }
    switch request.kind {
    case .scrollToTop:
      break
    case .goBack:
      _ = nav.goBackOneStep()
    case .resetToRoot:
      nav.reset()
    }
  }

  @ToolbarContentBuilder private var forwardToolbarItem: some ToolbarContent {
    if nav.canGoForward {
      ToolbarItem(placement: .topBarTrailing) {
        Button { nav.goForward() } label: {
          Image(systemName: "chevron.forward")
        }
        .accessibilityLabel("Go forward")
      }
    }
  }

  /// Deep links / shortcuts arrive on the legacy Router as a contextual destination.
  private func consumeContextualDestinationIfNeeded() {
    guard let destination = router.contextualDestination else { return }
    router.contextualDestination = nil
    openExternalDestination(destination)
  }

  /// `Nav.to(...)` appends to the active tab's `Router.fullPath`. Translate anything that
  /// lands there into `nav` and clear the Router (it no longer drives this surface).
  private func consumeRouterPathIfNeeded(_ path: [Router.NavDest]) {
    guard !path.isEmpty else { return }
    for destination in path { openExternalDestination(destination) }
    router.resetNavPath()
  }

  private func openExternalDestination(_ destination: Router.NavDest) {
    if let detail = PostsNav.postDetail(from: destination) {
      nav.openPostInDetail(detail.post, highlightID: detail.highlightID)
    } else {
      nav.navigate(destination, from: .content)
    }
  }
}

struct ColumnDetailContent: View {
  let nav: ColumnNav

  var body: some View {
    if let post = nav.detailPost {
      AuroraPostDetail(
        post: post,
        subreddit: detailSubreddit(for: post),
        highlightID: nav.detailHighlightID
      )
      .id("\(post.id)-\(nav.detailHighlightID ?? "root")")
      .diagnosticScreen("reddit.detail.\(post.id)")
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
