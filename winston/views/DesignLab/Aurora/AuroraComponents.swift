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
  var size: CGFloat = 30
  private var letter: String { String((name.first { $0.isLetter || $0.isNumber } ?? "r")).uppercased() }
  var body: some View {
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
        AuroraSubIcon(name: sub.data?.display_name ?? sub.id, size: 44)
        VStack(alignment: .leading, spacing: 2) {
          Text(sub.data?.display_name_prefixed ?? "r/\(sub.id)").font(.title3.weight(.bold))
          if let members = sub.data?.subscribers {
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
    .task { if sub.data?.subscribers == nil { await sub.refreshSubreddit() } }
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

struct AuroraCard: View {
  @ObservedObject var post: Post
  var isSelected: Bool = false

  var body: some View {
    if let winstonData = post.winstonData {
      AuroraCardContent(post: post, winstonData: winstonData, isSelected: isSelected)
    }
  }
}

private struct AuroraCardContent: View {
  @ObservedObject var post: Post
  @ObservedObject var winstonData: PostWinstonData
  let isSelected: Bool
  @Environment(\.auroraTheme) private var theme
  @Environment(\.contentWidth) private var envContentWidth
  @Default(.PostLinkDefSettings) private var defSettings
  /// Live row width, measured so feed media reflows on fold / rotate / split changes.
  @State private var rowWidth: CGFloat = 0

  /// Media is sized from the live row width; until the first geometry pass lands we
  /// fall back to the environment content width (≈ the column width) instead of ~0, so
  /// inline video and images never mount at a 1pt frame and render tiny.
  private var contentWidth: CGFloat {
    let base = rowWidth > 0 ? rowWidth : CGFloat(envContentWidth)
    return max(1, base - 32)
  }

  var body: some View {
    if let data = post.data {
      VStack(alignment: .leading, spacing: 11) {
        HStack(spacing: 8) {
          AuroraSubIcon(name: data.subreddit, size: 24)
          Text("r/\(data.subreddit)").font(.caption.weight(.semibold))
          Text("· \(Date(timeIntervalSince1970: data.created), format: .relative(presentation: .numeric, unitsStyle: .abbreviated))")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          if data.stickied == true {
            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(theme.accent)
          }
        }

        Text(data.title)
          .font(.headline)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)

        if !data.selftext.isEmpty, !hasDisplayMedia {
          Text(data.selftext).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
        }

        mediaBlock(data)

        if let flair = flairWithoutEmojis(str: data.link_flair_text)?.first, !flair.isEmpty {
          AuroraFlair(text: flair)
        }

        HStack(spacing: 12) {
          AuroraAvatar(name: data.author, size: 20)
          Text("u/\(data.author)")
            .font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
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
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(theme.cardFill, in: RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
          .stroke(isSelected ? theme.accent.opacity(0.9) : theme.hairline,
                  lineWidth: isSelected ? 1.8 : 0.7)
      )
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
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
        CrosspostCardNative(repost: repost, winstonData: repostWinstonData)
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
          dimsTheme: getEnabledTheme().postLinks.theme,
          feedItemKey: post.id,
          resetVideo: nil
        )
        .equatable()
        .trackInlineVideoCenter(key: post.id, coordinateSpace: "auroraFeed", enabled: media.isInlineVideo)
      }
    }
  }
}
