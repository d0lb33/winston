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
  /// Already capped (read once upstream); never decode PostLinkDefSettings per-row.
  let maxMediaHeightPct: CGFloat
  let contentWidth: CGFloat

  @State private var swipePresented = false
  @State private var loadingMore = false
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin

  private var indent: CGFloat { CGFloat(row.depth) * ThreadRails.step }
  private var bodyWidth: CGFloat { max(1, contentWidth - 32 - indent) }

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
    model.toggleCollapse(row.id)
  }

  @ViewBuilder private var commentRow: some View {
    if let data = comment.data {
      let collapsed = row.isCollapsed
      let hasBody = data.body?.isEmpty == false
      // Collapse is attached per-region (header + body) rather than to the whole
      // row, so the author name's own tap (open profile) and inline media's tap
      // (fullscreen) reliably win — mirrors the legacy CommentLinkContent.
      VStack(alignment: .leading, spacing: 0) {
        header(data, isCollapsed: collapsed)
          .padding(.bottom, !collapsed && hasBody ? 6 : 0)
          .contentShape(Rectangle())
          .onTapGesture { toggleCollapse() }
          .diagnosticTapTarget("comment collapse header", color: .orange)
        if !collapsed, hasBody, let body = data.body {
          CommentBodyNative(
            markdown: body,
            availableWidth: bodyWidth,
            fontSize: 15,
            lineSpacing: 2,
            postTitle: post?.data?.title ?? data.link_title ?? "",
            badgeKit: data.badgeKit,
            avatarImageRequest: comment.winstonData?.avatarImageRequest,
            cornerRadius: 12,
            maxMediaHeightScreenPercentage: maxMediaHeightPct,
            diagnosticContext: "commentNative:\(data.id)",
            onTextTap: toggleCollapse
          )
        }
      }
      .padding(.vertical, collapsed ? 8 : 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .diagnosticTapTarget("comment collapse fallback", color: .orange)
      .background {
        // Covers row chrome and spacing without putting a gesture back on CommentBodyNative.
        Rectangle()
          .fill(.clear)
          .contentShape(Rectangle())
          .onTapGesture { toggleCollapse() }
      }
      .accessibilityElement(children: .contain)
      .accessibilityAction(named: collapsed ? Text("Expand thread") : Text("Collapse thread")) {
        toggleCollapse()
      }
    }
  }

  // The header is kept structurally data-INDEPENDENT: the author tap is always attached
  // (gated internally), OP/flair render through a ForEach over chips, and the time is always
  // emitted. The row's opaque type therefore doesn't vary per comment (OP vs not, flair vs
  // not, has-time vs not). Previously each distinct shape was a distinct generic
  // specialization, so the Swift runtime had to instantiate fresh type metadata
  // (swift_getTypeByMangledName) for each as rows scrolled in — the dominant scroll hitch.
  private func header(_ data: CommentData, isCollapsed: Bool) -> some View {
    let isOP = (data.is_submitter ?? false) || (opAuthor != nil && data.author == opAuthor)
    return HStack(spacing: 6) {
      // Avatar + author share a single tap target (open profile / expand-when-collapsed). The avatar
      // always renders — AuroraAvatar falls back to a monogram when the request is nil — so the header
      // stays structurally data-independent (no per-comment generic specialization → no scroll hitch).
      HStack(spacing: 6) {
        AuroraAvatar(name: displayAuthor, avatarRequest: comment.winstonData?.avatarImageRequest, size: 22)
        Text(displayAuthor)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(isOP ? Color.accentColor : (isCollapsed ? Color.secondary : Color.primary))
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .contentShape(Rectangle())
      .onTapGesture {
        // Collapsed: behave like the rest of the header (expand). Expanded: open profile.
        if isCollapsed {
          toggleCollapse()
        } else if let author = comment.data?.author, !author.isEmpty, author != "[deleted]" {
          navigateRedditDestination(.reddit(.user(User(id: author))), model: redditNavigationModel, origin: redditNavigationOrigin)
        }
      }
      .accessibilityAddTraits(.isButton)
      .accessibilityHint(isCollapsed ? "" : "Opens profile")
      .diagnosticTapTarget(isCollapsed ? "comment expand author" : "comment author profile", color: .blue)

      ForEach(headerChips(data, isOP: isOP, isCollapsed: isCollapsed)) { chip in
        chipView(chip)
      }

      Spacer(minLength: 6)

      trailingAccessory(data, isCollapsed: isCollapsed)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }
  }

  private struct HeaderChip: Identifiable {
    let id: String
    let text: String
    let isOP: Bool
  }

  private func headerChips(_ data: CommentData, isOP: Bool, isCollapsed: Bool) -> [HeaderChip] {
    var chips: [HeaderChip] = []
    if isOP { chips.append(HeaderChip(id: "op", text: "OP", isOP: true)) }
    if !isCollapsed, let flair = data.author_flair_text, !flair.isEmpty {
      chips.append(HeaderChip(id: "flair", text: flair, isOP: false))
    }
    return chips
  }

  private func chipView(_ chip: HeaderChip) -> some View {
    Text(chip.text)
      .font(chip.isOP ? .caption2.weight(.bold) : .caption2)
      .foregroundStyle(chip.isOP ? Color.accentColor : Color.secondary)
      .lineLimit(1)
      .padding(.horizontal, 5).padding(.vertical, 1)
      .background(chip.isOP ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(.quaternary), in: Capsule())
  }

  @ViewBuilder private func trailingAccessory(_ data: CommentData, isCollapsed: Bool) -> some View {
    if isCollapsed {
      collapsedAccessory(data)
    } else {
      HStack(spacing: 6) {
        Text(row.relativeTime)
          .font(.footnote)
          .foregroundStyle(.secondary)
        NativeVoteControl(
          likes: data.likes,
          score: data.ups ?? 0,
          scoreHidden: data.score_hidden == true,
          onUp: { _ = await comment.vote(action: .up) },
          onDown: { _ = await comment.vote(action: .down) }
        )
      }
    }
  }

  private func collapsedAccessory(_ data: CommentData) -> some View {
    HStack(spacing: 6) {
      Text(data.score_hidden == true ? "-" : formatBigNumber(data.ups ?? 0))
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
      loadingMore = true
      Task {
        await comment.loadChildren(parent: parent, postFullname: postFullname, avatarSize: 28, post: post)
        model.rebuild(invalidateCollapseMetrics: true)
        loadingMore = false
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
        navigateRedditDestination(.reddit(.postHighlighted(post, parentID)), model: redditNavigationModel, origin: redditNavigationOrigin)
      } else {
        navigateRedditDestination(.reddit(.post(post)), model: redditNavigationModel, origin: redditNavigationOrigin)
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
          Task { await action.action(comment) }
        } label: {
          Label(active ? "Undo \(action.label.lowercased())" : action.label,
                systemImage: active ? action.icon.active : action.icon.normal)
        }
      }
    }
    if let permalink = comment.data?.permalink, let url = URL(string: "https://reddit.com\(permalink.escape.urlEncoded)") {
      ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
    }
    Divider()
    Button {
      let layout = RenderingReportLayoutContext(
        surface: "native-comment-row",
        renderer: "native-comment",
        rowSize: "\(contentWidth)xauto",
        bodySize: "\(bodyWidth)xauto",
        postDimensions: nil,
        forcedPostDimensions: nil,
        collapsed: row.isCollapsed,
        depth: row.depth
      )
      RenderingReportStore.shared.captureCommentIssue(
        comment: comment,
        surface: "native-comment-row",
        treeContext: [
          "treePosition": row.parent == nil ? "top-level" : "nested"
        ],
        layout: layout
      )
    } label: {
      Label("Report Rendering Issue", systemImage: "exclamationmark.bubble")
    }
  }
}
