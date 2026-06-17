//
//  RedditTwoColumnShell.swift
//  winston
//
//  Reusable native split shell for Reddit roots whose leading column is a source view
//  (Search, Me/profile, and similar non-sidebar surfaces).
//

import SwiftUI

struct RedditTwoColumnShell<Source: View>: View {
  let nav: ColumnNav
  @Environment(\.auroraTheme) private var auroraTheme

  @ViewBuilder var source: (ColumnNav) -> Source

  init(
    nav: ColumnNav,
    @ViewBuilder source: @escaping (ColumnNav) -> Source
  ) {
    self.nav = nav
    self.source = source
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
        ColumnDetailContent(nav: nav)
          .redditNavigation(nav, origin: .detail)
          .redditDestinations(nav, origin: .detail)
      }
    }
    .navigationSplitViewStyle(.balanced)
    .environment(\.auroraTheme, auroraTheme)
    .tint(auroraTheme.accent)
    .fontDesign(auroraTheme.fontDesign)
    .preferredColorScheme(auroraTheme.colorScheme)
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
