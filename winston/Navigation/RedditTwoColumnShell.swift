//
//  RedditTwoColumnShell.swift
//  winston
//
//  Reusable split shell for Reddit roots whose source view is the leading column
//  (Search, Me/profile, and similar non-sidebar surfaces).
//

import SwiftUI

struct RedditTwoColumnShell<Source: View>: View {
  @ObservedObject var router: Router
  @State private var navigation = RedditSplitNavigationModel(contentColumn: .sidebar)
  @Environment(\.auroraTheme) private var auroraTheme

  @ViewBuilder var source: (RedditSplitNavigationModel) -> Source

  var body: some View {
    @Bindable var navigation = navigation

    NavigationSplitView(columnVisibility: $navigation.columnVisibility, preferredCompactColumn: $navigation.preferredColumn) {
      NavigationStack(path: $navigation.contentPath) {
        source(navigation)
          .injectInTabDestinations(viewControllerHolder: router.navController)
          .redditNavigation(navigation, origin: .content)
      }
      .navigationSplitViewColumnWidth(min: 360, ideal: 440)
    } detail: {
      NavigationStack(path: $router.fullPath) {
        RedditDetailColumnContent(navigation: navigation)
          .injectInTabDestinations(viewControllerHolder: router.navController)
          .redditNavigation(navigation, origin: .detail)
      }
    }
    .navigationSplitViewStyle(.balanced)
    .redditForwardNavigationGesture(navigation: navigation) {
      source(navigation)
        .redditNavigation(navigation, origin: .content)
    }
    .environment(\.auroraTheme, auroraTheme)
    .tint(auroraTheme.accent)
    .fontDesign(auroraTheme.fontDesign)
    .preferredColorScheme(auroraTheme.colorScheme)
    .onAppear {
      navigation.attach(router: router)
      _ = navigation.absorbRootNavigationPathIfNeeded(router: router)
    }
    .onChange(of: router.fullPath) { oldPath, path in
      navigation.recordRouterPathChange(from: oldPath, to: path)
      if navigation.absorbRootNavigationPathIfNeeded(router: router) {
        return
      }
      if path.isEmpty {
        if navigation.detailPost == nil {
          navigation.focusContent()
        }
      } else {
        navigation.focusDetail()
      }
    }
    .onChange(of: navigation.preferredColumn) { oldColumn, newColumn in
      navigation.recordPreferredColumnChange(from: oldColumn, to: newColumn)
    }
  }
}

struct RedditDetailColumnContent: View {
  let navigation: RedditSplitNavigationModel

  var body: some View {
    if let post = navigation.detailPost {
      AuroraPostDetail(
        post: post,
        subreddit: detailSubreddit(for: post),
        highlightID: navigation.detailHighlightID
      )
      .id("\(post.id)-\(navigation.detailHighlightID ?? "root")")
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
