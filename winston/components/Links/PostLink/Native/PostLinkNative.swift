//
//  PostLinkNative.swift
//  winston
//
//  Plain, native-styled feed row (no card): system typography, full-width media,
//  a compact byline + native vote control. Self-sizing, so it drops straight into
//  the adaptive LazyVGrid in PostsFeedNative and reflows when the column width
//  changes. Media is sized from the LIVE measured width (PostRowMediaNative), and
//  external links that carry a preview image render "fuller" via LinkImageCardNative.
//

import SwiftUI
import Defaults
import NukeUI

struct PostLinkNative: View, Equatable, Identifiable {
  static func == (lhs: PostLinkNative, rhs: PostLinkNative) -> Bool {
    lhs.id == rhs.id && lhs.theme == rhs.theme && lhs.contentWidth == rhs.contentWidth && lhs.secondary == rhs.secondary && lhs.defSettings == rhs.defSettings
  }

  @EnvironmentObject var post: Post
  @EnvironmentObject var winstonData: PostWinstonData
  @EnvironmentObject var sub: Subreddit
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin
  var id: String
  weak var controller: UIViewController?
  var theme: SubPostsListTheme
  var showSub = false
  var secondary = false
  let contentWidth: CGFloat
  let defSettings: PostLinkDefSettings
  /// Set on an embedded crosspost so its inline video gates on the OUTER post id.
  var inlineVideoKeyOverride: String? = nil

  var inlineVideoFeedKey: String { inlineVideoKeyOverride ?? id }
  var over18: Bool { post.data?.over_18 ?? false }

  func markAsRead() async { await post.toggleSeen(true) }

  func openPost() {
    navigateRedditDestination(.reddit(.post(post)), model: redditNavigationModel, origin: redditNavigationOrigin)
  }

  func openSubreddit() {
    if let subName = post.data?.subreddit {
      withAnimation {
        navigateRedditDestination(.reddit(.subFeed(Subreddit(id: subName))), model: redditNavigationModel, origin: redditNavigationOrigin)
      }
    }
  }

  func openAuthor() {
    if let author = post.data?.author, !author.isEmpty, author != "[deleted]" {
      navigateRedditDestination(.reddit(.user(User(id: author))), model: redditNavigationModel, origin: redditNavigationOrigin)
    }
  }

  func resetVideo(video: SharedVideo) {
    DispatchQueue.main.async {
      let newVideo: MediaExtractedType = .video(SharedVideo.get(url: video.url, size: video.size, downloadURL: video.downloadURL, posterURL: video.posterURL, resetCache: true))
      post.winstonData?.extractedMedia = newVideo
      post.winstonData?.extractedMediaForcedNormal = newVideo
    }
  }

  // MARK: - Chips (NSFW / flair). Kept as a single ForEach so the row's opaque
  // type stays data-independent (avoids the type-metadata storm on scroll).
  private struct Chip: Identifiable { let id: String; let text: String; let nsfw: Bool }

  private func chips(_ data: PostData) -> [Chip] {
    var out: [Chip] = []
    if data.over_18 ?? false { out.append(Chip(id: "nsfw", text: "NSFW", nsfw: true)) }
    if let flair = flairWithoutEmojis(str: data.link_flair_text)?.first, !flair.isEmpty {
      out.append(Chip(id: "flair", text: flair, nsfw: false))
    }
    return out
  }

  private func chipView(_ chip: Chip) -> some View {
    Text(chip.text)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(chip.nsfw ? Color.red : Color.secondary)
      .lineLimit(1)
      .padding(.horizontal, 5).padding(.vertical, 1)
      .background(chip.nsfw ? AnyShapeStyle(Color.red.opacity(0.15)) : AnyShapeStyle(.quaternary), in: Capsule())
  }

  // MARK: - Media

