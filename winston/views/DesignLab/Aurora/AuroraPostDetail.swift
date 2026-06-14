//
//  AuroraPostDetail.swift
//  winston
//
//  Design Lab · Aurora — the trailing (detail) column: post + threaded comments.
//  Glass chrome (vote pill + actions) batched in a GlassEffectContainer; depth-tinted
//  thread rails; real collapse via a set of collapsed comment IDs.
//

import SwiftUI

struct AuroraPostDetail: View {
  let post: MockPost
  @State private var collapsed: Set<String> = []

  private var rows: [(comment: MockComment, depth: Int, isCollapsed: Bool)] {
    MockComment.visibleRows(MockData.comments(for: post), collapsed: collapsed)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header

        if let media = post.media {
          AuroraMedia(post: post, media: media, maxHeight: 460)
          if let domain = post.linkDomain { AuroraLinkChip(domain: domain) }
        }

        if let body = post.body {
          Text(body)
            .font(.body)
            .foregroundStyle(.primary.opacity(0.92))
            .fixedSize(horizontal: false, vertical: true)
        }

        actions

        HStack {
          Text("Comments").font(.title3.weight(.bold))
          Text(MockFormatting.compactNumber(post.commentCount))
            .font(.subheadline).foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.top, 4)

        Divider().overlay(.white.opacity(0.12))

        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(rows, id: \.comment.id) { row in
            AuroraCommentRow(
              comment: row.comment,
              depth: row.depth,
              isCollapsed: row.isCollapsed
            )
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
      .padding(20)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollContentBackground(.hidden)
    .navigationTitle(post.subreddit.displayName)
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom) { composer }
  }

  private var composer: some View {
    HStack(spacing: 10) {
      AuroraAvatar(seed: "you-aurora", name: "Y", size: 28)
      Text("Add a comment…").font(.subheadline).foregroundStyle(.secondary)
      Spacer()
      Image(systemName: "paperplane.fill")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(AuroraPalette.accent)
    }
    .padding(.horizontal, 16).padding(.vertical, 11)
    .glassEffect(.regular.interactive(), in: .capsule)
    .padding(.horizontal, 16).padding(.bottom, 8)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        AuroraSubIcon(sub: post.subreddit, size: 30)
        VStack(alignment: .leading, spacing: 1) {
          Text(post.subreddit.displayName).font(.subheadline.weight(.semibold))
          Text("u/\(post.author.username) · \(MockFormatting.relativeTime(post.createdOffset))")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
      }
      Text(post.title)
        .font(.title2.weight(.bold))
        .fixedSize(horizontal: false, vertical: true)
      if let flair = post.flair { AuroraFlair(flair: flair) }
    }
  }

  private var actions: some View {
    GlassEffectContainer(spacing: 12) {
      HStack(spacing: 12) {
        GlassVotePill(score: post.score)
        Label(MockFormatting.compactNumber(post.commentCount), systemImage: "bubble.left.fill")
          .font(.subheadline.weight(.semibold))
          .padding(.horizontal, 14).padding(.vertical, 9)
          .glassEffect(.regular, in: .capsule)
        Spacer()
        Image(systemName: "square.and.arrow.up")
          .font(.system(size: 15, weight: .semibold))
          .padding(11)
          .glassEffect(.regular.interactive(), in: .circle)
      }
    }
  }
}

// MARK: - Comment row

struct AuroraCommentRow: View {
  let comment: MockComment
  let depth: Int
  let isCollapsed: Bool

  private static let rail: [Color] = [AuroraPalette.accent, .teal, .green, .orange, .pink, .purple]

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      ForEach(0..<depth, id: \.self) { lvl in
        Capsule()
          .fill(Self.rail[lvl % Self.rail.count].opacity(0.55))
          .frame(width: 2.5)
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Text(comment.author.username).font(.subheadline.weight(.semibold))
          if comment.isOP {
            Text("OP").font(.caption2.weight(.bold))
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(AuroraPalette.accent.opacity(0.25), in: .capsule)
              .foregroundStyle(AuroraPalette.accent)
          }
          Text("· \(MockFormatting.relativeTime(comment.createdOffset))")
            .font(.caption).foregroundStyle(.secondary)
          Spacer(minLength: 6)
          if isCollapsed && comment.descendantCount > 0 {
            Text("+\(comment.descendantCount)")
              .font(.caption2.weight(.bold))
              .padding(.horizontal, 7).padding(.vertical, 2)
              .background(.white.opacity(0.12), in: .capsule)
              .foregroundStyle(.secondary)
          }
          Label(MockFormatting.compactNumber(comment.score), systemImage: "arrow.up")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }

        if !isCollapsed {
          Text(comment.body)
            .font(.subheadline)
            .foregroundStyle(.primary.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(.vertical, 9)
    .overlay(alignment: .bottom) {
      if depth == 0 { Divider().overlay(.white.opacity(0.08)) }
    }
  }
}
