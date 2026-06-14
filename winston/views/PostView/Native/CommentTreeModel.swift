//
//  CommentTreeModel.swift
//  winston
//
//  iOS 27 native comments rebuild.
//
//  The core architectural change vs. the legacy CommentLink: instead of
//  recursing views inside the List (which made collapse a janky bulk
//  insert/remove of nested rows), we flatten the comment tree into a single
//  array of visible rows. Collapsing is one animated array assignment that the
//  List diffs cleanly via stable ids. Depth drives a leading thread-line gutter.
//
//  The model OWNS the root comment container. It subscribes to the container's
//  change stream but only reassigns `rows` when the STRUCTURE actually changes
//  (a comment added/removed, a collapse toggled) — content-only changes like a
//  vote keep the same layout signature and never re-render the list. That keeps
//  reply/delete/load-more reflecting live without the legacy "re-render the whole
//  list on every avatar update" cost.
//
//  Collapse state lives here, in memory, scoped to this post-view instance —
//  it is NOT the global `CollapsedComment` Core Data table the legacy path uses
//  (that one leaked collapse across posts and sessions). It is seeded once from
//  each comment's API `collapsed` flag (crowd-control / collapsed-by-mods) and
//  the AutoModerator preference.
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
}

@Observable
final class CommentTreeModel {
  private(set) var rows: [CommentRow] = []

  /// Owned, not observed by any view — keeps the comment objects alive and is
  /// the splice target for root-level "load more".
  @ObservationIgnored let rootArray = ObservableArray<Comment>()
  @ObservationIgnored private var collapsed: Set<String> = []
  @ObservationIgnored private var didSeedCollapse = false
  @ObservationIgnored private var treeCancellable: AnyCancellable?
  @ObservationIgnored private var rebuildScheduled = false

  @ObservationIgnored private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  /// Install a freshly fetched root comment forest.
  func setRoots(_ comments: [Comment]) {
    comments.forEach { $0.parentWinston = rootArray }
    rootArray.data = comments
    seedInitialCollapseIfNeeded()
    observeTree()
    rebuild(force: true)
  }

  func isCollapsed(_ id: String) -> Bool { collapsed.contains(id) }

  func toggleCollapse(_ id: String) {
    if collapsed.contains(id) {
      collapsed.remove(id)
    } else {
      collapsed.insert(id)
    }
    rebuild(force: true)
  }

  /// Recompute the flattened visible rows. With `force == false`, the result is
  /// only published when the layout signature changed (cheap no-op on content
  /// changes such as votes).
  func rebuild(force: Bool = false) {
    var out: [CommentRow] = []
    out.reserveCapacity(max(rows.count, 8))
    flatten(rootArray.data, depth: 0, parent: nil, into: &out)
    if force || !Self.layoutEqual(out, rows) {
      rows = out
    }
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
    guard !rebuildScheduled else { return }
    rebuildScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.rebuildScheduled = false
      self.rebuild()
    }
  }

  // MARK: - Collapse seeding

  private func seedInitialCollapseIfNeeded() {
    guard !didSeedCollapse else { return }
    didSeedCollapse = true
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
          relativeTime: kind == .comment ? relativeString(data.created) : ""
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
      total += 1 + descendantCount(node.childrenWinston.data)
    }
    return total
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
