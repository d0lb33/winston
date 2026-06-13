//
//  ShortPostLink.swift
//  winston
//
//  Created by Igor Marcossi on 29/07/23.
//

import SwiftUI
import Defaults

struct ShortPostLink: View {
  var noHPad = false
  var post: Post
  @Environment(\.useTheme) private var selectedTheme

  private func openPost(data: PostData) {
    if post.winstonData == nil || post.winstonData?.titleAttr == nil || post.winstonData?.subreddit == nil {
      post.setupWinstonData(data: data, theme: selectedTheme, sub: Subreddit(id: data.subreddit))
    }

    AppDiagnostics.asyncRecord(
      .debug,
      category: "ui.embeddedPost",
      message: "ShortPostLink tapped",
      metadata: diagnosticsMetadata(data: data)
    )
    Nav.to(.reddit(.post(post)))
  }

  var body: some View {
    Group {
      if let data = post.data {
        VStack(alignment: .leading) {
          Text("\(data.title.escape)")
            .fontSize(18, .semibold)
          Text((data.selftext).md()).lineLimit(2)
            .fontSize(15).opacity(0.75)
          HStack {
  //          if let fullname = data.author_fullname {
              Badge(showVotes: true, post: post, theme: selectedTheme.postLinks.theme.badge)
  //              .equatable()
  //          }
            Spacer()
            Tag(text: "r/\(data.subreddit)", color: selectedTheme.postLinks.theme.badge.subColor())
              .highPriorityGesture(TapGesture().onEnded {
                AppDiagnostics.asyncRecord(
                  .debug,
                  category: "ui.embeddedPost",
                  message: "ShortPostLink subreddit tapped",
                  metadata: diagnosticsMetadata(data: data)
                )
                Nav.to(.reddit(.subFeed(Subreddit(id: data.subreddit))))
              })
          }
        }
        .padding(.horizontal, noHPad ? 0 : 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedListRowLikeBG()
        .mask(RR(20, Color.black))
        .onAppear {
          AppDiagnostics.asyncRecord(
            .debug,
            category: "ui.embeddedPost",
            message: "ShortPostLink appeared",
            metadata: diagnosticsMetadata(data: data)
          )
        }
        .onTapGesture {
          openPost(data: data)
        }
      } else {
        ProgressView()
          .progressViewStyle(.circular)
          .frame(maxWidth: .infinity, minHeight: 72)
          .themedListRowLikeBG()
          .mask(RR(20, Color.black))
          .onAppear {
            AppDiagnostics.asyncRecord(
              .warning,
              category: "ui.embeddedPost",
              message: "ShortPostLink missing post data",
              metadata: [
                "postID": post.id,
                "hasWinstonData": "\(post.winstonData != nil)"
              ]
            )
          }
      }
    }
  }

  func diagnosticsMetadata(data: PostData) -> [String: String] {
    [
      "postID": post.id,
      "fullname": data.name,
      "title": data.title,
      "subreddit": data.subreddit,
      "hasWinstonData": "\(post.winstonData != nil)"
    ]
  }
}
