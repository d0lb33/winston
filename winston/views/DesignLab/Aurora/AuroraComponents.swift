//
//  AuroraComponents.swift
//  winston
//
//  Aurora — shared Liquid Glass building blocks, driven by `AuroraTheme` from the
//  environment. These are the production components now wired to the real Reddit
//  entities (Post / Subreddit) and the production media pipeline (MediaPresenter via
//  PostRowMediaNative). The mock value types are gone.
//
//  PERFORMANCE: real `.glassEffect` (live blur) is reserved for a few *chrome*
//  elements (vote pills, sort bar, composer, close). Scrolling feed cards use a cheap
//  translucent fill — live-blur materials re-blurred against the animating mesh on
//  every scroll frame overwhelm the render server and hang the UI.
//

import SwiftUI
import Defaults
import NukeUI
import UIKit

// MARK: - Offline palette (stable per-seed colors; no network, cheap under scroll)

enum AuroraPalette {
  static let colors: [Color] = [
    .indigo, .teal, .pink, Color(red: 1.0, green: 0.72, blue: 0.22),
    .green, .blue, .purple, .orange, .mint, .red,
  ]

  static func color(for seed: String) -> Color {
    var hash = 5381
    for byte in seed.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
    return colors[abs(hash) % colors.count]
  }

  static func gradient(for seed: String) -> [Color] {
    let base = color(for: seed)
    return [base.opacity(0.95), base.opacity(0.6)]
  }
}

// MARK: - Living mesh backdrop

/// A slow, state-driven aurora. Animated as a single GPU mesh layer (no per-frame
/// TimelineView redraw, no live-blur surfaces in front) so it stays smooth under scroll.
struct AuroraBackdrop: View {
  let theme: AuroraTheme
  @State private var drift: CGFloat = 0

  var body: some View {
    let dx = Float(sin(Double(drift))) * 0.06
    let dy = Float(cos(Double(drift) * 0.8)) * 0.06
    let dx2 = Float(cos(Double(drift) * 0.6)) * 0.05

    MeshGradient(
      width: 3, height: 3,
      points: [
        .init(0, 0), .init(0.5, 0), .init(1, 0),
        .init(0, 0.5), .init(0.5 + dx, 0.5 + dy), .init(1, 0.5),
        .init(0, 1), .init(0.5 + dx2, 1), .init(1, 1),
      ],
      colors: theme.meshColors
    )
    .overlay(
      RadialGradient(colors: [.clear, theme.vignette.opacity(theme.vignetteStrength)],
                     center: .center, startRadius: 280, endRadius: 900)
    )
    .ignoresSafeArea()
    .onAppear {
      withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) {
        drift = .pi
      }
    }
  }
}

// MARK: - Icons & avatars (offline monograms)

struct AuroraSubIcon: View {
  let name: String
  var iconKit: SubredditIconKit? = nil
  var size: CGFloat = 30
  private var letter: String { String((name.first { $0.isLetter || $0.isNumber } ?? "r")).uppercased() }
  var body: some View {
    if let urlString = iconKit?.url, let url = URL(string: urlString) {
      LazyImage(url: url) { state in
        if let image = state.image {
          image
            .resizable()
            .scaledToFill()
        } else {
          monogram
        }
      }
      .processors([.resize(width: size)])
      .frame(width: size, height: size)
      .clipShape(Circle())
    } else {
      monogram
    }
  }

  private var monogram: some View {
    Circle()
      .fill(LinearGradient(colors: AuroraPalette.gradient(for: name), startPoint: .topLeading, endPoint: .bottomTrailing))
      .frame(width: size, height: size)
      .overlay(
        Text(letter)
          .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
      )
  }
}

extension Subreddit {
  var needsAuroraMetadataRefresh: Bool {
    guard let data else { return true }
    let hasMembers = (data.subscribers ?? 0) > 0
    let hasIcon = data.subredditIconKit.url?.isEmpty == false
    return !hasMembers || !hasIcon
  }
}

