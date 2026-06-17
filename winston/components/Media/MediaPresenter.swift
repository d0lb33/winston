//
//  MediaPresenter.swift
//  winston
//
//  Created by Igor Marcossi on 22/08/23.
//

import SwiftUI
import YouTubePlayerKit
import Defaults
import NukeUI

struct OnlyURL: View {
  static let height: Double = 22
  @Default(.BehaviorDefSettings) private var behaviorDefSettings
  var url: URL
  @Environment(\.openURL) private var openURL
  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "link")
      Text(cleanURL(url: url, showPath: false))
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .frame(maxHeight: OnlyURL.height)
    .background(Capsule(style: .continuous).fill(Color.accentColor.opacity(0.3)))
    .fontSize(15, .medium)
    .lineLimit(1)
    .foregroundColor(.white)
    .highPriorityGesture(TapGesture().onEnded {
      if let newURL = URL(string: url.absoluteString.replacingOccurrences(of: "https://reddit.com/", with: "winstonapp://")) {
        openURL(newURL)
      }
    })
  }
}

struct MediaPresenter: View, Equatable {
  static func == (lhs: MediaPresenter, rhs: MediaPresenter) -> Bool {
    lhs.compact == rhs.compact && lhs.contentWidth == rhs.contentWidth && lhs.badgeKit == rhs.badgeKit && lhs.cornerRadius == rhs.cornerRadius && lhs.blurPostLinkNSFW == rhs.blurPostLinkNSFW && lhs.over18 == rhs.over18 && lhs.media == rhs.media && lhs.diagnosticContext == rhs.diagnosticContext && lhs.feedItemKey == rhs.feedItemKey
  }
  
  @Binding var postDimensions: PostDimensions
  weak var controller: UIViewController?
  let postTitle: String
  let badgeKit: BadgeKit
  let avatarImageRequest: ImageRequest?
  let markAsSeen: (() async -> ())?
  var cornerRadius: Double
  var blurPostLinkNSFW: Bool
  var showURLInstead = false
  let media: MediaExtractedType
  var over18 = false
  let compact: Bool
  let contentWidth: CGFloat
  let maxMediaHeightScreenPercentage: CGFloat
  let resetVideo: ((SharedVideo) -> ())?
  var diagnosticContext: String? = nil
  /// Stable feed-item key (post id) used to gate inline video autoplay so only the
  /// centered video plays. nil when not presented in a gated feed (preserves old behavior).
  var feedItemKey: String? = nil

