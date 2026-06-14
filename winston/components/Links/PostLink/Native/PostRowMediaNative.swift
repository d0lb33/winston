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
import Defaults
import NukeUI

struct PostRowMediaNative: View, Equatable {
  static func == (lhs: PostRowMediaNative, rhs: PostRowMediaNative) -> Bool {
    lhs.postID == rhs.postID
      && lhs.compact == rhs.compact
      && lhs.feedItemKey == rhs.feedItemKey
      && lhs.widthBucket == rhs.widthBucket
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
  /// Pre-decoded once upstream — never read a Codable Default in a row body.
  let maxMediaHeightPct: CGFloat
  let cornerRadius: CGFloat
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
    maxMediaHeightPct: CGFloat,
    cornerRadius: CGFloat,
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
    self.maxMediaHeightPct = maxMediaHeightPct
    self.cornerRadius = cornerRadius
    self.feedItemKey = feedItemKey
    self.resetVideo = resetVideo
    _dims = State(initialValue: PostDimensions(contentWidth: 0, compact: compact, theme: dimsTheme, titleSize: .zero, badgeSize: .zero, spacingHeight: 0))
  }

  /// Bucket the width so sub-point jitter doesn't churn the equatable identity.
  private var widthBucket: Int { Int((columnWidth / 2).rounded()) }

  private var presenterWidth: CGFloat {
    compact ? scaledCompactModeThumbSize(compact: true, thumbnailSize: Defaults[.PostLinkDefSettings].compactMode.thumbnailSize) : max(1, columnWidth)
  }

  var body: some View {
    MediaPresenter(
      postDimensions: $dims,
      controller: nil,
      postTitle: postTitle,
      badgeKit: badgeKit,
      avatarImageRequest: avatarImageRequest,
      markAsSeen: nil,
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
