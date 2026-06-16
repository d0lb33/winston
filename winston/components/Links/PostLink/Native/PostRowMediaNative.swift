//
//  PostRowMediaNative.swift
//  winston
//
//  Equatable media wrapper for the native, adaptive feed rows. It reuses the
//  existing MediaPresenter pipeline (images / inline video / galleries / link
//  cards) but sizes media from the LIVE column width the row measures at render
//  time + the source aspect ratio carried by the extracted media itself. That
//  makes the feed reflow when the window / fold resizes, WITHOUT depending on the
//  cached PostDimensions (which are frozen at fetch time and never recomputed on
//  resize).
//
//  `==` compares only identity + a width bucket, so the underlying AVPlayer mounts
//  exactly once and survives the scroll re-renders that would otherwise re-init it
//  (the documented AVFCore SIGABRT trap from the comments rebuild). Column width
//  only changes on resize (never on scroll), so this never churns while scrolling.
//

import SwiftUI
import NukeUI

struct PostRowMediaNative: View, Equatable {
  static func == (lhs: PostRowMediaNative, rhs: PostRowMediaNative) -> Bool {
    lhs.postID == rhs.postID
      && lhs.compact == rhs.compact
      && lhs.feedItemKey == rhs.feedItemKey
      && lhs.widthBucket == rhs.widthBucket
      && lhs.mediaIdentity == rhs.mediaIdentity
      && lhs.marksSeenOnPreview == rhs.marksSeenOnPreview
  }

  let postID: String
  let postTitle: String
  let badgeKit: BadgeKit
  let avatarImageRequest: ImageRequest?
  let media: MediaExtractedType
  let over18: Bool
  let blurNSFW: Bool
  let isMediaTappable: Bool
  let compact: Bool
  /// Live, measured content width (column width minus the row's horizontal padding).
  let columnWidth: CGFloat
  let compactThumbnailSize: ThumbnailSizeModifier
  /// Pre-decoded once upstream — never read a Codable Default in a row body.
  let maxMediaHeightPct: CGFloat
  let cornerRadius: CGFloat
  let marksSeenOnPreview: Bool
  let markAsSeen: (() async -> ())?
  /// Stable feed key (the outer post id) for inline-video center election.
  let feedItemKey: String?
  let resetVideo: ((SharedVideo) -> ())?

  /// Throwaway dimensions: the image subview writes its measured size back here for
  /// the NSFW-overlay sizing; the native row self-sizes, so we never read `.size`.
  /// Seeded with an explicit theme + compact so it never reads Defaults / getEnabledTheme.
  @State private var dims: PostDimensions

  init(
    postID: String,
    postTitle: String,
    badgeKit: BadgeKit,
    avatarImageRequest: ImageRequest?,
    media: MediaExtractedType,
    over18: Bool,
    blurNSFW: Bool,
    isMediaTappable: Bool,
    compact: Bool,
    columnWidth: CGFloat,
    compactThumbnailSize: ThumbnailSizeModifier,
    maxMediaHeightPct: CGFloat,
    cornerRadius: CGFloat,
    marksSeenOnPreview: Bool,
    markAsSeen: (() async -> ())?,
    dimsTheme: PostLinkTheme,
    feedItemKey: String?,
    resetVideo: ((SharedVideo) -> ())?
  ) {
    self.postID = postID
    self.postTitle = postTitle
    self.badgeKit = badgeKit
    self.avatarImageRequest = avatarImageRequest
    self.media = media
    self.over18 = over18
    self.blurNSFW = blurNSFW
    self.isMediaTappable = isMediaTappable
    self.compact = compact
    self.columnWidth = columnWidth
    self.compactThumbnailSize = compactThumbnailSize
    self.maxMediaHeightPct = maxMediaHeightPct
    self.cornerRadius = cornerRadius
    self.marksSeenOnPreview = marksSeenOnPreview
    self.markAsSeen = markAsSeen
    self.feedItemKey = feedItemKey
    self.resetVideo = resetVideo
    _dims = State(initialValue: PostDimensions(contentWidth: 0, compact: compact, theme: dimsTheme, titleSize: .zero, badgeSize: .zero, spacingHeight: 0))
  }

  /// Bucket the width so sub-point jitter doesn't churn the equatable identity.
  private var widthBucket: Int { Int((columnWidth / 2).rounded()) }

  /// Stable identity for the rendered media payload. Keep this narrow enough that scroll
  /// re-renders don't churn the media subtree, but broad enough that async media swaps
  /// (streamable -> video, reset video, poster URL changes) are not hidden by `.equatable()`.
  private var mediaIdentity: String {
    switch media {
    case .video(let video):
      return [
        "video",
        video.url.absoluteString,
        video.downloadURL?.absoluteString ?? "",
        video.posterURL?.absoluteString ?? "",
        "\(video.size.width)x\(video.size.height)"
      ].joined(separator: "|")
    case .streamable(let streamable):
      return "streamable|\(streamable.shortCode)"
    case .imgs(let images):
      return "imgs|\(images.map { "\($0.url.absoluteString):\($0.size.width)x\($0.size.height)" }.joined(separator: ","))"
    case .yt(let media):
      return "yt|\(media.videoID)|\(media.thumbnailURL.absoluteString)|\(media.size.width)x\(media.size.height)"
    case .link(let preview):
      return "link|\(preview.previewURL?.absoluteString ?? "")"
    case .repost(let post):
      return "repost|\(post.id)|\(post.winstonData?.extractedMedia?.isInlineVideo == true)"
    case .post(let entity):
      return "post|\(entity?.entity.id ?? "")"
    case .comment(let entity):
      return "comment|\(entity?.entity.id ?? "")"
    case .subreddit(let entity):
      return "subreddit|\(entity?.entity.id ?? "")"
    case .user(let entity):
      return "user|\(entity?.entity.id ?? "")"
    }
  }

  private var presenterWidth: CGFloat {
    compact ? scaledCompactModeThumbSize(compact: true, thumbnailSize: compactThumbnailSize) : max(1, columnWidth)
  }

  var body: some View {
    let _ = ScrollPerfProbe.shared.bump("postRowMediaNativeBody")
    MediaPresenter(
      postDimensions: $dims,
      controller: nil,
      postTitle: postTitle,
      badgeKit: badgeKit,
      avatarImageRequest: avatarImageRequest,
      markAsSeen: marksSeenOnPreview ? markAsSeen : nil,
      cornerRadius: cornerRadius,
      blurPostLinkNSFW: blurNSFW,
      media: media,
      over18: over18,
      compact: compact,
      contentWidth: presenterWidth,
      maxMediaHeightScreenPercentage: maxMediaHeightPct,
      resetVideo: resetVideo,
      diagnosticContext: "postRowNative:\(postID)",
      feedItemKey: feedItemKey
    )
    .allowsHitTesting(isMediaTappable || media.alwaysAllowsInlineNavigation)
  }
}
