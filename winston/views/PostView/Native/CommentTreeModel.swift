//
//  CommentTreeModel.swift
//  winston
//
//  iOS 27 native comments rebuild.
//
//  The core architectural change vs. the legacy CommentLink: instead of
//  recursing views inside the List (which made collapse a janky bulk
//  insert/remove of nested rows), we flatten the comment tree into a single
//  array of visible rows. Collapsing animates only the affected row slice, and
//  List keeps identity stable via CommentRow.id. Depth drives a leading
//  thread-line gutter.
//
//  The model OWNS the root comment container. It subscribes to the container's
//  change stream but only reassigns `rows` when the STRUCTURE actually changes
//  (a comment added/removed, a collapse toggled) — content-only changes like a
//  vote keep the same layout signature and never re-render the list. That keeps
//  reply/delete/load-more reflecting live without the legacy "re-render the whole
//  list on every avatar update" cost.
//
//  Collapse state lives here, scoped by post id. It is NOT the global
//  `CollapsedComment` Core Data table the legacy path uses (that one leaked
//  collapse across posts). If the user has saved state for this post, that wins;
//  otherwise the model seeds once from each comment's API `collapsed` flag
//  (crowd-control / collapsed-by-mods) and the AutoModerator preference.
//

import SwiftUI
import Combine
import Defaults

enum CommentRowKind: Equatable {
  case comment
  case more           // "Load N more replies" stub
  case continueThread // the "_" stub → opens the full conversation
}

/// One visible row in the flattened comment list. Identity is the comment id,
/// which is stable across re-fetches and includes the kind suffix for stubs, so
/// the List can animate insert/remove without confusing rows.
struct CommentRow: Identifiable {
  let id: String
  let comment: Comment
  let depth: Int
  let isCollapsed: Bool
  let hiddenReplyCount: Int
  let kind: CommentRowKind
  let isLastChild: Bool
  /// Where a "more" stub lives, so `loadChildren` knows what to splice into.
  let parent: CommentParentElement?
  /// Precomputed at flatten time so rows don't each spin up a live formatter.
  let relativeTime: String

  /// Compares only the fields that affect layout — used to skip needless
  /// rebuilds when a vote/save changes content but not structure.
  func layoutMatches(_ other: CommentRow) -> Bool {
    id == other.id
      && depth == other.depth
      && isCollapsed == other.isCollapsed
      && hiddenReplyCount == other.hiddenReplyCount
      && kind == other.kind
      && isLastChild == other.isLastChild
      && relativeTime == other.relativeTime
  }

  func withCollapseState(_ isCollapsed: Bool, hiddenReplyCount: Int) -> CommentRow {
    CommentRow(
      id: id,
      comment: comment,
      depth: depth,
      isCollapsed: isCollapsed,
      hiddenReplyCount: hiddenReplyCount,
      kind: kind,
      isLastChild: isLastChild,
      parent: parent,
      relativeTime: relativeTime
    )
  }
}

@Observable
@MainActor
final class CommentTreeModel {
  private(set) var rows: [CommentRow] = []

  /// Owned, not observed by any view — keeps the comment objects alive and is
  /// the splice target for root-level "load more".
  @ObservationIgnored let rootArray = ObservableArray<Comment>()
  @ObservationIgnored private var postID: String
  @ObservationIgnored private var collapsed: Set<String> = []
  @ObservationIgnored private var didSeedCollapse = false
  @ObservationIgnored private var treeCancellable: AnyCancellable?
  @ObservationIgnored private let rebuildContext = "commentTreeRebuild-\(UUID().uuidString)"
  @ObservationIgnored private let collapsePersistContext = "commentCollapsePersist-\(UUID().uuidString)"
  @ObservationIgnored private let collapseWarmContext = "commentCollapseWarm-\(UUID().uuidString)"
  @ObservationIgnored private var descendantCountCache: [String: Int] = [:]
  /// Relative-time strings are expensive to produce (RelativeDateTimeFormatter goes through
  /// ICU). Cache per comment id so a flatten — which runs on EVERY collapse/expand — reuses
  /// the string instead of reformatting the whole tree each time (that was a main-thread hang
  /// big enough to trip the watchdog when collapsing/expanding many comments).
  @ObservationIgnored private var relativeTimeCache: [String: String] = [:]

  @ObservationIgnored private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  init(postID: String) {
    self.postID = postID
  }