/// Offline monogram avatar (no network) — keeps scrolling cheap.
struct AuroraAvatar: View {
  let name: String
  var size: CGFloat = 22
  private var letter: String { String((name.first { $0.isLetter || $0.isNumber } ?? "u")).uppercased() }
  var body: some View {
    Circle()
      .fill(LinearGradient(colors: AuroraPalette.gradient(for: name), startPoint: .top, endPoint: .bottom))
      .frame(width: size, height: size)
      .overlay(
        Text(letter)
          .font(.system(size: size * 0.48, weight: .bold))
          .foregroundStyle(.white)
      )
  }
}

// MARK: - Flair

struct AuroraFlair: View {
  let text: String
  @Environment(\.auroraTheme) private var theme
  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .lineLimit(1)
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(theme.accent.opacity(0.22), in: .capsule)
      .foregroundStyle(theme.accent)
  }
}

// MARK: - Interactive glass vote pill (chrome — real glass is fine here)

struct GlassVotePill: View {
  let likes: Bool?
  let score: Int
  var compact: Bool = false
  let onUp: () async -> Void
  let onDown: () async -> Void
  @Environment(\.auroraTheme) private var theme

  var body: some View {
    HStack(spacing: compact ? 8 : 11) {
      voteButton("arrow.up", active: likes == true, color: theme.accent) { Task { await onUp() } }
      Text(formatBigNumber(score))
        .font(.subheadline.weight(.semibold)).monospacedDigit()
        .foregroundStyle(likes == true ? theme.accent : likes == false ? theme.downvote : .primary)
        .contentTransition(.numericText())
      voteButton("arrow.down", active: likes == false, color: theme.downvote) { Task { await onDown() } }
    }
    .padding(.horizontal, compact ? 12 : 14)
    .padding(.vertical, compact ? 7 : 9)
    .glassEffect(.regular.interactive(), in: .capsule)
  }

  private func voteButton(_ symbol: String, active: Bool, color: Color, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: compact ? 13 : 15, weight: .bold))
        .foregroundStyle(active ? color : .secondary)
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Link chip

struct AuroraLinkChip: View {
  let domain: String
  @Environment(\.auroraTheme) private var theme
  var body: some View {
    Label(domain, systemImage: "safari.fill")
      .font(.caption.weight(.semibold))
      .lineLimit(1)
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(theme.chipFill, in: .capsule)
      .foregroundStyle(.secondary)
  }
}

// MARK: - Community header (feed)

struct AuroraCommunityHeader: View {
  @ObservedObject var sub: Subreddit
  @Environment(\.auroraTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        AuroraSubIcon(name: sub.data?.display_name ?? sub.id, iconKit: sub.data?.subredditIconKit, size: 44)
        VStack(alignment: .leading, spacing: 2) {
          Text(sub.displayTitle).font(.title3.weight(.bold))
          if let members = sub.data?.subscribers, members > 0 {
            Text("\(formatBigNumber(members)) members")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer()
        joinButton
      }
      if let about = sub.data?.public_description, !about.isEmpty {
        Text(about)
          .font(.subheadline).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(16)
    .background(theme.cardFill, in: RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).stroke(theme.hairline, lineWidth: 0.7)
    )
    .onAppear {
      Task {
        if sub.needsAuroraMetadataRefresh {
          await sub.refreshSubreddit()
        }
      }
    }
  }

  private var joinButton: some View {
    let joined = sub.data?.user_is_subscriber ?? false
    return Button {
      sub.subscribeToggle(optimistic: true)
    } label: {
      Text(joined ? "Joined" : "Join")
        .font(.subheadline.weight(.bold))
        .foregroundStyle(joined ? theme.accent : (theme.isDark ? .black : .white))
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(joined ? theme.chipFill : theme.accent, in: .capsule)
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Feed card

struct AuroraPostCardRow: View {
  @ObservedObject var post: Post
  var isSelected: Bool = false
  var onCompactNavigate: ((Router.NavDest) -> Void)? = nil
  var onSelect: (() -> Void)? = nil

  @State private var cardWidth: CGFloat = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Color.clear
        .frame(height: 0)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.width
        } action: { newWidth in
          let measuredWidth = max(1, newWidth)
          guard abs(measuredWidth - cardWidth) > 0.5 else { return }
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) {
            ScrollPerfProbe.shared.bump("auroraRowWidthChange")
            cardWidth = measuredWidth
          }
        }

      if cardWidth > 0 {
        AuroraCard(
          post: post,
          cardWidth: cardWidth,
          isSelected: isSelected,
          onCompactNavigate: onCompactNavigate
        )
        .frame(width: cardWidth, alignment: .leading)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .modifier(AuroraPostCardRowTapModifier(onSelect: onSelect))
  }
}

private struct AuroraPostCardRowTapModifier: ViewModifier {
  let onSelect: (() -> Void)?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let onSelect {
      content.onTapGesture(perform: onSelect)
    } else {
      content
    }
  }
}

struct AuroraCard: View {
  @ObservedObject var post: Post
  let cardWidth: CGFloat
  var isSelected: Bool = false
  var onCompactNavigate: ((Router.NavDest) -> Void)? = nil

