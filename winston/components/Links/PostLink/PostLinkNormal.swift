//
//  PostLinkNormal.swift
//  winston
//
//  Created by Igor Marcossi on 25/09/23.
//

import SwiftUI
import Defaults
import NukeUI

struct PostLinkNormalSelftext: View, Equatable {
  static func == (lhs: PostLinkNormalSelftext, rhs: PostLinkNormalSelftext) -> Bool {
    return lhs.selftext == rhs.selftext && lhs.theme == rhs.theme
  }
  var selftext: String
  var theme: ThemeText
  var body: some View {
    Text(selftext).lineLimit(3)
      .fontSize(theme.size, theme.weight.t)
      .foregroundColor(theme.color())
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    //      .id("body")
  }
}

struct PostLinkClean: View, Equatable, Identifiable {
  static func == (lhs: PostLinkClean, rhs: PostLinkClean) -> Bool {
    lhs.id == rhs.id && lhs.theme == rhs.theme && lhs.contentWidth == rhs.contentWidth && lhs.secondary == rhs.secondary && lhs.defSettings == rhs.defSettings
  }

  @EnvironmentObject var post: Post
  @EnvironmentObject var winstonData: PostWinstonData
  @EnvironmentObject var sub: Subreddit
  var id: String
  weak var controller: UIViewController?
  var theme: SubPostsListTheme
  var showSub = false
  var secondary = false
  let contentWidth: CGFloat
  let defSettings: PostLinkDefSettings
  /// Set on an embedded crosspost so its inline video gates on the OUTER post id (the key
  /// the feed tracks), letting it autoplay with the feed. nil for normal feed rows.
  var inlineVideoKeyOverride: String? = nil

  /// The feed-gating key for this row's inline video — the outer post id when embedded.
  var inlineVideoFeedKey: String { inlineVideoKeyOverride ?? id }

  func markAsRead() async {
    Task(priority: .background) { await post.toggleSeen(true) }
  }

  func openPost() {
    Nav.to(.reddit(.post(post)))
  }

  func openSubreddit() {
    if let subName = post.data?.subreddit {
      withAnimation {
        Nav.to(.reddit(.subFeed(Subreddit(id: subName))))
      }
    }
  }

  func resetVideo(video: SharedVideo) {
    DispatchQueue.main.async {
      let newVideo: MediaExtractedType = .video(SharedVideo.get(url: video.url, size: video.size, downloadURL: video.downloadURL, posterURL: video.posterURL, resetCache: true))
      post.winstonData?.extractedMedia = newVideo
      post.winstonData?.extractedMediaForcedNormal = newVideo
    }
  }

  var over18: Bool { post.data?.over_18 ?? false }

  @ViewBuilder
  func mediaComponentCall() -> some View {
    if let data = post.data {
      if let extractedMedia = winstonData.extractedMedia {
        MediaPresenter(postDimensions: $winstonData.postDimensions, controller: controller, postTitle: data.title, badgeKit: data.badgeKit, avatarImageRequest: winstonData.avatarImageRequest, markAsSeen: !defSettings.lightboxReadsPost ? nil : markAsRead, cornerRadius: theme.theme.mediaCornerRadius, blurPostLinkNSFW: defSettings.blurNSFW, media: extractedMedia, over18: over18, compact: false, contentWidth: winstonData.postDimensions.mediaSize?.width ?? 0, maxMediaHeightScreenPercentage: defSettings.maxMediaHeightScreenPercentage, resetVideo: resetVideo, diagnosticContext: "post-clean:\(id):\(String(data.title.prefix(80)))", feedItemKey: inlineVideoFeedKey)
          .allowsHitTesting(defSettings.isMediaTappable || extractedMedia.alwaysAllowsInlineNavigation)

        if case .repost(let repost) = extractedMedia {
          if let repostWinstonData = repost.winstonData, let repostSub = repostWinstonData.subreddit {
            PostLink(
              id: repost.id,
              controller: controller,
              theme: theme,
              showSub: true,
              secondary: true,
              compactPerSubreddit: false,
              postStyleOverride: .clean,
              contentWidth: contentWidth,
              defSettings: defSettings,
              // Embedded video gates on the OUTER post id so it autoplays with the feed.
              inlineVideoKeyOverride: inlineVideoFeedKey
            )
            .background(Color.primary.opacity(0.05))
            .cornerRadius(theme.theme.mediaCornerRadius)
            .environmentObject(repost)
            .environmentObject(repostWinstonData)
            .environmentObject(repostSub)
            .onAppear {
              AppDiagnostics.asyncRecord(
                .debug,
                category: "ui.embeddedPost",
                message: "Rendering clean crosspost PostLink",
                metadata: embeddedPostMetadata(parentData: data, repost: repost, reason: "render")
              )
            }
          } else {
            Color.clear
              .frame(width: 0, height: 0)
              .onAppear {
                AppDiagnostics.asyncRecord(
                  .warning,
                  category: "ui.embeddedPost",
                  message: "Clean crosspost PostLink missing render dependencies",
                  metadata: embeddedPostMetadata(parentData: data, repost: repost, reason: "missing-dependencies")
                )
              }
          }
        }
      }
    }
  }

