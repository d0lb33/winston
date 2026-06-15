//
//  AuroraSubFeedScreen.swift
//  winston
//
//  A pushable, single-column Aurora feed — the destination for `.subFeed` deep links
//  (tapping a community name, a sub link in a post/comment, etc.). The 3-pane
//  AuroraRoot drives its feed through the sidebar; this is the stack-pushed form for
//  navigating into one community from anywhere. Selecting a post pushes the post
//  detail via Nav, so it composes with the existing navigation graph.
//

import SwiftUI
import Defaults

struct AuroraSubFeedScreen: View {
  let subreddit: Subreddit
  @Default(.auroraThemeID) private var auroraThemeID
  @State private var model: AuroraFeedModel
  @State private var sort: SubListingSortOption = .hot
  @State private var selectedPostID: String?
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin

  init(subreddit: Subreddit) {
    self.subreddit = subreddit
    _model = State(initialValue: AuroraFeedModel(subreddit: subreddit))
  }

  private var theme: AuroraTheme { auroraThemeID.theme }
  private var isCommunity: Bool { !feedsAndSuch.contains(subreddit.id) }

  var body: some View {
    Group {
      if subreddit.id == "saved" {
        AuroraSavedScreen(
          onPostSelected: { post in
            navigateRedditDestination(.reddit(.post(post)), model: redditNavigationModel, origin: redditNavigationOrigin)
          },
          onCommentSelected: { comment in
            guard let data = comment.data, let linkID = data.link_id, let subID = data.subreddit else { return }
            navigateRedditDestination(.reddit(.postHighlighted(Post(id: linkID, subID: subID), comment.id)), model: redditNavigationModel, origin: redditNavigationOrigin)
          }
        )
      } else {
        AuroraFeed(
          model: model,
          title: subreddit.displayTitle,
          community: isCommunity ? subreddit : nil,
          selectedPostID: $selectedPostID,
          sort: $sort
        )
      }
    }
    .environment(\.auroraTheme, theme)
    .tint(theme.accent)
    .background { AuroraBackdrop(theme: theme) }
    .toolbarBackground(.hidden, for: .navigationBar)
    .onChange(of: selectedPostID) { _, id in
      // Stack-push the post rather than driving a detail pane.
      if let id, let post = model.post(id: id) {
        selectedPostID = nil
        navigateRedditDestination(.reddit(.post(post)), model: redditNavigationModel, origin: redditNavigationOrigin)
      }
    }
  }
}
