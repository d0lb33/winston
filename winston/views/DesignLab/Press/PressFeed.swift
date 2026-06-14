//
//  PressFeed.swift
//  winston
//
//  Design Lab · Press — the front page: a serif cover story over a width-driven
//  masonry of secondary stories. Columns reflow with the window: 1 → 2 → 3.
//

import SwiftUI

struct PressFeed: View {
  let posts: [MockPost]
  let sectionTitle: String
  let onOpen: (MockPost) -> Void

  @State private var width: CGFloat = 0

  private var cover: MockPost? { posts.first }
  private var rest: [MockPost] { Array(posts.dropFirst()) }
  private var columnCount: Int { width > 1080 ? 3 : width > 660 ? 2 : 1 }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        masthead

        if let cover {
          Button { onOpen(cover) } label: { PressCover(post: cover) }
            .buttonStyle(.plain)
        }

        Rectangle().fill(PressPalette.ink).frame(height: 2)

        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 26, alignment: .top), count: columnCount),
          alignment: .leading,
          spacing: 26
        ) {
          ForEach(rest) { post in
            Button { onOpen(post) } label: { PressStory(post: post) }
              .buttonStyle(.plain)
          }
        }
      }
      .padding(.horizontal, 28)
      .padding(.top, 14)
      .padding(.bottom, 40)
      .frame(maxWidth: 1180)
      .frame(maxWidth: .infinity)
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    .background(PressPalette.paper)
  }

  private var masthead: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(sectionTitle)
        .font(.system(size: 44, weight: .black, design: .serif))
        .foregroundStyle(PressPalette.ink)
      HStack {
        Text("VOL. XXVII — TODAY’S EDITION")
          .font(.caption2.weight(.semibold)).tracking(2)
          .foregroundStyle(PressPalette.faint)
        Spacer()
        Text("\(posts.count) STORIES")
          .font(.caption2.weight(.semibold)).tracking(2)
          .foregroundStyle(PressPalette.faint)
      }
    }
  }
}

// MARK: - Cover story

private struct PressCover: View {
  let post: MockPost

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      PressKicker(post: post)

      Text(post.title)
        .font(.system(size: 36, weight: .bold, design: .serif))
        .foregroundStyle(PressPalette.ink)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)

      if let media = post.media {
        PressMedia(post: post, media: media, height: 300)
      }

      if let body = post.body {
        Text(body)
          .font(.system(.body, design: .serif))
          .foregroundStyle(PressPalette.ink.opacity(0.82))
          .lineLimit(media == nil ? 6 : 2)
          .fixedSize(horizontal: false, vertical: true)
      }

      PressByline(post: post)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var media: MockMediaSeed? { post.media }
}

// MARK: - Secondary story (grid cell)

private struct PressStory: View {
  let post: MockPost

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      if let media = post.media {
        PressMedia(post: post, media: media, height: 150)
      }
      PressKicker(post: post)
      Text(post.title)
        .font(.system(size: 20, weight: .semibold, design: .serif))
        .foregroundStyle(PressPalette.ink)
        .fixedSize(horizontal: false, vertical: true)
      if post.media == nil, let body = post.body {
        Text(body)
          .font(.system(.subheadline, design: .serif))
          .foregroundStyle(PressPalette.ink.opacity(0.78))
          .lineLimit(3)
      }
      PressByline(post: post)
      Rectangle().fill(PressPalette.rule).frame(height: 1).padding(.top, 2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