  func embeddedPostMetadata(parentData: PostData, repost: Post, reason: String) -> [String: String] {
    [
      "reason": reason,
      "parentPost": parentData.name,
      "parentID": id,
      "parentTitle": parentData.title,
      "repostID": repost.id,
      "repostFullname": repost.data?.name ?? "nil",
      "repostTitle": repost.data?.title ?? "nil",
      "repostSubreddit": repost.data?.subreddit ?? "nil",
      "hasWinstonData": "\(repost.winstonData != nil)",
      "hasSubreddit": "\(repost.winstonData?.subreddit != nil)",
      "contentWidth": "\(contentWidth)",
      "secondary": "\(secondary)"
    ]
  }

  var body: some View {
    if let data = post.data {
      let over18 = data.over_18 ?? false
      let newCommentsCount = winstonData.seenCommentsCount == nil ? nil : data.num_comments - winstonData.seenCommentsCount!

      VStack(alignment: .leading, spacing: min(theme.theme.verticalElementsSpacing, 8)) {
        HStack(alignment: .top, spacing: 10) {
          BadgeView(
            avatarRequest: winstonData.avatarImageRequest,
            showAuthorOnPostLinks: defSettings.showAuthor,
            saved: data.badgeKit.saved,
            usernameColor: nil,
            author: data.badgeKit.author,
            fullname: data.badgeKit.authorFullname,
            userFlair: data.badgeKit.userFlair,
            created: data.badgeKit.created,
            avatarURL: nil,
            theme: theme.theme.badge,
            commentsCount: formatBigNumber(data.num_comments),
            newCommentsCount: newCommentsCount,
            votesCount: defSettings.showVotesCluster ? nil : formatBigNumber(data.ups),
            likes: data.likes,
            openSub: showSub ? openSubreddit : nil,
            subName: data.subreddit
          )

          Spacer(minLength: 8)

          if defSettings.showVotesCluster {
            VotesCluster(votesKit: data.votesKit, voteAction: post.vote, showUpVoteRatio: defSettings.showUpVoteRatio)
              .fontSize(20, .medium)
          }
        }
        .postReadDimmed(post: post, theme: theme)

        if defSettings.titlePosition == .bottom { mediaComponentCall() }

        PostLinkTitle(attrString: winstonData.titleAttr, label: data.title.escape, theme: theme.theme.titleText, size: winstonData.postDimensions.titleSize, nsfw: over18, flair: data.link_flair_text)
          .padding(.top, 1)
          .postReadDimmed(post: post, theme: theme)

        if !data.selftext.isEmpty && defSettings.showSelfText {
          PostLinkNormalSelftext(selftext: data.selftext, theme: theme.theme.bodyText)
            .lineSpacing(theme.theme.linespacing)
            .postReadDimmed(post: post, theme: theme)
        }

        if defSettings.titlePosition == .top { mediaComponentCall() }

        if theme.theme.showDivider {
          SubsNStuffLine().equatable()
            .opacity(0.55)
            .postReadDimmed(post: post, theme: theme)
        }
      }
      .postLinkStyle(
        post: post,
        sub: sub,
        theme: theme,
        size: winstonData.postDimensions.size,
        secondary: secondary,
        openPost: openPost,
        readPostOnScroll: defSettings.readOnScroll,
        innerPadding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
      )
      .swipyUI(onTap: openPost, actionsSet: defSettings.swipeActions, entity: post, secondary: secondary)
    }
  }
}