  @ViewBuilder
  private func mediaBlock(_ data: PostData, liveWidth: CGFloat) -> some View {
    if let media = winstonData.extractedMediaForcedNormal {
      if case .repost(let repost) = media, let repostWinstonData = repost.winstonData {
        CrosspostCardNative(repost: repost, winstonData: repostWinstonData)
      } else if case .link(let previewModel) = media, let img = redditPreviewLinkImage(data) {
        LinkImageCardNative(
          imageURL: img.url,
          sourceSize: img.size,
          displayURL: previewModel.previewURL ?? img.url,
          columnWidth: liveWidth,
          maxMediaHeightPct: defSettings.maxMediaHeightScreenPercentage,
          cornerRadius: theme.theme.mediaCornerRadius
        )
        .equatable()
      } else {
        PostRowMediaNative(
          postID: id,
          postTitle: data.title,
          badgeKit: data.badgeKit,
          avatarImageRequest: winstonData.avatarImageRequest,
          media: media,
          over18: over18,
          blurNSFW: defSettings.blurNSFW,
          isMediaTappable: defSettings.isMediaTappable,
          compact: false,
          columnWidth: liveWidth,
          maxMediaHeightPct: defSettings.maxMediaHeightScreenPercentage,
          cornerRadius: theme.theme.mediaCornerRadius,
          marksSeenOnPreview: defSettings.lightboxReadsPost,
          markAsSeen: markAsRead,
          dimsTheme: theme.theme,
          feedItemKey: inlineVideoFeedKey,
          resetVideo: resetVideo
        )
        .equatable()
      }
    }
  }

  var body: some View {
    if let data = post.data {
      // Use the grid-computed column width (passed in) rather than self-measuring:
      // the media is sized FROM this width, so measuring our own (content-influenced)
      // width fed back into a stale/oversized loop after rotation / column changes.
      let liveWidth = max(1, contentWidth)
      VStack(alignment: .leading, spacing: 0) {
        // Chips row (zero height when empty → no spurious gap).
        HStack(spacing: 6) { ForEach(chips(data)) { chipView($0) } }
          .padding(.bottom, chips(data).isEmpty ? 0 : 6)
          .postReadDimmed(post: post, theme: theme)

        Text(data.title)
          .font(.headline)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .postReadDimmed(post: post, theme: theme)

        if !data.selftext.isEmpty && defSettings.showSelfText {
          Text(data.selftext)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .postReadDimmed(post: post, theme: theme)
        }

        mediaBlock(data, liveWidth: liveWidth)
          .padding(.top, 10)

        footer(data)
          .padding(.top, 10)
          .postReadDimmed(post: post, theme: theme)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .contextMenu { PostLinkContext(post: post) } preview: { PostLinkContextPreview(post: post, sub: sub) }
      .swipyUI(onTap: openPost, actionsSet: defSettings.swipeActions, entity: post, secondary: secondary)
    }
  }

  // MARK: - Footer (byline + comments + votes)

  @ViewBuilder
  private func footer(_ data: PostData) -> some View {
    HStack(spacing: 6) {
      Text("u/\(data.author)")
        .foregroundStyle(.secondary)
        .onTapGesture { openAuthor() }
      Text("·").foregroundStyle(.tertiary)
      Text(Date(timeIntervalSince1970: data.created), format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
        .foregroundStyle(.secondary)
      if showSub {
        Text("·").foregroundStyle(.tertiary)
        Text("r/\(data.subreddit)")
          .foregroundStyle(.secondary)
          .onTapGesture { openSubreddit() }
      }

      Spacer(minLength: 6)

      Label(formatBigNumber(data.num_comments), systemImage: "bubble.left")
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)

      if defSettings.showVotesCluster {
        NativeVoteControl(
          likes: data.likes,
          score: data.ups,
          onUp: { _ = await post.vote(.up) },
          onDown: { _ = await post.vote(.down) }
        )
      }
    }
    .font(.footnote)
    .lineLimit(1)
  }
}
