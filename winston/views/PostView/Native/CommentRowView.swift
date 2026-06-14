//
//  CommentRowView.swift
//  winston
//
//  A single flattened comment row, styled to feel like a first-party Apple app:
//  system fonts, Dynamic Type, SF Symbols, depth-tinted thread rails, native
//  swipe actions, tap-to-collapse, and inline media with tap-to-fullscreen.
//  Switches on the row kind (comment / load-more / continue-thread).
//

import SwiftUI
import Defaults
import MarkdownUI

struct CommentRowView: View {
  let row: CommentRow
  @ObservedObject var comment: Comment
  let model: CommentTreeModel
  weak var post: Post?
  let postFullname: String
  let opAuthor: String?
  let swipeActions: SwipeActionsSet

  @State private var swipePresented = false
  @State private var loadingMore = false

  private var indent: CGFloat { CGFloat(row.depth) * ThreadRails.step }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Full-width hairline between top-level threads.
      if row.depth == 0 {
        Divider().opacity(0.5)
      }
      decoratedContent
    }
    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    .listRowSeparator(.hidden)
    .commentSwipeActions(
      comment: comment,
      actionsSet: swipeActions,
      enabled: row.kind == .comment,
      actionsArePresented: $swipePresented
    )
    .contextMenu { if row.kind == .comment { contextMenuContent } }
  }

  @ViewBuilder private var decoratedContent: some View {
    rowContent
      .padding(.leading, indent)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(alignment: .leading) { ThreadRails(depth: row.depth) }
  }

  @ViewBuilder private var rowContent: some View {
    switch row.kind {
    case .comment: commentRow
    case .more: moreRow
    case .continueThread: continueThreadRow
    }
  }

  // MARK: - Comment

  private func toggleCollapse() {
    guard !swipePresented else { return }
    withAnimation(.snappy(duration: 0.28)) { model.toggleCollapse(row.id) }
  }

  @ViewBuilder private var commentRow: some View {
    if let data = comment.data {
      // Collapse is attached per-region (header + body) rather than to the whole
      // row, so the author name's own tap (open profile) and inline media's tap
      // (fullscreen) reliably win — mirrors the legacy CommentLinkContent.
      VStack(alignment: .leading, spacing: row.isCollapsed ? 0 : 6) {
        header(data)
          .contentShape(Rectangle())
          .onTapGesture { toggleCollapse() }
        if !row.isCollapsed, let body = data.body, !body.isEmpty {
          CommentBodyNative(
            markdown: body,
            availableWidth: max(1, .screenW - 32 - indent),
            fontSize: 15,
            lineSpacing: 2,
            postTitle: post?.data?.title ?? data.link_title ?? "",
            badgeKit: data.badgeKit,
            avatarImageRequest: comment.winstonData?.avatarImageRequest,
            cornerRadius: 12,
            maxMediaHeightScreenPercentage: min(Defaults[.PostLinkDefSettings].maxMediaHeightScreenPercentage, 45),
            diagnosticContext: "commentNative:\(data.id)"
          )
          .contentShape(Rectangle())
          .onTapGesture { toggleCollapse() }
        }
      }
      .padding(.vertical, row.isCollapsed ? 8 : 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .contain)
      .accessibilityAction(named: row.isCollapsed ? Text("Expand thread") : Text("Collapse thread")) {
        toggleCollapse()
      }
    }
  }

  private func header(_ data: CommentData) -> some View {
    let isOP = (data.is_submitter ?? false) || (opAuthor != nil && data.author == opAuthor)
    return HStack(spacing: 6) {
      Group {
        if row.isCollapsed {
          // Collapsed: let the header tap handle expand; don't capture the name.
          Text(displayAuthor)
        } else {
          // Expanded: tapping the name opens the profile. As the innermost tap
          // target it wins over the header's collapse tap (legacy pattern).
          Text(displayAuthor)
            .onTapGesture {
              if let author = comment.data?.author, !author.isEmpty, author != "[deleted]" {
                Nav.to(.reddit(.user(User(id: author))))
              }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens profile")
        }
      }
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(isOP ? Color.accentColor : (row.isCollapsed ? .secondary : .primary))
      if isOP {
        Text("OP")
          .font(.caption2.weight(.bold))
          .foregroundStyle(Color.accentColor)
          .padding(.horizontal, 5).padding(.vertical, 1)
          .background(Color.accentColor.opacity(0.15), in: Capsule())
      }
      if let flair = data.author_flair_text, !flair.isEmpty, !row.isCollapsed {
        Text(flair)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .padding(.horizontal, 5).padding(.vertical, 1)
          .background(.quaternary, in: Capsule())
      }
      Spacer(minLength: 6)
      if row.isCollapsed {
        collapsedAccessory(data)
      } else {
        if !row.relativeTime.isEmpty {
          Text(row.relativeTime)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        NativeVoteControl(
          likes: data.likes,
          score: data.ups ?? 0,
          onUp: { _ = await comment.vote(action: .up) },
          onDown: { _ = await comment.vote(action: .down) }
        )
      }
    }
  }

  private func collapsedAccessory(_ data: CommentData) -> some View {
    HStack(spacing: 6) {
      Text(formatBigNumber(data.ups ?? 0))
        .font(.footnote.weight(.medium).monospacedDigit())
        .foregroundStyle(.secondary)
      if row.hiddenReplyCount > 0 {
        HStack(spacing: 2) {
          Image(systemName: "bubble.left.fill")
          Text("\(row.hiddenReplyCount)")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
      }
      Image(systemName: "chevron.right")
        .font(.caption.weight(.bold))
        .foregroundStyle(.tertiary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.hiddenReplyCount > 0 ? "Collapsed, \(row.hiddenReplyCount) hidden replies" : "Collapsed")
  }

  private var displayAuthor: String {
    if let author = comment.data?.author, !author.isEmpty { return author }
    return "[deleted]"
  }

  // MARK: - Load more

  private var moreRow: some View {
    let count = comment.data?.count ?? 0
    return Button {
      guard let parent = row.parent else { return }
      withAnimation(spring) { loadingMore = true }
      Task {
        await comment.loadChildren(parent: parent, postFullname: postFullname, avatarSize: 28, post: post)
        withAnimation(.snappy) { model.rebuild() }
        withAnimation(spring) { loadingMore = false }
      }
    } label: {
      HStack(spacing: 6) {
        if loadingMore {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "plus.circle")
        }
        Text(loadingMore ? "Loading…" : "Show \(count) more repl\(count == 1 ? "y" : "ies")")
      }
      .font(.subheadline.weight(.medium))
      .foregroundStyle(Color.accentColor)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(loadingMore)
  }

  // MARK: - Continue thread

  private var continueThreadRow: some View {
    Button {
      guard let post else { return }
      // Deep-link to the parent comment's context (cursor pagination loops on
      // these "too deep" continuations, so load the parent thread fresh instead).
      if let parentID = comment.data?.parent_id, parentID.hasPrefix("t1_") {
        Nav.to(.reddit(.postHighlighted(post, parentID)))
      } else {
        Nav.to(.reddit(.post(post)))
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "arrow.turn.down.right")
        Text("Continue this thread")
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
      }
      .font(.subheadline.weight(.medium))
      .foregroundStyle(Color.accentColor)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Context menu

  @ViewBuilder private var contextMenuContent: some View {
    ForEach(allCommentSwipeActions) { action in
      if action.enabled(comment) {
        let active = action.active(comment)
        Button {
          Task(priority: .background) { await action.action(comment) }
        } label: {
          Label(active ? "Undo \(action.label.lowercased())" : action.label,
                systemImage: active ? action.icon.active : action.icon.normal)
        }
      }
    }
    if let permalink = comment.data?.permalink, let url = URL(string: "https://reddit.com\(permalink.escape.urlEncoded)") {
      ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
    }
  }
}
