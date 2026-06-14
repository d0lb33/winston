//
//  DeckComponents.swift
//  winston
//
//  Design Lab · Deck — spatial, gesture-first building blocks.
//  Aesthetic: near-black canvas, one electric-lime accent, bold rounded type, springy
//  motion and depth. Cards you flick through like a deck.
//

import SwiftUI

// MARK: - Palette

enum DeckPalette {
  static let canvas = Color(red: 0.05, green: 0.05, blue: 0.07)
  static let card   = Color(red: 0.10, green: 0.10, blue: 0.13)
  static let accent = Color(red: 0.66, green: 0.95, blue: 0.32)   // electric lime
  static let accentInk = Color.black
}

struct SpringButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .animation(.snappy(duration: 0.25), value: configuration.isPressed)
  }
}

// MARK: - Subreddit chip

struct DeckSubChip: View {
  let sub: MockSubreddit
  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(sub.accent.color).frame(width: 15, height: 15)
      Text(sub.displayName).font(.caption.weight(.bold))
    }
    .padding(.horizontal, 10).padding(.vertical, 6)
    .background(.black.opacity(0.4), in: .capsule)
    .foregroundStyle(.white)
  }
}

struct DeckTag: View {
  let text: String
  var color: Color = DeckPalette.accent
  var body: some View {
    Text(text.uppercased())
      .font(.caption2.weight(.heavy)).tracking(0.8)
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(color, in: .capsule)
      .foregroundStyle(DeckPalette.accentInk)
  }
}

// MARK: - Media

struct DeckMedia: View {
  let post: MockPost
  let media: MockMediaSeed
  /// When non-nil the media is a fixed-height band; when nil it fills its container (card background).
  var height: CGFloat? = nil
  @State private var revealed = false

  private var blurred: Bool { (post.isNSFW || post.isSpoiler) && !revealed }

  var body: some View {
    SeededRemoteImage(
      seed: media.seed,
      pixelWidth: 1100,
      pixelHeight: Int(1100 / max(media.aspect, 0.4)),
      blurred: blurred
    )
    .frame(maxWidth: .infinity)
    .frame(height: height, alignment: .center)
    .frame(maxHeight: height == nil ? .infinity : nil)
    .overlay {
      if blurred {
        VStack(spacing: 4) {
          Image(systemName: "eye.slash.fill").font(.title3)
          Text(post.isSpoiler ? "Spoiler" : "NSFW").font(.subheadline.weight(.bold))
          Text("Tap to reveal").font(.caption2).opacity(0.8)
        }
        .foregroundStyle(.white)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { if blurred { withAnimation(.snappy) { revealed = true } } }
  }
}

// MARK: - Card

struct DeckCard: View {
  let post: MockPost
  var focused: Bool = false
  var namespace: Namespace.ID
  var compact: Bool = false

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      if let media = post.media {
        DeckMedia(post: post, media: media)
      } else {
        LinearGradient(colors: MockMediaPalette.colors(for: post.id),
                       startPoint: .topLeading, endPoint: .bottomTrailing)
      }

      LinearGradient(colors: [.clear, .black.opacity(0.2), .black.opacity(0.88)],
                     startPoint: .center, endPoint: .bottom)

      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          DeckSubChip(sub: post.subreddit)
          if post.isNSFW { DeckTag(text: "NSFW", color: .pink) }
          if let flair = post.flair { DeckTag(text: flair.text, color: flair.tint.color) }
        }
        Text(post.title)
          .font(.system(size: compact ? 18 : 26, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .lineLimit(compact ? 3 : 5)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 16) {
          Label(MockFormatting.compactNumber(post.score), systemImage: "arrow.up")
          Label(MockFormatting.compactNumber(post.commentCount), systemImage: "bubble.right.fill")
          Spacer()
          Text(MockFormatting.relativeTime(post.createdOffset))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white.opacity(0.85))
      }
      .padding(compact ? 16 : 22)
    }
    .background(DeckPalette.card)
    .clipShape(RoundedRectangle(cornerRadius: compact ? 22 : 30, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: compact ? 22 : 30, style: .continuous)
        .stroke(focused ? DeckPalette.accent.opacity(0.5) : .white.opacity(0.08),
                lineWidth: focused ? 1.6 : 1)
    )
    .shadow(color: .black.opacity(0.55), radius: focused ? 26 : 12, x: 0, y: focused ? 16 : 8)
  }
}

// MARK: - Vote pill

struct DeckVotePill: View {
  let score: Int
  @State private var vote = 0
  private var shown: Int { score + vote }

  var body: some View {
    HStack(spacing: 12) {
      button("arrow.up", active: vote == 1) { withAnimation(.snappy) { vote = vote == 1 ? 0 : 1 } }
      Text(MockFormatting.compactNumber(shown))
        .font(.subheadline.weight(.bold)).monospacedDigit()
        .foregroundStyle(vote == 1 ? DeckPalette.accent : .white)
        .contentTransition(.numericText())
      button("arrow.down", active: vote == -1) { withAnimation(.snappy) { vote = vote == -1 ? 0 : -1 } }
    }
    .padding(.horizontal, 16).padding(.vertical, 11)
    .glassEffect(.regular.interactive(), in: .capsule)
  }

  private func button(_ symbol: String, active: Bool, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 15, weight: .bold))
        .foregroundStyle(active ? DeckPalette.accent : .white.opacity(0.7))
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Comment row

struct DeckCommentRow: View {
  let comment: MockComment
  let depth: Int
  let isCollapsed: Bool

  private static let rail: [Color] = [DeckPalette.accent, .cyan, .pink, .orange, .purple, .mint]

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      ForEach(0..<depth, id: \.self) { lvl in
        Capsule().fill(Self.rail[lvl % Self.rail.count].opacity(0.6)).frame(width: 3)
      }
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Text(comment.author.username).font(.subheadline.weight(.bold)).foregroundStyle(.white)
          if comment.isOP {
            Text("OP").font(.caption2.weight(.heavy))
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(DeckPalette.accent, in: .capsule)
              .foregroundStyle(DeckPalette.accentInk)
          }
          Text("· \(MockFormatting.relativeTime(comment.createdOffset))")
            .font(.caption).foregroundStyle(.white.opacity(0.5))
          Spacer(minLength: 6)
          if isCollapsed && comment.descendantCount > 0 {
            Text("+\(comment.descendantCount)")
              .font(.caption2.weight(.bold))
              .padding(.horizontal, 7).padding(.vertical, 2)
              .background(.white.opacity(0.12), in: .capsule)
              .foregroundStyle(.white.opacity(0.7))
          }
          Label(MockFormatting.compactNumber(comment.score), systemImage: "arrow.up")
            .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.5))
        }
        if !isCollapsed {
          Text(comment.body)
            .font(.subheadline).foregroundStyle(.white.opacity(0.86))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(.vertical, 9)
    .overlay(alignment: .bottom) {
      if depth == 0 { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }
  }
}
