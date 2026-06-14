//
//  DeckPostDetail.swift
//  winston
//
//  Design Lab · Deck — the expanded post.
//  Compact: comments ride in a draggable bottom sheet (peek → medium → full) with
//  background interaction, so you read the post while the conversation hovers.
//  Wide: comments flow inline beneath the post (the sheet would cover both panes).
//

import SwiftUI

struct DeckPostDetail: View {
  let post: MockPost
  var useSheet: Bool = true
  var onBack: (() -> Void)? = nil

  @State private var showComments = false
  @State private var collapsed: Set<String> = []

  private var rows: [(comment: MockComment, depth: Int, isCollapsed: Bool)] {
    MockComment.visibleRows(MockData.comments(for: post), collapsed: collapsed)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if let media = post.media {
          DeckMedia(post: post, media: media, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }

        header

        if let body = post.body {
          Text(body)
            .font(.body)
            .foregroundStyle(.white.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
        }

        actionRow

        if !useSheet {
          commentsHeader
          commentList
        }
      }
      .padding(20)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
      .padding(.bottom, useSheet ? 150 : 24)
    }
    .background(DeckPalette.canvas)
    .overlay(alignment: .topLeading) {
      if let onBack {
        Button(action: onBack) {
          Image(systemName: "chevron.left")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .padding(.leading, 16).padding(.top, 8)
      }
    }
    .toolbar(.hidden, for: .navigationBar)
    .sheet(isPresented: sheetBinding) {
      DeckCommentsSheet(post: post, rows: rows, onToggle: toggle)
        .presentationDetents([.height(120), .medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .presentationCornerRadius(28)
        .interactiveDismissDisabled()
    }
    .onAppear {
      guard useSheet else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showComments = true }
    }
  }

  private var sheetBinding: Binding<Bool> {
    Binding(get: { useSheet && showComments }, set: { showComments = $0 })
  }

  private func toggle(_ id: String) {
    withAnimation(.snappy) {
      if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        DeckSubChip(sub: post.subreddit)
        Spacer()
        Text("u/\(post.author.username) · \(MockFormatting.relativeTime(post.createdOffset))")
          .font(.caption).foregroundStyle(.white.opacity(0.6))
      }
      Text(post.title)
        .font(.system(size: 26, weight: .heavy, design: .rounded))
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
      if let flair = post.flair { DeckTag(text: flair.text, color: flair.tint.color) }
    }
  }

  private var actionRow: some View {
    HStack(spacing: 12) {
      DeckVotePill(score: post.score)
      Button { withAnimation(.snappy) { showComments = true } } label: {
        Label(MockFormatting.compactNumber(post.commentCount), systemImage: "bubble.right.fill")
          .font(.subheadline.weight(.bold)).foregroundStyle(.white)
          .padding(.horizontal, 16).padding(.vertical, 11)
          .glassEffect(.regular.interactive(), in: .capsule)
      }
      .buttonStyle(.plain)
      Spacer()
      Image(systemName: "square.and.arrow.up")
        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
        .padding(13)
        .glassEffect(.regular.interactive(), in: .circle)
    }
  }

  private var commentsHeader: some View {
    HStack {
      Text("Comments").font(.title3.weight(.bold)).foregroundStyle(.white)
      Text(MockFormatting.compactNumber(post.commentCount)).foregroundStyle(.white.opacity(0.6))
      Spacer()
    }
    .padding(.top, 6)
  }

  private var commentList: some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(rows, id: \.comment.id) { row in
        DeckCommentRow(comment: row.comment, depth: row.depth, isCollapsed: row.isCollapsed)
          .contentShape(Rectangle())
          .onTapGesture { toggle(row.comment.id) }
      }
    }
  }
}

// MARK: - Comments sheet

struct DeckCommentsSheet: View {
  let post: MockPost
  let rows: [(comment: MockComment, depth: Int, isCollapsed: Bool)]
  let onToggle: (String) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 8) {
          Text("Comments").font(.title3.weight(.bold))
          Text(MockFormatting.compactNumber(post.commentCount)).foregroundStyle(.secondary)
          Spacer()
          Image(systemName: "arrow.up.arrow.down").font(.caption.weight(.bold)).foregroundStyle(DeckPalette.accent)
        }
        .padding(.bottom, 8)

        ForEach(rows, id: \.comment.id) { row in
          DeckCommentRow(comment: row.comment, depth: row.depth, isCollapsed: row.isCollapsed)
            .contentShape(Rectangle())
            .onTapGesture { onToggle(row.comment.id) }
        }
      }
      .padding(20)
    }
    .scrollContentBackground(.hidden)
    .preferredColorScheme(.dark)
  }
}
