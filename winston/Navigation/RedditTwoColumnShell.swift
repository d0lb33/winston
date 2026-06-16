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

  private var isSourceRootVisibleForTabInteraction: Bool {
    tab != nil && nav.contentPath.isEmpty && (hSize == .regular || nav.preferredColumn == .sidebar)
  }

  private var isDetailVisibleForTabInteraction: Bool {
    tab != nil && nav.detailPost != nil && hSize != .regular && nav.preferredColumn == .detail
  }

  var body: some View {
    @Bindable var nav = nav

    NavigationSplitView(preferredCompactColumn: $nav.preferredColumn) {
      NavigationStack(path: $nav.contentPath) {
        source(nav)
          .redditNavigation(nav, origin: .content)
          .redditDestinations(nav, origin: .content)
      }
      .navigationSplitViewColumnWidth(min: 360, ideal: 440)
    } detail: {
      NavigationStack(path: $nav.detailPath) {
        ColumnDetailContent(
          nav: nav,
          tabInteractionTab: isDetailVisibleForTabInteraction ? tab : nil,
          tabInteractions: isDetailVisibleForTabInteraction ? tabInteractions : nil,
          tabInteractionRequest: isDetailVisibleForTabInteraction ? tab.flatMap { tabInteractions.requests[$0] } : nil
        )
          .redditNavigation(nav, origin: .detail)
          .redditDestinations(nav, origin: .detail)
      }
      .environment(\.tabInteractionTab, isDetailVisibleForTabInteraction ? tab : nil)
      .environment(\.tabInteractionCenter, isDetailVisibleForTabInteraction ? tabInteractions : nil)
      .environment(\.tabInteractionRequest, isDetailVisibleForTabInteraction ? tab.flatMap { tabInteractions.requests[$0] } : nil)
    }
    .navigationSplitViewStyle(.balanced)
    .environment(\.auroraTheme, auroraTheme)
    .tint(auroraTheme.accent)
    .fontDesign(auroraTheme.fontDesign)
    .preferredColorScheme(auroraTheme.colorScheme)
    .onAppear {
      if let tab {
        tabInteractions.setIsAtTop(tab, true)
      }
    }
    .routerDeepLinkInbox(
      router: router,
      consume: { nav.consumeDeepLink(path: $0) },
      onRootReset: { nav.reset() }
    )
    .onChange(of: tab.flatMap { tabInteractions.requests[$0] }) { _, request in
      handleTabInteractionRequest(request)
    }
  }

  private func handleTabInteractionRequest(_ request: TabInteractionRequest?) {
    guard let request else { return }
    switch request.kind {
    case .scrollToTop:
      guard isSourceRootVisibleForTabInteraction || isDetailVisibleForTabInteraction else {
        AppDiagnostics.asyncBreadcrumb(
          "Split tab scroll request routed to back",
          metadata: [
            "tab": tab?.rawValue ?? "none",
            "preferredColumn": "\(nav.preferredColumn)",
            "contentPathCount": "\(nav.contentPath.count)",
            "detailPathCount": "\(nav.detailPath.count)",
            "hasDetailPost": "\(nav.detailPost != nil)"
          ]
        )
        _ = nav.goBackOneStep()
        return
      }
    case .goBack:
      _ = nav.goBackOneStep()
    case .resetToRoot:
      nav.reset()
    }
  }

}

struct ColumnDetailContent: View {
  let nav: ColumnNav
  var tabInteractionTab: Nav.TabIdentifier?
  var tabInteractions: TabInteractionCenter?
  var tabInteractionRequest: TabInteractionRequest?

  var body: some View {
    if let post = nav.detailPost {
      AuroraPostDetail(
        post: post,
        subreddit: detailSubreddit(for: post),
        highlightID: nav.detailHighlightID,
        tabInteractionTab: tabInteractionTab,
        tabInteractions: tabInteractions,
        tabInteractionRequest: tabInteractionRequest
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
