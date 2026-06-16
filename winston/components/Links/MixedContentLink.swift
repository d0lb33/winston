//
//  MixedContentLink.swift
//  winston
//
//  Created by Igor Marcossi on 21/11/23.
//

import SwiftUI

struct MixedContentLink: View, Equatable {
  static func == (lhs: MixedContentLink, rhs: MixedContentLink) -> Bool {
    lhs.content == rhs.content && lhs.theme == rhs.theme
  }
  
  var content: Either<Post, Comment>
  var theme: SubPostsListTheme
  
  @Environment(\.contentWidth) private var contentWidth
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin
  
  var body: some View {
    switch content {
    case .first(let post):
      if post.winstonData != nil {
        AuroraPostCardRow(post: post, availableRowWidth: contentWidth, onSelect: {
          navigateRedditDestination(.reddit(.post(post)), model: redditNavigationModel, origin: redditNavigationOrigin)
        })
      }
    case .second(let comment):
      VStack(spacing: 10) {
        commentContext(comment)
          .allowsHitTesting(false)
          .padding(.horizontal, 12)
          .padding(.top, 12)
        if comment.winstonData != nil {
          NativeCommentPreview(comment: comment, availableWidth: contentWidth)
            .allowsHitTesting(false)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture {
        openCommentPost(comment)
      }
    }
  }

  @ViewBuilder
  private func commentContext(_ comment: Comment) -> some View {
    if let data = comment.data {
      HStack(spacing: 10) {
        Image(systemName: "bubble.left.and.text.bubble.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(commentTitle(data))
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
          if let subreddit = data.subreddit {
            Text("r/\(subreddit)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
  }

  private func openCommentPost(_ comment: Comment) {
    guard let data = comment.data, let linkID = data.link_id, let subID = data.subreddit else { return }
    navigateRedditDestination(.reddit(.postHighlighted(Post(id: linkID, subID: subID), comment.id)), model: redditNavigationModel, origin: redditNavigationOrigin)
  }

  private func commentTitle(_ data: CommentData) -> String {
    if let title = data.link_title, !title.isEmpty { return title }
    return "Comment"
  }
}
