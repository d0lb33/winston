//
//  PressComponents.swift
//  winston
//
//  Design Lab · Press — editorial magazine building blocks.
//  Aesthetic: ink on paper, serif display type, hairline rules, one vermillion accent.
//  Glass is reserved strictly for the navigation chrome (the rail / bottom pill).
//

import SwiftUI

// MARK: - Palette

enum PressPalette {
  static let paper  = Color(red: 0.96, green: 0.95, blue: 0.91)
  static let ink    = Color(red: 0.12, green: 0.11, blue: 0.10)
  static let accent = Color(red: 0.80, green: 0.23, blue: 0.16)   // vermillion
  static let rule   = Color(red: 0.12, green: 0.11, blue: 0.10).opacity(0.18)
  static let faint  = Color(red: 0.12, green: 0.11, blue: 0.10).opacity(0.55)
}

// MARK: - Kicker (subreddit + flair, small caps)

struct PressKicker: View {
  let post: MockPost
  var body: some View {
    HStack(spacing: 8) {
      Text(post.subreddit.displayName.uppercased())
        .font(.caption2.weight(.bold)).tracking(1.6)
        .foregroundStyle(PressPalette.accent)
      if let flair = post.flair {
        Text("— " + flair.text.uppercased())
          .font(.caption2.weight(.semibold)).tracking(1.2)
          .foregroundStyle(PressPalette.faint)
      }
      if post.isPinned {
        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(PressPalette.accent)
      }
    }
  }
}

// MARK: - Byline

struct PressByline: View {
  let post: MockPost
  var body: some View {
    Text("By \(post.author.username)   ·   \(MockFormatting.relativeTime(post.createdOffset))   ·   \(MockFormatting.compactNumber(post.commentCount)) comments")
      .font(.caption).foregroundStyle(PressPalette.faint)
  }
}

// MARK: - Subreddit monogram (rail / pill)

struct PressSubMonogram: View {
  let sub: MockSubreddit
  let selected: Bool
  var size: CGFloat = 40
  var body: some View {
    Text(String(sub.name.prefix(1)).uppercased())
      .font(.system(size: size * 0.42, weight: .bold, design: .serif))
      .frame(width: size, height: size)
      .background(selected ? PressPalette.accent : PressPalette.ink.opacity(0.06), in: Circle())
      .foregroundStyle(selected ? .white : PressPalette.ink)
  }
}

struct PressHomeButton: View {
  let selected: Bool
  var size: CGFloat = 40
  var body: some View {
    Image(systemName: "newspaper.fill")
      .font(.system(size: size * 0.38, weight: .semibold))
      .frame(width: size, height: size)
      .background(selected ? PressPalette.accent : PressPalette.ink.opacity(0.06), in: Circle())
      .foregroundStyle(selected ? .white : PressPalette.ink)
  }
}

// MARK: - Media (editorial band)

struct PressMedia: View {
  let post: MockPost
  let media: MockMediaSeed
  var height: CGFloat
  @State private var revealed = false

  private var blurred: Bool { (post.isNSFW || post.isSpoiler) && !revealed }

  var body: some View {
    SeededRemoteImage(
      seed: media.seed,
      pixelWidth: 1200,
      pixelHeight: Int(1200 / max(media.aspect, 0.4)),
      blurred: blurred
    )
    .frame(maxWidth: .infinity)
    .frame(height: height)
    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    .overlay(alignment: .bottomTrailing) {
      if media.count > 1 {
        Text("\(media.count) PHOTOS")
          .font(.caption2.weight(.bold)).tracking(1)
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(PressPalette.ink.opacity(0.8), in: .rect(cornerRadius: 2))
          .foregroundStyle(PressPalette.paper)
          .padding(8)
      }
    }
    .overlay {
      if blurred {
        VStack(spacing: 4) {
          Image(systemName: "eye.slash").font(.title3)
          Text(post.isSpoiler ? "SPOILER" : "SENSITIVE").font(.caption.weight(.bold)).tracking(1.5)
          Text("Tap to reveal").font(.caption2)
        }
        .foregroundStyle(PressPalette.paper)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PressPalette.ink.opacity(0.55))
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { if blurred { withAnimation(.easeOut) { revealed = true } } }
  }
}

// MARK: - Leading rail (wide)

struct PressRail: View {
  @Binding var selectedSubID: String?

  var body: some View {
    VStack(spacing: 16) {
      Text("P")
        .font(.system(size: 26, weight: .black, design: .serif))
        .foregroundStyle(PressPalette.accent)
        .padding(.bottom, 2)

      Button { withAnimation(.snappy) { selectedSubID = nil } } label: {
        PressHomeButton(selected: selectedSubID == nil)
      }
      .buttonStyle(.plain)

      Rectangle().fill(PressPalette.rule).frame(width: 26, height: 1)

      ForEach(MockData.subreddits) { sub in
        Button { withAnimation(.snappy) { selectedSubID = sub.id } } label: {
          PressSubMonogram(sub: sub, selected: selectedSubID == sub.id)
        }
        .buttonStyle(.plain)
      }
      Spacer()
    }
    .frame(width: 78)
    .padding(.vertical, 20)
    .background(PressPalette.paper)
  }
}

// MARK: - Bottom pill (narrow) — the one place glass appears in Press

struct PressBottomBar: View {
  @Binding var selectedSubID: String?

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 12) {
        Button { withAnimation(.snappy) { selectedSubID = nil } } label: {
          PressHomeButton(selected: selectedSubID == nil, size: 38)
        }
        .buttonStyle(.plain)
        ForEach(MockData.subreddits) { sub in
          Button { withAnimation(.snappy) { selectedSubID = sub.id } } label: {
            PressSubMonogram(sub: sub, selected: selectedSubID == sub.id, size: 38)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
    }
    .clipShape(.capsule)
    .glassEffect(.regular.interactive(), in: .capsule)
  }
}
