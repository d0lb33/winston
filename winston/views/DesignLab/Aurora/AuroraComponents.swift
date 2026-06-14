//
//  AuroraComponents.swift
//  winston
//
//  Design Lab · Aurora family — shared Liquid Glass building blocks, driven by
//  `AuroraTheme` from the environment so the same views render as midnight / dawn / eclipse.
//
//  PERFORMANCE: real `.glassEffect` (live blur) is reserved for a few *chrome* elements
//  (vote pills, sort bar, composer, close). Scrolling feed cards use a cheap translucent
//  fill — live-blur materials re-blurred against the animating mesh on every scroll frame
//  overwhelm the render server and hang the UI.
//

import SwiftUI

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

// MARK: - Icons & avatars

struct AuroraSubIcon: View {
  let sub: MockSubreddit
  var size: CGFloat = 30
  var body: some View {
    Circle()
      .fill(sub.accent.color.gradient)
      .frame(width: size, height: size)
      .overlay(
        Text(String(sub.name.prefix(1)).uppercased())
          .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
      )
  }
}

/// Offline monogram avatar (no network) — keeps scrolling cheap.
struct AuroraAvatar: View {
  let seed: String
  let name: String
  var size: CGFloat = 22
  var body: some View {
    Circle()
      .fill(LinearGradient(colors: MockMediaPalette.colors(for: seed), startPoint: .top, endPoint: .bottom))
      .frame(width: size, height: size)
      .overlay(
        Text(String(name.prefix(1)).uppercased())
          .font(.system(size: size * 0.48, weight: .bold))
          .foregroundStyle(.white)
      )
  }
}

// MARK: - Flair

struct AuroraFlair: View {
  let flair: MockFlair
  var body: some View {
    Text(flair.text)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(flair.tint.color.opacity(0.24), in: .capsule)
      .foregroundStyle(flair.tint.color)
  }
}

// MARK: - Interactive glass vote pill (chrome — real glass is fine here)

struct GlassVotePill: View {
  let score: Int
  var compact: Bool = false
  @Environment(\.auroraTheme) private var theme
  @State private var vote = 0

  private var shown: Int { score + vote }

  var body: some View {
    HStack(spacing: compact ? 8 : 11) {
      voteButton("arrow.up", active: vote == 1, color: theme.accent) {
        withAnimation(.snappy) { vote = vote == 1 ? 0 : 1 }
      }
      Text(MockFormatting.compactNumber(shown))
        .font(.subheadline.weight(.semibold)).monospacedDigit()
        .foregroundStyle(vote == 1 ? theme.accent : vote == -1 ? theme.downvote : .primary)
        .contentTransition(.numericText())
      voteButton("arrow.down", active: vote == -1, color: theme.downvote) {
        withAnimation(.snappy) { vote = vote == -1 ? 0 : -1 }
      }
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

// MARK: - Media

struct AuroraMedia: View {
  let post: MockPost
  let media: MockMediaSeed
  var maxHeight: CGFloat = 300
  @Environment(\.auroraTheme) private var theme
  @State private var revealed = false

  private var blurred: Bool { (post.isNSFW || post.isSpoiler) && !revealed }

  var body: some View {
    SeededRemoteImage(
      seed: media.seed,
      pixelWidth: 1000,
      pixelHeight: Int(1000 / max(media.aspect, 0.4)),
      blurred: blurred
    )
    .frame(maxWidth: .infinity)
    .aspectRatio(media.aspect, contentMode: .fit)
    .frame(maxHeight: maxHeight)
    .clipShape(RoundedRectangle(cornerRadius: theme.mediaRadius, style: .continuous))
    .overlay(alignment: .topTrailing) {
      if media.count > 1 {
        Label("1/\(media.count)", systemImage: "square.on.square")
          .font(.caption2.weight(.semibold))
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(.black.opacity(0.5), in: .capsule)
          .foregroundStyle(.white)
          .padding(10)
      }
    }
    .overlay {
      if blurred {
        VStack(spacing: 6) {
          Image(systemName: "eye.slash.fill").font(.title2)
          Text(post.isSpoiler ? "Spoiler" : "NSFW").font(.subheadline.weight(.semibold))
          Text("Tap to reveal").font(.caption).foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { if blurred { withAnimation(.easeOut) { revealed = true } } }
    .accessibilityLabel(post.isNSFW ? "Sensitive media" : "Post media")
  }
}

// MARK: - Link chip

struct AuroraLinkChip: View {
  let domain: String
  @Environment(\.auroraTheme) private var theme
  var body: some View {
    Label(domain, systemImage: "safari.fill")
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(theme.chipFill, in: .capsule)
      .foregroundStyle(.secondary)
  }
}

// MARK: - Community header (feed)

struct AuroraCommunityHeader: View {
  let sub: MockSubreddit
  @Environment(\.auroraTheme) private var theme
  @State private var joined = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        AuroraSubIcon(sub: sub, size: 44)
        VStack(alignment: .leading, spacing: 2) {
          Text(sub.displayName).font(.title3.weight(.bold))
          Text("\(MockFormatting.compactNumber(sub.members)) members")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          withAnimation(.snappy) { joined.toggle() }
        } label: {
          Text(joined ? "Joined" : "Join")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(joined ? theme.accent : (theme.isDark ? .black : .white))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(joined ? theme.chipFill : theme.accent, in: .capsule)
        }
        .buttonStyle(.plain)
      }
      Text(sub.about)
        .font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .background(theme.cardFill, in: RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).stroke(theme.hairline, lineWidth: 0.7)
    )
  }
}

// MARK: - Feed card

struct AuroraCard: View {
  let post: MockPost
  var isSelected: Bool = false
  @Environment(\.auroraTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(spacing: 8) {
        AuroraSubIcon(sub: post.subreddit, size: 24)
        Text(post.subreddit.displayName).font(.caption.weight(.semibold))
        Text("· \(MockFormatting.relativeTime(post.createdOffset))")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        if post.isPinned {
          Image(systemName: "pin.fill").font(.caption2).foregroundStyle(theme.accent)
        }
      }

      Text(post.title)
        .font(.headline)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)

      if let body = post.body, post.media == nil {
        Text(body).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
      }

      if let media = post.media {
        AuroraMedia(post: post, media: media)
        if let domain = post.linkDomain { AuroraLinkChip(domain: domain) }
      }

      if let flair = post.flair { AuroraFlair(flair: flair) }

      HStack(spacing: 14) {
        AuroraAvatar(seed: post.author.avatarSeed, name: post.author.username, size: 20)
        Text("u/\(post.author.username)").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Label(MockFormatting.compactNumber(post.commentCount), systemImage: "bubble.left.fill")
        Label("\(Int(post.upvoteRatio * 100))%", systemImage: "arrow.up")
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
    }
    .padding(16)
    .background(theme.cardFill, in: RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        .stroke(isSelected ? theme.accent.opacity(0.9) : theme.hairline,
                lineWidth: isSelected ? 1.8 : 0.7)
    )
  }
}
