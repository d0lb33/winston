//
//  PostLinkNativeCompact.swift
//  winston
//
//  Plain, native-styled COMPACT feed row: a side thumbnail + title + byline. Used
//  when the resolved post style is `.compact`. Honors the existing compact settings
//  (thumbnail side / size / placeholder). Self-sizing for the adaptive grid.
//

import SwiftUI
import Defaults
import NukeUI

struct PostLinkNativeCompact: View, Equatable, Identifiable {
  static func == (lhs: PostLinkNativeCompact, rhs: PostLinkNativeCompact) -> Bool {
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

  var over18: Bool { post.data?.over_18 ?? false }
  private var thumbSize: CGFloat { scaledCompactModeThumbSize(compact: true, thumbnailSize: defSettings.compactMode.thumbnailSize) }

  func openPost() { Nav.to(.reddit(.post(post))) }
  func openSubreddit() {
    if let subName = post.data?.subreddit { Nav.to(.reddit(.subFeed(Subreddit(id: subName)))) }
  }
  func openAuthor() {
    if let author = post.data?.author, !author.isEmpty, author != "[deleted]" {
      Nav.to(.reddit(.user(User(id: author))))
    }
  }
  func resetVideo(video: SharedVideo) {
    DispatchQueue.main.async {
      let newVideo: MediaExtractedType = .video(SharedVideo.get(url: video.url, size: video.size, downloadURL: video.downloadURL, posterURL: video.posterURL, resetCache: true))
      post.winstonData?.extractedMedia = newVideo
      post.winstonData?.extractedMediaForcedNormal = newVideo
    }
  }
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

  @ViewBuilder
  private var thumb: some View {
    Group {
      if let media = winstonData.extractedMedia {
        if case .repost(let repost) = media, let repostData = repost.data, let url = URL(string: "https://reddit.com/r/\(repostData.subreddit)/comments/\(repost.id)") {
          PreviewLink(url: url, compact: true, previewModel: PreviewModel.get(url, compact: true))
        } else if let data = post.data {
          PostRowMediaNative(
            postID: id,
            postTitle: data.title,
            badgeKit: data.badgeKit,
            avatarImageRequest: winstonData.avatarImageRequest,
            media: media,
            over18: over18,
            blurNSFW: defSettings.blurNSFW,
            isMediaTappable: defSettings.isMediaTappable,
            compact: true,
            columnWidth: thumbSize,
            maxMediaHeightPct: defSettings.maxMediaHeightScreenPercentage,
            cornerRadius: theme.theme.mediaCornerRadius,
            dimsTheme: theme.theme,
            feedItemKey: id,
            resetVideo: resetVideo
          )
          .equatable()
        }
      } else if defSettings.compactMode.showPlaceholderThumbnail {
        PostLinkCompactThumbPlaceholder(theme: theme.theme.compactSelftextPostLinkPlaceholderImg).equatable()
      }
    }
    .frame(width: thumbSize, height: thumbSize)
    .clipped()
  }

  var body: some View {
    if let data = post.data {
      HStack(alignment: .top, spacing: 12) {
        if defSettings.compactMode.thumbnailSide == .leading { thumb }

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) { ForEach(chips(data)) { chipView($0) } }
            .padding(.bottom, chips(data).isEmpty ? 0 : 2)

          Text(data.title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

          footer(data)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)

        if defSettings.compactMode.thumbnailSide == .trailing { thumb }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .postReadDimmed(post: post, theme: theme)
      .contextMenu { PostLinkContext(post: post) } preview: { PostLinkContextPreview(post: post, sub: sub) }
      .swipyUI(onTap: openPost, actionsSet: defSettings.swipeActions, entity: post, secondary: secondary)
    }
  }

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