  var body: some View {
    let _ = ScrollPerfProbe.shared.bump("auroraCardBody")
    if let winstonData = post.winstonData {
      AuroraCardContent(
        post: post,
        winstonData: winstonData,
        cardWidth: cardWidth,
        isSelected: isSelected,
        onCompactNavigate: onCompactNavigate
      )
    }
  }
}

private struct AuroraCardContent: View {
  @ObservedObject var post: Post
  @ObservedObject var winstonData: PostWinstonData
  let cardWidth: CGFloat
  let isSelected: Bool
  let onCompactNavigate: ((Router.NavDest) -> Void)?
  @Environment(\.auroraTheme) private var theme
  @Environment(\.useTheme) private var selectedTheme
  @Environment(\.horizontalSizeClass) private var hSize
  @Default(.PostLinkDefSettings) private var defSettings

  /// Media is sized from the row-owned card width. The card never measures itself,
  /// so media cannot feed back into the width used to lay out the row.
  private var contentWidth: CGFloat {
    max(1, cardWidth - 32)
  }

  private func markAsRead() async {
    await post.toggleSeen(true)
  }

  var body: some View {
    let _ = ScrollPerfProbe.shared.bump("auroraCardContentBody")
    if let data = post.data {
      let readOpacity = data.winstonSeen == true ? 0.6 : 1
      VStack(alignment: .leading, spacing: 11) {
        HStack(spacing: 8) {
          Button { openSubreddit(data.subreddit) } label: {
            HStack(spacing: 8) {
              AuroraSubIcon(name: data.subreddit, size: 24)
              Text("r/\(data.subreddit)").font(.caption.weight(.semibold)).foregroundStyle(.primary)
            }
          }
          .buttonStyle(.borderless)
          Text("· \(Date(timeIntervalSince1970: data.created), format: .relative(presentation: .numeric, unitsStyle: .abbreviated))")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          if data.stickied == true {
            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(theme.accent)
          }
        }
        .opacity(readOpacity)

        Text(data.title)
          .font(.headline)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
          .opacity(readOpacity)

        if !data.selftext.isEmpty, !hasDisplayMedia {
          Text(data.selftext).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
            .opacity(readOpacity)
        }

        mediaBlock(data)

        if let flair = flairWithoutEmojis(str: data.link_flair_text)?.first, !flair.isEmpty {
          AuroraFlair(text: flair)
            .opacity(readOpacity)
        }

        HStack(spacing: 12) {
          Button { openAuthor(data.author) } label: {
            HStack(spacing: 6) {
              AuroraAvatar(name: data.author, size: 20)
              Text("u/\(data.author)").font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            }
          }
          .buttonStyle(.borderless)
          Spacer(minLength: 8)
          Label(formatBigNumber(data.num_comments), systemImage: "bubble.left.fill")
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
          NativeVoteControl(
            likes: data.likes,
            score: data.ups,
            onUp: { _ = await post.vote(.up) },
            onDown: { _ = await post.vote(.down) }
          )
          .buttonStyle(.borderless)
        }
        .opacity(readOpacity)
      }
      .padding(16)
      .frame(width: cardWidth, alignment: .leading)
      .background(theme.cardFill, in: RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
          .stroke(isSelected ? theme.accent.opacity(0.9) : theme.hairline,
                  lineWidth: isSelected ? 1.8 : 0.7)
      )
      .contextMenu { contextMenuItems(data) }
    }
  }