  /// Install a freshly fetched root comment forest.
  func setRoots(_ comments: [Comment]) {
    comments.forEach { $0.parentWinston = rootArray }
    rootArray.data = comments
    relativeTimeCache.removeAll(keepingCapacity: true)
    descendantCountCache.removeAll(keepingCapacity: true)
    seedInitialCollapseIfNeeded()
    observeTree()
    rebuild(force: true)
    scheduleWarmCollapseMetrics()
  }

  func toggleCollapse(_ id: String) {
    setCollapse(id, collapsed: !collapsed.contains(id))
  }

  private func setCollapse(_ id: String, collapsed target: Bool) {
    guard collapsed.contains(id) != target else { return }
    guard let rowIndex = rows.firstIndex(where: { $0.id == id }), rows[rowIndex].kind == .comment else {
      setCollapseByRecomputingRows(id, collapsed: target)
      return
    }
    let row = rows[rowIndex]
    setCollapsedState(id, target)

    let out = target
      ? rows(collapsing: row, at: rowIndex)
      : rows(expanding: row, at: rowIndex)

    setRowsWithCollapseAnimation(out)
    schedulePersistCollapse()
  }

  private func setCollapseByRecomputingRows(_ id: String, collapsed target: Bool) {
    setCollapsedState(id, target)
    let out = computeRows()
    setRowsWithCollapseAnimation(out)
    schedulePersistCollapse()
  }

  private func setCollapsedState(_ id: String, _ target: Bool) {
    if target {
      collapsed.insert(id)
    } else {
      collapsed.remove(id)
    }
  }

  private func setRowsWithCollapseAnimation(_ rows: [CommentRow]) {
    withAnimation(.snappy(duration: 0.18)) {
      self.rows = rows
    }
  }

  private func rows(collapsing row: CommentRow, at index: Int) -> [CommentRow] {
    var out = rows
    out[index] = row.withCollapseState(true, hiddenReplyCount: descendantCount(for: row.comment))

    let firstDescendantIndex = index + 1
    guard firstDescendantIndex < out.endIndex else { return out }

    let endIndex = out[firstDescendantIndex...].firstIndex { $0.depth <= row.depth } ?? out.endIndex
    if firstDescendantIndex < endIndex {
      out.removeSubrange(firstDescendantIndex..<endIndex)
    }
    return out
  }

  private func rows(expanding row: CommentRow, at index: Int) -> [CommentRow] {
    var out = rows
    out[index] = row.withCollapseState(false, hiddenReplyCount: 0)

    var inserted: [CommentRow] = []
    flatten(row.comment.childrenWinston.data, depth: row.depth + 1, parent: row.comment, into: &inserted)
    if !inserted.isEmpty {
      out.insert(contentsOf: inserted, at: index + 1)
    }
    return out
  }

  /// Recompute the flattened visible rows. With `force == false`, the result is
  /// only published when the layout signature changed (cheap no-op on content
  /// changes such as votes).
  func rebuild(force: Bool = false, invalidateCollapseMetrics: Bool = false) {
    if invalidateCollapseMetrics {
      descendantCountCache.removeAll(keepingCapacity: true)
    }
    let out = computeRows()
    if force || !Self.layoutEqual(out, rows) {
      rows = out
    }
    if invalidateCollapseMetrics {
      scheduleWarmCollapseMetrics()
    }
  }

  private func computeRows() -> [CommentRow] {
    var out: [CommentRow] = []
    out.reserveCapacity(max(rows.count, 8))
    flatten(rootArray.data, depth: 0, parent: nil, into: &out)
    return out
  }

  // MARK: - Tree observation

  /// Rebuild when the forest structurally changes (reply, delete, load-more).
  /// `ObservableArray` forwards its direct children's change notifications, so
  /// this fires for top-level reshapes; nested reshapes call `rebuild()`
  /// directly from their action sites.
  private func observeTree() {
    treeCancellable = rootArray.objectWillChange
      .sink { [weak self] _ in self?.scheduleStructuralRebuild() }
  }

  private func scheduleStructuralRebuild() {
    // Child changes fire roughly one-per-runloop during scroll — each comment's vote /
    // seen / avatar (winstonData) update bubbles up through ObservableArray. Debounce so a
    // burst collapses into ONE flatten after it settles, instead of re-flattening the whole
    // tree on the main thread on every tick. Real structural edits (reply / delete /
    // load-more) call rebuild() directly, so this path is only a backstop and the small
    // delay is invisible.
    DispatchQueue.main.debounce(delay: 0.12, context: rebuildContext) { [weak self] in
      self?.rebuild()
    }
  }

