//
//  PostHeaderNative.swift
//  winston
//
//  Native-styled post header for the comments rebuild: title, byline, media, and
//  body. The media pipeline (images / inline video / galleries) is reused as-is
//  via MediaPresenter, but wrapped in an equatable subview so the AVPlayer mounts
//  exactly once and is never re-initialized by header re-renders (that re-init
//  storm was throwing an uncaught AVFCore exception → SIGABRT).
//

import SwiftUI
import Defaults
import MarkdownUI
import NukeUI

struct PostHeaderNative: View {
  @ObservedObject var post: Post
  @ObservedObject var winstonData: PostWinstonData
  var sub: Subreddit
  @Default(.PostPageDefSettings) private var defSettings

  var body: some View {
    let data = post.data ?? emptyPostData
    let over18 = data.over_18 ?? false
    let maxMediaHeightPct = Defaults[.PostLinkDefSettings].maxMediaHeightScreenPercentage
    VStack(alignment: .leading, spacing: 12) {
      Text(data.title)
        .font(.title3.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 6) {
        Text("u/\(data.author)")
          .foregroundStyle(.secondary)
        Text("·").foregroundStyle(.tertiary)
        Text(Date(timeIntervalSince1970: data.created), format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
          .foregroundStyle(.secondary)
        if let flair = data.link_flair_text, !flair.isEmpty {
          Text(flair)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
        }
        Spacer(minLength: 0)
      }
      .font(.footnote)

      if let extractedMedia = winstonData.extractedMediaForcedNormal {
        // A crosspost's own media is `.repost` (which MediaPresenter renders as
        // nothing) — the actual media lives on the embedded original post, so
        // render that as an inline crosspost card.
        if case .repost(let repost) = extractedMedia, let repostWinstonData = repost.winstonData {
          CrosspostCardNative(repost: repost, winstonData: repostWinstonData)
        } else {
          PostMediaNative(
            postID: post.id,
            postTitle: data.title,
            badgeKit: data.badgeKit,
            avatarImageRequest: winstonData.avatarImageRequest,
            media: extractedMedia,
            over18: over18,
            blurNSFW: defSettings.blurNSFW,
            maxMediaHeightPct: maxMediaHeightPct,
            dimensions: $winstonData.postDimensionsForcedNormal
          )
          .equatable()
        }
      }

      if !data.selftext.isEmpty {
        Markdown(MarkdownUtil.formatForMarkdown(data.selftext))
          .markdownTheme(.winstonMarkdown(fontSize: 16, lineSpacing: 2))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
    .onAppear { Task { await post.toggleSeen(true) } }
  }
}

/// Equatable wrapper around MediaPresenter. Compared only by post id, so the
/// player view is built once per post and survives header re-renders untouched.
private struct PostMediaNative: View, Equatable {
  static func == (lhs: PostMediaNative, rhs: PostMediaNative) -> Bool { lhs.postID == rhs.postID }

  let postID: String
  let postTitle: String
  let badgeKit: BadgeKit
  let avatarImageRequest: ImageRequest?
  let media: MediaExtractedType
  let over18: Bool
  let blurNSFW: Bool
  /// Passed in (decoded once by the caller) so this equatable body never JSON-decodes
  /// PostLinkDefSettings when it re-evaluates on a video-surface refresh.
  let maxMediaHeightPct: CGFloat
  @Binding var dimensions: PostDimensions

  var body: some View {
    MediaPresenter(
      postDimensions: $dimensions,
      controller: nil,
      postTitle: postTitle,
      badgeKit: badgeKit,
      avatarImageRequest: avatarImageRequest,
      markAsSeen: {},
      cornerRadius: 12,
      blurPostLinkNSFW: blurNSFW,
      media: media,
      over18: over18,
      compact: false,
      contentWidth: dimensions.mediaSize?.width ?? 0,
      maxMediaHeightScreenPercentage: maxMediaHeightPct,
      resetVideo: nil,
      diagnosticContext: "postDetailNative:\(postID)"
    )
    .nsfw(over18 && blurNSFW)
  }
}

/// Inline card for a crossposted ("repost") post. The outer post's media is
/// `.repost`, which renders nothing — the real media (and title/body) live on the
/// embedded original post, so render those here. Shared by the native and legacy
/// post-detail headers (both only called MediaPresenter, which skips `.repost`).
struct CrosspostCardNative: View {
  @ObservedObject var repost: Post
  @ObservedObject var winstonData: PostWinstonData
  var contentWidth: CGFloat? = nil
  @Default(.PostPageDefSettings) private var defSettings
  @Default(.PostLinkDefSettings) private var postLinkDefSettings
  @Environment(\.useTheme) private var selectedTheme

  private var constrainedWidth: CGFloat? {
    contentWidth.map { max(1, $0) }
  }

  private var constrainedMediaWidth: CGFloat {
    max(1, (constrainedWidth ?? 0) - 24)
  }

  var body: some View {
    if let data = repost.data {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 5) {
          Image(systemName: "arrow.2.squarepath")
          Text("Crossposted from r/\(data.subreddit)")
            .fontWeight(.medium)
          Spacer(minLength: 0)
          Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .onTapGesture { Nav.to(.reddit(.post(repost))) }

        Text(data.title)
          .font(.subheadline.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)

        if let media = winstonData.extractedMediaForcedNormal {
          if constrainedWidth != nil {
            PostRowMediaNative(
              postID: repost.id,
              postTitle: data.title,
              badgeKit: data.badgeKit,
              avatarImageRequest: winstonData.avatarImageRequest,
              media: media,
              over18: data.over_18 ?? false,
              blurNSFW: defSettings.blurNSFW,
              isMediaTappable: postLinkDefSettings.isMediaTappable,
              compact: false,
              columnWidth: constrainedMediaWidth,
              maxMediaHeightPct: postLinkDefSettings.maxMediaHeightScreenPercentage,
              cornerRadius: 12,
              marksSeenOnPreview: postLinkDefSettings.lightboxReadsPost,
              markAsSeen: { await repost.toggleSeen(true) },
              dimsTheme: selectedTheme.postLinks.theme,
              feedItemKey: repost.id,
              resetVideo: nil
            )
            .equatable()
          } else {
            PostMediaNative(
              postID: repost.id,
              postTitle: data.title,
              badgeKit: data.badgeKit,
              avatarImageRequest: winstonData.avatarImageRequest,
              media: media,
              over18: data.over_18 ?? false,
              blurNSFW: defSettings.blurNSFW,
              maxMediaHeightPct: Defaults[.PostLinkDefSettings].maxMediaHeightScreenPercentage,
              dimensions: $winstonData.postDimensionsForcedNormal
            )
            .equatable()
          }
        }

        if !data.selftext.isEmpty {
          Markdown(MarkdownUtil.formatForMarkdown(data.selftext))
            .markdownTheme(.winstonMarkdown(fontSize: 15, lineSpacing: 2))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(12)
      .frame(width: constrainedWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
  }
}

/// Compact, native action bar for the post (vote / comments / save / reply / share).
struct PostActionBarNative: View {
  @ObservedObject var post: Post
  var updateComments: ((Comment) -> ())? = nil
  @State private var showReplyModal = false

  var body: some View {
    if let data = post.data {
      let permaURL = URL(string: "https://reddit.com\(data.permalink.escape.urlEncoded)")
      HStack(spacing: 18) {
        NativeVoteControl(
          likes: data.likes,
          score: data.ups,
          prominent: true,
          onUp: { _ = await post.vote(.up) },
          onDown: { _ = await post.vote(.down) }
        )

        Label("\(data.num_comments)", systemImage: "bubble.left")
          .foregroundStyle(.secondary)
          .accessibilityLabel("\(data.num_comments) comments")

        Spacer()

        Button {
          SaveChooserInstance.shared.enable(.post(post))
        } label: {
          Image(systemName: data.saved ? "bookmark.fill" : "bookmark")
            .foregroundStyle(data.saved ? .green : .secondary)
        }
        .accessibilityLabel(data.saved ? "Unsave" : "Save")

        Button {
          showReplyModal = true
        } label: {
          Image(systemName: "arrowshape.turn.up.left")
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Reply")

        if let permaURL {
          ShareLink(item: permaURL) {
            Image(systemName: "square.and.arrow.up")
              .foregroundStyle(.secondary)
          }
          .simultaneousGesture(TapGesture().onEnded {
            Task { await post.markInteractedAsRead() }
          })
          .accessibilityLabel("Share")
        }
      }
      .font(.subheadline)
      .buttonStyle(.borderless)
      .padding(.vertical, 6)
      .sheet(isPresented: $showReplyModal) {
        ReplyModalPost(post: post, updateComments: updateComments)
      }
    }
  }
}