  var body: some View {
    let _ = ScrollPerfProbe.shared.bump("mediaPresenterBody")
    switch media {
    case .imgs(let imgsExtracted):
      let _ = ScrollPerfProbe.shared.bump("mediaPresenter.imgs")
      if !showURLInstead {
        if imgsExtracted.count > 0 && imgsExtracted[0].url.absoluteString.hasSuffix(".gif") {
          ImageMediaPost(postDimensions: $postDimensions, controller: controller, postTitle: postTitle, badgeKit: badgeKit, avatarImageRequest: avatarImageRequest, markAsSeen: markAsSeen, cornerRadius: cornerRadius, compact: compact, images: imgsExtracted, contentWidth: contentWidth, maxMediaHeightScreenPercentage: maxMediaHeightScreenPercentage, diagnosticContext: diagnosticContext)
            .nsfw(over18 && blurPostLinkNSFW, smallIcon: compact, size: postDimensions.mediaSize)
        } else {
          ImageMediaPost(postDimensions: $postDimensions, controller: controller, postTitle: postTitle, badgeKit: badgeKit, avatarImageRequest: avatarImageRequest, markAsSeen: markAsSeen, cornerRadius: cornerRadius, compact: compact, images: imgsExtracted, contentWidth: contentWidth, maxMediaHeightScreenPercentage: maxMediaHeightScreenPercentage, diagnosticContext: diagnosticContext)
            .nsfw(over18 && blurPostLinkNSFW, smallIcon: compact, size: postDimensions.mediaSize)
          
        }
      }
    case .video(let sharedVideo):
      let _ = ScrollPerfProbe.shared.bump("mediaPresenter.video")
      if !showURLInstead {
        VideoPlayerPost(controller: controller, cachedVideo: sharedVideo, markAsSeen: markAsSeen, compact: compact, contentWidth: contentWidth, url: sharedVideo.url, resetVideo: resetVideo, maxMediaHeightScreenPercentage: maxMediaHeightScreenPercentage, diagnosticContext: diagnosticContext, feedItemKey: feedItemKey, inlineBlurNSFW: over18 && blurPostLinkNSFW, inlineCornerRadius: cornerRadius)
          .nsfw(over18 && blurPostLinkNSFW, smallIcon: compact, size: postDimensions.mediaSize)
      }
      
    case .streamable(_):
      let _ = ScrollPerfProbe.shared.bump("mediaPresenter.streamable")
      if !showURLInstead {
        ProgressView()
        .progressViewStyle(.circular)
        .frame(maxWidth: .infinity, minHeight: 100)
        .id("streamable-loading")
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
      }
    case .yt(let ytMediaExtracted):
      let _ = ScrollPerfProbe.shared.bump("mediaPresenter.yt")
      if !showURLInstead {
        YTMediaPostPlayer(compact: compact, player: ytMediaExtracted.player, ytMediaExtracted: ytMediaExtracted, contentWidth: contentWidth, diagnosticContext: diagnosticContext)
      }
    case .link(let previewModel):
      let _ = ScrollPerfProbe.shared.bump("mediaPresenter.link")
      if let previewURL = previewModel.previewURL {
        if !showURLInstead {
          PreviewLinkContent(compact: compact, viewModel: previewModel, url: previewURL)
        } else {
          OnlyURL(url: previewURL)
        }
      }
    case .post(let postExtractedEntity):
      let _ = ScrollPerfProbe.shared.bump("mediaPresenter.post")
      if let postExtractedEntity = postExtractedEntity {
        if !showURLInstead {
          if compact, let sub = postExtractedEntity.subredditID, let postID = postExtractedEntity.postID {
            if let url = URL(string: "https://reddit.com/r/\(sub)/comments/\(postID)") {
              PreviewLink(url: url, compact: compact, previewModel: PreviewModel.get(url, compact: compact))
            }
          } else {
            RedditMediaPost(entity: .post(postExtractedEntity.entity))
          }
        } else if let sub = postExtractedEntity.subredditID, let postID = postExtractedEntity.postID, let url = URL(string: "https://reddit.com/r/\(sub)/comments/\(postID)") {
          OnlyURL(url: url)
        }
      }
    case .comment(let commentExtractedEntity):
      let _ = ScrollPerfProbe.shared.bump("mediaPresenter.comment")
      if let commentExtractedEntity = commentExtractedEntity {
        if !showURLInstead {
          if compact, let sub = commentExtractedEntity.subredditID, let postID = commentExtractedEntity.postID, let commentID = commentExtractedEntity.commentID {
            if let url = URL(string: "https://reddit.com/r/\(sub)/comments/\(postID)/comment/\(commentID)") {
              PreviewLink(url: url, compact: compact, previewModel: PreviewModel.get(url, compact: compact))
            }
          } else {
            RedditMediaPost(entity: .comment(commentExtractedEntity.entity))
          }
        } else if let sub = commentExtractedEntity.subredditID, let postID = commentExtractedEntity.postID, let commentID = commentExtractedEntity.commentID, let url = URL(string: "https://reddit.com/r/\(sub)/comments/\(postID)/comment/\(commentID)") {
          OnlyURL(url: url)
        }
      }
    case .subreddit(let subExtractedEntity):
      let _ = ScrollPerfProbe.shared.bump("mediaPresenter.subreddit")
      if let subExtractedEntity = subExtractedEntity {
        if !showURLInstead {
          if compact {
            if let url = URL(string: "https://reddit.com/r/\(subExtractedEntity.subredditID ?? "")") {
              PreviewLink(url: url, compact: compact, previewModel: PreviewModel.get(url, compact: compact))
            }
          } else {
            RedditMediaPost(entity: .subreddit(subExtractedEntity.entity))
          }
        } else if let url = URL(string: "https://reddit.com/r/\(subExtractedEntity.subredditID ?? "")") {
          OnlyURL(url: url)
        }
      }
    case .user(let userExtractedEntity):
      let _ = ScrollPerfProbe.shared.bump("mediaPresenter.user")
      if let userExtractedEntity = userExtractedEntity {
        if !showURLInstead {
          if compact {
            if let url = URL(string: "https://reddit.com/u/\(userExtractedEntity.userID ?? "")") {
              PreviewLink(url: url, compact: compact, previewModel: PreviewModel.get(url, compact: compact))
            }
          } else {
            RedditMediaPost(entity: .user(userExtractedEntity.entity))
          }
        } else if let url = URL(string: "https://reddit.com/u/\(userExtractedEntity.userID ?? "")") {
          OnlyURL(url: url)
        }
      }
    default:
      EmptyView()
    }
  }
}