  // MARK: - Card actions

  private func openAuthor(_ author: String) {
    guard !author.isEmpty, author != "[deleted]" else { return }
    navigate(.reddit(.user(User(id: author))))
  }

  private func openSubreddit(_ name: String) {
    guard !name.isEmpty else { return }
    navigate(.reddit(.subFeed(Subreddit(id: name))))
  }

  private func navigate(_ destination: Router.NavDest) {
    if hSize == .compact, let onCompactNavigate {
      onCompactNavigate(destination)
    } else {
      Nav.to(destination)
    }
  }

  private func permalink(_ data: PostData) -> URL? {
    URL(string: "https://reddit.com\(data.permalink.escape.urlEncoded)")
  }

  @ViewBuilder
  private func contextMenuItems(_ data: PostData) -> some View {
    Button { Task { _ = await post.vote(.up) } } label: { Label("Upvote", systemImage: "arrow.up") }
    Button { Task { _ = await post.vote(.down) } } label: { Label("Downvote", systemImage: "arrow.down") }
    Button { Task { _ = await post.saveToggle() } } label: {
      Label(data.saved ? "Unsave" : "Save", systemImage: data.saved ? "bookmark.fill" : "bookmark")
    }
    Button { ReplyModalInstance.shared.enable(.post(post)) } label: {
      Label("Reply", systemImage: "arrowshape.turn.up.left")
    }
    Divider()
    Button { openAuthor(data.author) } label: { Label("u/\(data.author)", systemImage: "person.circle") }
    Button { openSubreddit(data.subreddit) } label: { Label("r/\(data.subreddit)", systemImage: "rectangle.stack") }
    Divider()
    if let url = permalink(data) {
      ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
        .simultaneousGesture(TapGesture().onEnded {
          Task { await post.markInteractedAsRead() }
        })
      Button {
        Task { await post.markInteractedAsRead() }
        UIPasteboard.general.url = url
      } label: { Label("Copy Link", systemImage: "link") }
    }
  }

  private var hasDisplayMedia: Bool {
    guard let media = winstonData.extractedMediaForcedNormal else { return false }
    if case .link = media { return false }
    return true
  }

  @ViewBuilder
  private func mediaBlock(_ data: PostData) -> some View {
    if let media = winstonData.extractedMediaForcedNormal {
      if case .repost(let repost) = media, let repostWinstonData = repost.winstonData {
        CrosspostCardNative(repost: repost, winstonData: repostWinstonData, contentWidth: contentWidth)
      } else {
        PostRowMediaNative(
          postID: post.id,
          postTitle: data.title,
          badgeKit: data.badgeKit,
          avatarImageRequest: winstonData.avatarImageRequest,
          media: media,
          over18: data.over_18 ?? false,
          blurNSFW: defSettings.blurNSFW,
          isMediaTappable: defSettings.isMediaTappable,
          compact: false,
          columnWidth: contentWidth,
          maxMediaHeightPct: defSettings.maxMediaHeightScreenPercentage,
          cornerRadius: theme.mediaRadius,
          marksSeenOnPreview: defSettings.lightboxReadsPost,
          markAsSeen: markAsRead,
          dimsTheme: selectedTheme.postLinks.theme,
          feedItemKey: post.id,
          resetVideo: nil
        )
        .equatable()
        .trackInlineVideoCenter(key: post.id, coordinateSpace: "auroraFeed", enabled: media.isInlineVideo)
      }
    }
  }
}