struct PostLinkNormal: View, Equatable, Identifiable {
  static func == (lhs: PostLinkNormal, rhs: PostLinkNormal) -> Bool {
    return lhs.id == rhs.id && lhs.theme == rhs.theme && lhs.contentWidth == rhs.contentWidth && lhs.secondary == rhs.secondary && lhs.defSettings == rhs.defSettings
  }

  @EnvironmentObject var post: Post
  @EnvironmentObject var winstonData: PostWinstonData
  @EnvironmentObject var sub: Subreddit
  var id: String
  weak var controller: UIViewController?
  var theme: SubPostsListTheme
  var showSub = false
  var secondary = false
  let contentWidth: CGFloat
  let defSettings: PostLinkDefSettings
  /// Set on an embedded crosspost so its inline video gates on the OUTER post id (the key
  /// the feed tracks), letting it autoplay with the feed. nil for normal feed rows.
  var inlineVideoKeyOverride: String? = nil

  /// The feed-gating key for this row's inline video — the outer post id when embedded.
  var inlineVideoFeedKey: String { inlineVideoKeyOverride ?? id }

  func markAsRead() async {
    Task(priority: .background) { await post.toggleSeen(true) }
  }

  func openPost() {
    Nav.to(.reddit(.post(post)))
  }

  func openSubreddit() {
    if let subName = post.data?.subreddit {
      withAnimation {
        Nav.to(.reddit(.subFeed(Subreddit(id: subName))))
      }
    }
  }

  func resetVideo(video: SharedVideo) {
    DispatchQueue.main.async {
      let newVideo: MediaExtractedType = .video(SharedVideo.get(url: video.url, size: video.size, downloadURL: video.downloadURL, posterURL: video.posterURL, resetCache: true))
      post.winstonData?.extractedMedia = newVideo
      post.winstonData?.extractedMediaForcedNormal = newVideo

    }
  }

  func onDisappear() {
    if defSettings.readOnScroll {
      FeedScrollWorkCoordinator.shared.markSeenWhenIdle(post)
    }
  }

  var over18: Bool { post.data?.over_18 ?? false }

  @ViewBuilder
  func mediaComponentCall() -> some View {
    if let data = post.data {
      if let extractedMedia = winstonData.extractedMedia {
        MediaPresenter(postDimensions: $winstonData.postDimensions, controller: controller, postTitle: data.title, badgeKit: data.badgeKit, avatarImageRequest: winstonData.avatarImageRequest, markAsSeen: !defSettings.lightboxReadsPost ? nil : markAsRead, cornerRadius: theme.theme.mediaCornerRadius, blurPostLinkNSFW: defSettings.blurNSFW, media: extractedMedia, over18: over18, compact: false, contentWidth: winstonData.postDimensions.mediaSize?.width ?? 0, maxMediaHeightScreenPercentage: defSettings.maxMediaHeightScreenPercentage, resetVideo: resetVideo, diagnosticContext: "post:\(id):\(String(data.title.prefix(80)))", feedItemKey: inlineVideoFeedKey)
          .allowsHitTesting(defSettings.isMediaTappable || extractedMedia.alwaysAllowsInlineNavigation)

        if case .repost(let repost) = extractedMedia {
          if let repostWinstonData = repost.winstonData, let repostSub = repostWinstonData.subreddit {
            PostLink(
              id: repost.id,
              controller: controller,
              theme: theme,
              showSub: true,
              secondary: true,
              compactPerSubreddit: false,
              postStyleOverride: .classic,
              contentWidth: contentWidth,
              defSettings: defSettings,
              // Embedded video gates on the OUTER post id so it autoplays with the feed.
              inlineVideoKeyOverride: inlineVideoFeedKey
            )
            .background(Color.primary.opacity(0.05))
            .cornerRadius(theme.theme.mediaCornerRadius)
            //                }
            //            .swipyRev(size: repostWinstonData.postDimensions.size, actionsSet: postSwipeActions, entity: repost)
            .environmentObject(repost)
            .environmentObject(repostWinstonData)
            .environmentObject(repostSub)
            .onAppear {
              AppDiagnostics.asyncRecord(
                .debug,
                category: "ui.embeddedPost",
                message: "Rendering crosspost PostLink",
                metadata: embeddedPostMetadata(parentData: data, repost: repost, reason: "render")
              )
            }
          } else {
            Color.clear
              .frame(width: 0, height: 0)
              .onAppear {
                AppDiagnostics.asyncRecord(
                  .warning,
                  category: "ui.embeddedPost",
                  message: "Crosspost PostLink missing render dependencies",
                  metadata: embeddedPostMetadata(parentData: data, repost: repost, reason: "missing-dependencies")
                )
              }
          }
        }
      }
    }
  }