  // MARK: - Collapse seeding

  private func seedInitialCollapseIfNeeded() {
    guard !didSeedCollapse else { return }
    didSeedCollapse = true
    if let saved = Defaults[.collapsedCommentsByPost][postID] {
      collapsed = Set(saved)
      return
    }
    let collapseAutoMod = Defaults[.CommentsSectionDefSettings].collapseAutoModerator
    func walk(_ nodes: [Comment]) {
      for node in nodes {
        guard let data = node.data else { continue }
        if data.collapsed == true {
          collapsed.insert(node.id)
        } else if collapseAutoMod, (data.depth ?? 0) == 0, data.author == "AutoModerator" {
          collapsed.insert(node.id)
        }
        walk(node.childrenWinston.data)
      }
    }
    walk(rootArray.data)
  }

  private func schedulePersistCollapse() {
    let snapshot = collapsed
    let postIDSnapshot = postID
    DispatchQueue.main.debounce(delay: 0.25, context: collapsePersistContext) {
      Task { @MainActor in
        Self.persistCollapse(snapshot, postID: postIDSnapshot)
      }
    }
  }

  private static func persistCollapse(_ collapsed: Set<String>, postID: String) {
    var saved = Defaults[.collapsedCommentsByPost]
    saved[postID] = collapsed.sorted()
    Defaults[.collapsedCommentsByPost] = saved
  }

  private func scheduleWarmCollapseMetrics() {
    DispatchQueue.main.debounce(delay: 0.05, context: collapseWarmContext) { [weak self] in
      self?.warmCollapseMetrics()
    }
  }

  private func warmCollapseMetrics() {
    for node in rootArray.data where node.kind != "more" {
      _ = descendantCount(for: node)
    }
  }

  // MARK: - Flatten

  private func flatten(_ nodes: [Comment], depth: Int, parent: Comment?, into out: inout [CommentRow]) {
    let count = nodes.count
    for (i, node) in nodes.enumerated() {
      guard let data = node.data else { continue }
      let isMore = node.kind == "more"
      // A "more" stub with count 0 is a deep "continue thread" continuation
      // (cursor pagination loops on these), so route it to the deep-link path.
      let kind: CommentRowKind = !isMore
        ? .comment
        : ((node.id == "_" || (data.count ?? 0) == 0) ? .continueThread : .more)
      let parentElement: CommentParentElement? = parent.map { .comment($0) } ?? .post(rootArray)
      let isColl = !isMore && collapsed.contains(node.id)
      let children = node.childrenWinston.data
      out.append(
        CommentRow(
          id: node.id,
          comment: node,
          depth: depth,
          isCollapsed: isColl,
          hiddenReplyCount: isColl ? descendantCount(children) : 0,
          kind: kind,
          isLastChild: i == count - 1,
          parent: parentElement,
          relativeTime: kind == .comment ? cachedRelative(node.id, data.created) : ""
        )
      )
      if !isColl && !children.isEmpty {
        flatten(children, depth: depth + 1, parent: node, into: &out)
      }
    }
  }

  private func descendantCount(_ nodes: [Comment]) -> Int {
    var total = 0
    for node in nodes where node.kind != "more" {
      total += 1 + descendantCount(for: node)
    }
    return total
  }

  private func descendantCount(for node: Comment) -> Int {
    if let cached = descendantCountCache[node.id] { return cached }

    var total = 0
    for child in node.childrenWinston.data where child.kind != "more" {
      total += 1 + descendantCount(for: child)
    }
    descendantCountCache[node.id] = total
    return total
  }

  /// Cached relative-time lookup. Computed once per comment id (the value drifts only by
  /// minutes over a viewing session, so reusing it is fine) — keeps the expensive formatter
  /// off the per-collapse rebuild path.
  private func cachedRelative(_ id: String, _ created: Double?) -> String {
    if let cached = relativeTimeCache[id] { return cached }
    let value = relativeString(created)
    relativeTimeCache[id] = value
    return value
  }

  private func relativeString(_ created: Double?) -> String {
    guard let created, created > 0 else { return "" }
    return Self.relativeFormatter.localizedString(for: Date(timeIntervalSince1970: created), relativeTo: Date())
  }

  private static func layoutEqual(_ lhs: [CommentRow], _ rhs: [CommentRow]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for i in lhs.indices where !lhs[i].layoutMatches(rhs[i]) { return false }
    return true
  }
}
