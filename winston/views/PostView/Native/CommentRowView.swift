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
  /// Bare comment id (no `t1_` prefix) to tint after a deep-link jump; nil = no highlight.
  var highlightedID: String? = nil
  /// Already capped (read once upstream); never decode PostLinkDefSettings per-row.
  let maxMediaHeightPct: CGFloat
  let contentWidth: CGFloat
  var onToggleCollapse: ((String) -> Void)? = nil

  @State private var swipePresented = false
  @State private var loadingMore = false
  @State private var showingSelectText = false
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin
  @Environment(\.auroraTheme) private var theme

  private var indent: CGFloat { CGFloat(row.depth) * ThreadRails.step }
  private var bodyWidth: CGFloat { max(1, contentWidth - 32 - indent) }
  private var tapCoordinateSpace: String { "comment-row-tap-\(row.id)" }
  private var authorTapMinX: CGFloat { 16 + indent }
  private var authorTapMaxX: CGFloat { authorTapMinX + AuthorTapTarget.avatarSize + AuthorTapTarget.spacing + displayAuthorTapWidth }
  private var authorTapMidY: CGFloat { (row.isCollapsed ? 8 : 10) + AuthorTapTarget.avatarSize / 2 }
  private var authorTapMinY: CGFloat { authorTapMidY - AuthorTapTarget.height / 2 }
  private var authorTapMaxY: CGFloat { authorTapMidY + AuthorTapTarget.height / 2 }

  var body: some View {
    let _ = ScrollPerfDiagnostics.bump(row.kind.bodyDiagnosticsCategory)
    VStack(alignment: .leading, spacing: 0) {
      // Full-width hairline between top-level threads.
      if row.depth == 0 {
        Divider().opacity(0.5)
      }
      decoratedContent
    }
    // Zero the row insets so the row content (and its full-width collapse layer) reaches the
    // screen edges; the former 16pt horizontal insets are folded into `decoratedContent`.
    .listRowInsets(EdgeInsets())
    .listRowSeparator(.hidden)
    .commentSwipeActions(
      comment: comment,
      actionsSet: swipeActions,
      enabled: row.kind == .comment,
      actionsArePresented: $swipePresented
    )
    .contextMenu { if row.kind == .comment { contextMenuContent } }
    .selectableTextSheet(isPresented: $showingSelectText, markdown: comment.data?.body ?? "")
  }

  @ViewBuilder private var decoratedContent: some View {
    // Indent + thread rails first (rails stay aligned to the indent), THEN the 16pt horizontal
    // inset (was `listRowInsets`). For comment rows the whole row is one collapse tap target
    // (`contentShape` + `SpatialTapGesture`): a tap anywhere in the gutter, padding, empty
    // header space, or plain body text collapses/expands. Real controls (votes, media, links,
    // spoiler) are foreground children and win their own taps. The author/profile target is a
    // small fixed band over the visible avatar/name; space below it remains collapse.
    let base = rowContent
      .padding(.leading, indent)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(alignment: .leading) { ThreadRails(depth: row.depth) }
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
      // Deep-link highlight. The tint shape is ALWAYS in the tree (opacity-driven), so the
      // row's opaque type never varies per comment — preserves the no-scroll-hitch property.
      .background(highlightTint)
    if row.kind == .comment {
      base
        .coordinateSpace(name: tapCoordinateSpace)
        .contentShape(Rectangle())
        .gesture(
          SpatialTapGesture(coordinateSpace: .named(tapCoordinateSpace))
            .onEnded { handleRowTap(at: $0.location) }
        )
        .diagnosticTapTarget("comment collapse (row)", color: .orange)
    } else {
      base
    }
  }

  @ViewBuilder private var rowContent: some View {
    switch row.kind {
    case .comment: commentRow
    case .more: moreRow
    case .continueThread: continueThreadRow
    }
  }

  // MARK: - Deep-link highlight

  private var isHighlighted: Bool { row.kind == .comment && highlightedID == row.id }

  /// Tint card drawn behind a deep-linked comment. Kept structurally constant (opacity
  /// flips with `isHighlighted`) so it animates in/out with the parent's transaction.
  private var highlightTint: some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
      .fill(theme.accent.opacity(isHighlighted ? 0.15 : 0))
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(theme.accent.opacity(isHighlighted ? 0.4 : 0), lineWidth: 1)
      )
      .padding(.horizontal, 8)
      .padding(.vertical, 1)
      .allowsHitTesting(false)
  }

  // MARK: - Comment

  private func toggleCollapse() {
    guard !swipePresented else { return }
    if let onToggleCollapse {
      onToggleCollapse(row.id)
    } else {
      model.toggleCollapse(row.id)
    }
  }

  private func handleRowTap(at location: CGPoint) {
    guard !swipePresented else { return }
    if profileAuthor != nil && isAuthorProfileTap(location) {
      openAuthorProfile()
    } else {
      toggleCollapse()
    }
  }

  private func isAuthorProfileTap(_ location: CGPoint) -> Bool {
    location.x >= authorTapMinX
      && location.x <= authorTapMaxX
      && location.y >= authorTapMinY
      && location.y <= authorTapMaxY
  }

  @ViewBuilder private var commentRow: some View {
    let _ = ScrollPerfDiagnostics.bump("commentRow.commentBody")
    if let data = comment.data {
      let collapsed = row.isCollapsed
      let hasBody = data.body?.isEmpty == false
      // Collapse is handled by ONE full-width clear layer in `decoratedContent`. The visible
      // avatar/name, inline media, links, votes, and spoiler button are foreground controls
      // that win their own taps; everything else falls through to collapse. No gesture is
      // attached to the body/text view.
      VStack(alignment: .leading, spacing: 0) {
        header(data, isCollapsed: collapsed)
          .padding(.bottom, !collapsed && hasBody ? 6 : 0)
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
            onTextTap: nil
          )
        }
      }
      .padding(.vertical, collapsed ? 8 : 10)
      .frame(maxWidth: .infinity, alignment: .leading)
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
    ScrollPerfDiagnostics.bump("commentRow.header")
    let isOP = (data.is_submitter ?? false) || (opAuthor != nil && data.author == opAuthor)
    return HStack(spacing: 6) {
      // Avatar and author are intentionally tiny profile targets. Header whitespace around
      // them falls through to the row-wide collapse target.
      HStack(spacing: AuthorTapTarget.spacing) {
        AuroraAvatar(name: displayAuthor, avatarRequest: comment.winstonData?.avatarImageRequest, size: AuthorTapTarget.avatarSize)
          .diagnosticTapTarget("comment author avatar profile", color: .blue)
        Text(displayAuthor)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(isOP ? Color.accentColor : (isCollapsed ? Color.secondary : Color.primary))
          .lineLimit(1)
          .truncationMode(.tail)
          .diagnosticTapTarget("comment author name profile", color: .blue)
      }

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
    ScrollPerfDiagnostics.bump("commentRow.headerChips")
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

  private var profileAuthor: String? {
    guard let author = comment.data?.author, !author.isEmpty, author != "[deleted]" else { return nil }
    return author
  }

  private var displayAuthorTapWidth: CGFloat {
    min(CGFloat(displayAuthor.count) * AuthorTapTarget.characterWidth, max(1, contentWidth - authorTapMinX - AuthorTapTarget.trailingAllowance))
  }

  private func openAuthorProfile() {
    guard let author = profileAuthor else { return }
    navigateRedditDestination(.reddit(.user(User(id: author))), model: redditNavigationModel, origin: redditNavigationOrigin)
  }

  private enum AuthorTapTarget {
    static let avatarSize: CGFloat = 22
    static let spacing: CGFloat = 6
    static let height: CGFloat = 16
    static let characterWidth: CGFloat = 8.5
    static let trailingAllowance: CGFloat = 64
  }

  // MARK: - Load more

  private var moreRow: some View {
    let _ = ScrollPerfDiagnostics.bump("commentRow.moreBody")
    let count = comment.data?.count ?? 0
    return Button {
      guard let parent = row.parent else { return }
      loadingMore = true
      Task {
        let start = ScrollPerfDiagnostics.now()
        await comment.loadChildren(parent: parent, postFullname: postFullname, avatarSize: 28, post: post)
        model.rebuild(invalidateCollapseMetrics: true)
        ScrollPerfDiagnostics.recordDuration(
          category: "commentRow.loadMore",
          message: "Comment load-more was slow",
          elapsedNanos: ScrollPerfDiagnostics.now() - start,
          thresholdMs: 40,
          metadata: ["row": row.id, "post": postFullname, "count": "\(count)"]
        )
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
    let _ = ScrollPerfDiagnostics.bump("commentRow.continueBody")
    return Button {
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
    if comment.data?.body?.isEmpty == false {
      Button {
        showingSelectText = true
      } label: {
        Label("Select Text", systemImage: "text.cursor")
      }
    }
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

private extension CommentRowKind {
  var bodyDiagnosticsCategory: String {
    switch self {
    case .comment: return "commentRow.body.comment"
    case .more: return "commentRow.body.more"
    case .continueThread: return "commentRow.body.continue"
    }
  }
}
