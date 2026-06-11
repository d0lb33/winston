//
//  MixedContentLink.swift
//  winston
//
//  Created by Igor Marcossi on 21/11/23.
//

import SwiftUI
import Defaults

struct MixedContentLink: View, Equatable {
  static func == (lhs: MixedContentLink, rhs: MixedContentLink) -> Bool {
    lhs.content == rhs.content && lhs.theme == rhs.theme
  }
  
  var content: Either<Post, Comment>
  var theme: SubPostsListTheme
  
  @Default(.PostLinkDefSettings) private var postLinkDefSettings
  @Default(.CommentLinkDefSettings) private var commentLinkDefSettings
  @Environment(\.contentWidth) private var contentWidth
  
  var body: some View {
    switch content {
    case .first(let post):
      if let winstonData = post.winstonData, let postSub = winstonData.subreddit {
        PostLink(id: post.id, theme: theme, showSub: true, compactPerSubreddit: nil, contentWidth: contentWidth, defSettings: postLinkDefSettings)
        .environmentObject(post)
        .environmentObject(postSub)
        .environmentObject(winstonData)
      }
    case .second(let comment):
      VStack {
        ShortCommentPostLink(comment: comment)
          .allowsHitTesting(false)
          .padding()
        if let commentWinstonData = comment.winstonData {
          CommentLink(showReplies: false, comment: comment, commentWinstonData: commentWinstonData, children: comment.childrenWinston)
            .allowsHitTesting(false)
        }
      }
      .background(PostLinkBG(theme: theme, stickied: false, secondary: false).equatable())
      .mask(RR(theme.theme.cornerRadius, Color.black).equatable())
      .contentShape(Rectangle())
      .onTapGesture {
        openCommentPost(comment)
      }
    }
  }

  private func openCommentPost(_ comment: Comment) {
    guard let data = comment.data, let linkID = data.link_id, let subID = data.subreddit else { return }
    Nav.to(.reddit(.postHighlighted(Post(id: linkID, subID: subID), comment.id)))
  }
}