  func embeddedPostMetadata(parentData: PostData, repost: Post, reason: String) -> [String: String] {
    [
      "reason": reason,
      "parentPost": parentData.name,
      "parentID": id,
      "parentTitle": parentData.title,
      "repostID": repost.id,
      "repostFullname": repost.data?.name ?? "nil",
      "repostTitle": repost.data?.title ?? "nil",
      "repostSubreddit": repost.data?.subreddit ?? "nil",
      "hasWinstonData": "\(repost.winstonData != nil)",
      "hasSubreddit": "\(repost.winstonData?.subreddit != nil)",
      "contentWidth": "\(contentWidth)",
      "secondary": "\(secondary)"
    ]
  }

  var body: some View {
    if let data = post.data {
      let over18 = data.over_18 ?? false
      VStack(alignment: .leading, spacing: theme.theme.verticalElementsSpacing) {

        if theme.theme.showDivider && defSettings.dividerPosition == .top {
          SubsNStuffLine().equatable()
            .postReadDimmed(post: post, theme: theme)
        }

        if defSettings.titlePosition == .bottom { mediaComponentCall() }

        PostLinkTitle(attrString: winstonData.titleAttr, label: data.title.escape, theme: theme.theme.titleText, size: winstonData.postDimensions.titleSize, nsfw: over18, flair: data.link_flair_text)
          .padding(.bottom, 5)
          .postReadDimmed(post: post, theme: theme)

        if !data.selftext.isEmpty && defSettings.showSelfText {
          PostLinkNormalSelftext(selftext: data.selftext, theme: theme.theme.bodyText)
            .lineSpacing(theme.theme.linespacing)
            .postReadDimmed(post: post, theme: theme)
        }

        if defSettings.titlePosition == .top { mediaComponentCall() }

        if theme.theme.showDivider && defSettings.dividerPosition == .bottom {
          SubsNStuffLine().equatable()
            .postReadDimmed(post: post, theme: theme)
        }

        HStack {
          let newCommentsCount = winstonData.seenCommentsCount == nil ? nil : data.num_comments - winstonData.seenCommentsCount!
          BadgeView(avatarRequest: winstonData.avatarImageRequest, showAuthorOnPostLinks: defSettings.showAuthor, saved: data.badgeKit.saved, usernameColor: nil, author: data.badgeKit.author, fullname: data.badgeKit.authorFullname, userFlair: data.badgeKit.userFlair, created: data.badgeKit.created, avatarURL: nil, theme: theme.theme.badge, commentsCount: formatBigNumber(data.num_comments), newCommentsCount: newCommentsCount, votesCount: defSettings.showVotesCluster ? nil : formatBigNumber(data.ups), likes: data.likes, openSub: showSub ? openSubreddit : nil, subName: data.subreddit)

          Spacer()

          if defSettings.showVotesCluster { VotesCluster(votesKit: data.votesKit, voteAction: post.vote, showUpVoteRatio: defSettings.showUpVoteRatio).fontSize(22, .medium) }

        }
        .postReadDimmed(post: post, theme: theme)
      }
      .postLinkStyle(post: post, sub: sub, theme: theme, size: winstonData.postDimensions.size, secondary: secondary, openPost: openPost, readPostOnScroll: defSettings.readOnScroll)
      .swipyUI(onTap: openPost, actionsSet: defSettings.swipeActions, entity: post, secondary: secondary)
    }
  }
}

//let atr = NSTextAttachment()
//atr.
