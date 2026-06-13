//
//  RedditMediaPost.swift
//  winston
//
//  Created by Igor Marcossi on 31/07/23.
//

import SwiftUI
import Combine

struct RedditMediaPost: View {
  var entity: RedditEntityType
  static let height: CGFloat = 88

  @State private var loadAttempt = 0
  @State private var loadFailed = false

  /// Whether the entity has everything it needs to render.
  private var hasData: Bool {
    switch entity {
    case .comment(let comment): return comment.data != nil && comment.winstonData != nil
    case .post(let post): return post.data != nil
    case .user(let user): return user.data != nil
    case .subreddit(let subreddit): return subreddit.data != nil
    }
  }

  var body: some View {
    HStack(spacing: 16) {
      if hasData {
        switch entity {
        case .comment(let comment):
          if let commentWinstonData = comment.winstonData {
            CommentLink(showReplies: false, comment: comment, commentWinstonData: commentWinstonData, children: comment.childrenWinston)
              .padding(.vertical, 8)
          }
        case .post(let post):
          ShortPostLink(noHPad: true, post: post)
        case .user(let user):
          UserLinkContainer(noHPad: true, user: user)
        case .subreddit(let subreddit):
          SubredditLinkContainer(sub: subreddit)
        }
      } else if loadFailed {
        Button {
          loadFailed = false
          loadAttempt += 1
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise")
            Text("Couldn't load — tap to retry")
          }
          .fontSize(15, .medium)
          .opacity(0.65)
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
      } else {
        ProgressView()
          .progressViewStyle(.circular)
          .frame(maxWidth: .infinity)
      }
    }
    .frame(maxWidth: .infinity, minHeight: RedditMediaPost.height, maxHeight: RedditMediaPost.height)
    .padding(.horizontal, 8)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.1)))
    .task(id: loadAttempt) {
      await loadEntityIfNeeded()
    }
    .onAppear {
      AppDiagnostics.asyncRecord(
        .debug,
        category: "ui.embeddedPost",
        message: "RedditMediaPost appeared",
        metadata: entityDiagnosticsMetadata()
      )
    }
  }

  /// Embedded entities arrive from mediaExtractor as bare ids; this view owns
  /// hydrating them so the extractor stays a pure, synchronous function.
  @MainActor
  private func loadEntityIfNeeded() async {
    guard !hasData else { return }
    switch entity {
    case .post(let post):
      if let data = await RedditWire.shared.postData(forID: post.id) {
        withAnimation { post.data = data }
      }
    case .comment(let comment):
      if let data = await RedditWire.shared.commentData(forID: comment.id) {
        withAnimation {
          comment.data = data
          comment.setupWinstonData()
        }
      }
    case .user(let user):
      if let data = await RedditWire.shared.userProfile(user.id) {
        withAnimation { user.data = data }
      }
    case .subreddit(let subreddit):
      await subreddit.refreshSubreddit()
    }
    if !hasData {
      loadFailed = true
      AppDiagnostics.asyncRecord(
        .warning,
        category: "ui.embeddedPost",
        message: "Embedded entity failed to load",
        metadata: entityDiagnosticsMetadata()
      )
    }
  }

  func entityDiagnosticsMetadata() -> [String: String] {
    switch entity {
    case .comment(let comment):
      return [
        "kind": "comment",
        "id": comment.id,
        "hasData": "\(comment.data != nil)",
        "hasWinstonData": "\(comment.winstonData != nil)",
        "title": comment.data?.link_title ?? "nil"
      ]
    case .post(let post):
      return [
        "kind": "post",
        "id": post.id,
        "hasData": "\(post.data != nil)",
        "hasWinstonData": "\(post.winstonData != nil)",
        "title": post.data?.title ?? "nil",
        "subreddit": post.data?.subreddit ?? "nil"
      ]
    case .user(let user):
      return [
        "kind": "user",
        "id": user.id,
        "hasData": "\(user.data != nil)"
      ]
    case .subreddit(let subreddit):
      return [
        "kind": "subreddit",
        "id": subreddit.id,
        "hasData": "\(subreddit.data != nil)"
      ]
    }
  }
}
