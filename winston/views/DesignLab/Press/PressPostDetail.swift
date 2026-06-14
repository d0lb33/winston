//
//  PressPostDetail.swift
//  winston
//
//  Design Lab · Press — the article view. The signature resize move: body and comments
//  stay in a single column capped at a comfortable reading measure. Widening the window
//  grows the margins, never the column — the opposite of Aurora's multi-pane spread.
//

import SwiftUI

struct PressPostDetail: View {
  let post: MockPost
  @State private var collapsed: Set<String> = []

  private var rows: [(comment: MockComment, depth: Int, isCollapsed: Bool)] {
    MockComment.visibleRows(MockData.comments(for: post), collapsed: collapsed)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PressKicker(post: post)

        Text(post.title)
          .font(.system(size: 32, weight: .bold, design: .serif))
          .foregroundStyle(PressPalette.ink)
          .lineSpacing(3)
          .fixedSize(horizontal: false, vertical: true)

        PressByline(post: post)

        Rectangle().fill(PressPalette.rule).frame(height: 1)

        if let media = post.media {
          PressMedia(post: post, media: media, height: 340)
          if let domain = post.linkDomain {
            Text(domain.uppercased())
              .font(.caption2.weight(.semibold)).tracking(1.5)
              .foregroundStyle(PressPalette.faint)
          }
        }

        if let body = post.body {
          leadParagraph(body)
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 10) {
          Text("THE CONVERSATION")
            .font(.caption.weight(.bold)).tracking(2)
            .foregroundStyle(PressPalette.ink)
          Rectangle().fill(PressPalette.rule).frame(height: 1)
        }
        .padding(.top, 8)

        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(rows, id: \.comment.id) { row in
            PressCommentRow(comment: row.comment, depth: row.depth, isCollapsed: row.isCollapsed)
              .contentShape(Rectangle())
              .onTapGesture {
                withAnimation(.snappy) {
                  if collapsed.contains(row.comment.id) { collapsed.remove(row.comment.id) }
                  else { collapsed.insert(row.comment.id) }
                }
              }
          }
        }
      }
      .frame(maxWidth: 680)               // the reading measure — capped, not multi-pane
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 28)
      .padding(.vertical, 22)
    }
    .background(PressPalette.paper)
    .navigationTitle(post.subreddit.displayName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(PressPalette.paper, for: .navigationBar)
  }

  /// An ornamented raised initial that leads the body — an editorial touch.
  private func leadParagraph(_ text: String) -> Text {
    guard let first = text.first else { return Text(text) }
    let rest = String(text.dropFirst())
    return Text(String(first))
      .font(.system(size: 46, weight: .black, design: .serif))
      .foregroundColor(PressPalette.accent)
      + Text(rest)
      .font(.system(.body, design: .serif))
      .foregroundColor(PressPalette.ink.opacity(0.9))
  }
}

// MARK: - Comment row

struct PressCommentRow: View {
  let comment: MockComment
  let depth: Int
  let isCollapsed: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      if depth > 0 {
        Rectangle().fill(PressPalette.rule).frame(width: 1).padding(.trailing, 14)
      }
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Text(comment.author.username)
            .font(.system(.subheadline, design: .serif).weight(.semibold))
            .foregroundStyle(PressPalette.ink)
          if comment.isOP {
            Text("AUTHOR").font(.caption2.weight(.bold)).tracking(1)
              .foregroundStyle(PressPalette.accent)
          }
          Text("· \(MockFormatting.relativeTime(comment.createdOffset))")
            .font(.caption).foregroundStyle(PressPalette.faint)
          Spacer(minLength: 6)
          if isCollapsed && comment.descendantCount > 0 {
            Text("+\(comment.descendantCount)")
              .font(.caption2.weight(.bold))
              .foregroundStyle(PressPalette.faint)
          }
          Text("▲ \(MockFormatting.compactNumber(comment.score))")
            .font(.caption).foregroundStyle(PressPalette.faint)
        }
        if !isCollapsed {
          Text(comment.body)
            .font(.system(.subheadline, design: .serif))
            .foregroundStyle(PressPalette.ink.opacity(0.88))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(.leading, CGFloat(depth) * 16)
    .padding(.vertical, 9)
    .overlay(alignment: .bottom) {
      if depth == 0 { Rectangle().fill(PressPalette.rule).frame(height: 1) }
    }
  }
}
