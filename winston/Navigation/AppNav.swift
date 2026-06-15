//
//  AppNav.swift
//  winston
//
//  Native, selection-driven navigation model. Replaces the dual-source-of-truth
//  system (`Router.fullPath` + `RedditSplitNavigationModel` choreography) with thin
//  per-surface state that lets `NavigationSplitView` own all compact↔regular column
//  collapse/expand — so navigation survives foldables, Stage Manager, Split View,
//  rotation, and arbitrary window resizing.
//
//  Introduced incrementally (navigation rebuild). The legacy `Nav`/`Router` types still
//  exist and remain wired until each surface is migrated. See
//  docs/navigation-rebuild-plan.md.
//
//  Vocabulary note: these models keep using `Router.NavDest` as the routing vocabulary
//  so the existing `Nav.to(...)` / link-tap call sites keep working through the
//  migration. `NavDest` is lifted to a top-level type only when `Router` is deleted.
//

import SwiftUI

/// Top-level container for the app's navigation state. One per app; mirrors the
/// existing `Nav.shared` singleton while the two coexist during migration.
@Observable
@MainActor
final class AppNav {
  static let shared = AppNav()

  /// The selected tab. Bound directly to the native `TabView(selection:)`.
  var selectedTab: Tab = .posts

  /// Per-surface navigation state. Each is the single source of truth for its tab.
  let posts = PostsNav()
  let me = ColumnNav()
  let search = ColumnNav()
  let inbox = StackNav()
  let settings = SettingsNav()

  enum Tab: String, CaseIterable, Hashable, Codable {
    case posts, inbox, me, search, settings
  }

  private init() {}

  /// Reset the account-scoped surfaces when the signed-in account changes. Settings is
  /// intentionally left untouched (matches the legacy `Nav.resetAccountScopedStacks`).
  func resetAccountScopedSurfaces() {
    posts.reset()
    me.reset()
    search.reset()
    inbox.reset()
    if selectedTab != .settings { selectedTab = .posts }
  }
}

// MARK: - Posts (three-column: communities sidebar | feed | post+comments)

/// Single source of truth for the Posts split. Unlike the legacy
/// `RedditSplitNavigationModel`, the detail stack is owned *here* (`detailPath`) instead
/// of an external `Router.fullPath`, so there is nothing to reconcile across size-class
/// transitions — `NavigationSplitView` re-renders straight from this state on resize.
///
/// `preferredColumn` is *derived* from the current selection (post open → detail; else
/// content). There is no `record*`/`absorb*` reconciliation and no Router coupling —
/// those were the source of the resize/fold bugs.
@Observable
@MainActor
final class PostsNav: RedditNavigator {
  /// Sidebar selection: a community uuid, a feed token ("home"/"popular"/"saved"), or a
  /// saved-list route id. Stable string token — never derived from `CachedSub` identity,
  /// which churns when the `@FetchRequest` re-syncs (see AuroraRoot.swift).
  var community: String? = "popular"

  /// Feed-list selection — the post highlighted in the content column. Used for the
  /// iPad row highlight and, when it maps to a feed post, the detail root.
  var selectedPostID: String?

  /// Explicit post for the detail root when it did not come from the feed list (a link
  /// tap, a deep link, a saved item).
  var detailPost: Post?
  var detailHighlightID: String?

  /// Pushes that stay in the content column (a sub/user opened from a card while the
  /// feed remains visible).
  var contentPath: [Router.NavDest] = []

  /// The open post's detail navigation stack (comment-author profile, crosspost, etc.).
  /// Owned here — this is what replaces the external `Router.fullPath`.
  var detailPath: [Router.NavDest] = []

  /// Which column the collapsed (compact) layout shows. Derived from state, never from a
  /// history stack.
  var preferredColumn: NavigationSplitViewColumn = .content

  // MARK: Forward navigation
  //
  // iOS has no native "forward" (a NavigationStack only has back). This is a clean
  // re-implementation of the app's trailing-edge forward affordance. `forwardStack`
  // records what the user just backed out of; `goForward()` replays it. Recording is
  // driven from the view via `recordTransition(from:to:)` on `snapshot`; programmatic
  // navigation suppresses recording so only genuine user back-swipes populate the stack.
  //
  // This is PURELY ADDITIVE: it never mutates the real nav paths except through
  // `goForward()`, so it cannot affect back/resize/fold correctness. Worst case is a rare
  // missed forward entry, never broken navigation.

  enum ForwardEntry: Equatable {
    case detailPush(Router.NavDest)
    case contentPush(Router.NavDest)
    /// Re-focus a column the user backed away from (compact: detail → content → sidebar).
    case focusColumn(NavigationSplitViewColumn)
  }

  struct ForwardRecord: Equatable {
    let id = UUID()
    let entry: ForwardEntry
    let preview: UIImage?

    static func == (lhs: ForwardRecord, rhs: ForwardRecord) -> Bool {
      lhs.id == rhs.id
    }
  }

  private(set) var forwardStack: [ForwardRecord] = []
  @ObservationIgnored private var suppressNextRecording = false

  var canGoForward: Bool { !forwardStack.isEmpty }
  var nextForwardPreview: UIImage? { forwardStack.last?.preview }

  /// The nav state the recorder diffs. Equatable so the view can `.onChange(of:)` it.
  struct Snapshot: Equatable {
    var selectedPostID: String?
    var detailPostID: String?
    var detailHighlightID: String?
    var contentPath: [Router.NavDest]
    var detailPath: [Router.NavDest]
    var preferredColumn: NavigationSplitViewColumn
  }

  var snapshot: Snapshot {
    Snapshot(
      selectedPostID: selectedPostID,
      detailPostID: detailPost?.id,
      detailHighlightID: detailHighlightID,
      contentPath: contentPath,
      detailPath: detailPath,
      preferredColumn: preferredColumn
    )
  }

  // MARK: RedditNavigator

  func navigate(_ destination: Router.NavDest, from origin: RedditNavigationOrigin) {
    switch origin {
    case .content:
      if let detail = Self.postDetail(from: destination) {
        openPostInDetail(detail.post, highlightID: detail.highlightID)
      } else {
        beginUserNavigation()
        contentPath.append(destination)
        preferredColumn = .content
      }
    case .detail:
      beginUserNavigation()
      detailPath.append(destination)
      preferredColumn = .detail
    }
  }

  // MARK: Intents

  /// Open a post in the detail column from a non-feed source (link/deep link/saved).
  func openPostInDetail(_ post: Post, highlightID: String? = nil) {
    beginUserNavigation()
    selectedPostID = nil
    detailPost = post
    detailHighlightID = highlightID
    detailPath = []
    preferredColumn = .detail
  }

  /// Promote a feed-list selection to the detail column. Keeps `selectedPostID` for the
  /// row highlight.
  func selectFeedPost(_ post: Post) {
    beginUserNavigation()
    detailPost = post
    detailHighlightID = nil
    detailPath = []
    preferredColumn = .detail
  }

  /// Clear the detail and any in-column pushes (e.g. when the sidebar feed changes).
  func resetContentAndDetail() {
    beginUserNavigation()
    selectedPostID = nil
    detailPost = nil
    detailHighlightID = nil
    contentPath = []
    detailPath = []
    preferredColumn = .content
  }

  func reset() {
    community = "popular"
    resetContentAndDetail()
  }

  /// Replay the most recent thing the user backed out of.
  func goForward() {
    guard let record = forwardStack.popLast() else { return }
    applyForwardEntry(record.entry)
  }

  private func applyForwardEntry(_ entry: ForwardEntry) {
    suppressNextRecording = true
    switch entry {
    case .detailPush(let destination):
      detailPath.append(destination)
      preferredColumn = .detail
    case .contentPush(let destination):
      contentPath.append(destination)
      preferredColumn = .content
    case .focusColumn(let column):
      preferredColumn = column
    }
  }

  /// Driven from the view's `.onChange(of: posts.snapshot)`. Records the inverse of a
  /// genuine user back-navigation so `goForward()` can replay it.
  func recordTransition(from old: Snapshot, to new: Snapshot, preview: UIImage?) {
    if suppressNextRecording {
      suppressNextRecording = false
      return
    }
    if let popped = Self.poppedSuffix(old.detailPath, new.detailPath) {
      appendForwardEntries(popped.reversed().map(ForwardEntry.detailPush), preview: preview)
    }
    if let popped = Self.poppedSuffix(old.contentPath, new.contentPath) {
      appendForwardEntries(popped.reversed().map(ForwardEntry.contentPush), preview: preview)
    }
    // Column back: the user moved to a shallower column (sidebar < content < detail), so
    // forward can re-focus the deeper one they just left. This is what makes forward
    // replay each step (… → feed → post) instead of jumping straight to the deepest one.
    // Skip re-focusing an empty detail (nothing to show there).
    if Self.columnDepth(new.preferredColumn) < Self.columnDepth(old.preferredColumn),
       !(old.preferredColumn == .detail && detailPost == nil) {
      appendForwardEntries([.focusColumn(old.preferredColumn)], preview: preview)
    }
  }

  /// Compact stack depth, so a "back" (decreasing depth) is distinguishable from a
  /// "forward" (increasing depth) column move. sidebar < content < detail.
  private static func columnDepth(_ column: NavigationSplitViewColumn) -> Int {
    if column == .detail { return 2 }
    if column == .content { return 1 }
    return 0 // sidebar / automatic
  }

  // MARK: Internals

  /// A new forward navigation: clear any redo history and suppress the recorder for the
  /// path/column mutations this action is about to make.
  private func beginUserNavigation() {
    forwardStack = []
    suppressNextRecording = true
  }

  private func appendForwardEntries(_ entries: [ForwardEntry], preview: UIImage?) {
    forwardStack.append(contentsOf: entries.map { ForwardRecord(entry: $0, preview: preview) })
  }

  private static func poppedSuffix(_ old: [Router.NavDest], _ new: [Router.NavDest]) -> [Router.NavDest]? {
    guard old.count > new.count, Array(old.prefix(new.count)) == new else { return nil }
    return Array(old.dropFirst(new.count))
  }

  static func postDetail(from destination: Router.NavDest) -> (post: Post, highlightID: String?)? {
    guard case .reddit(let reddit) = destination else { return nil }
    switch reddit {
    case .post(let post): return (post, nil)
    case .postHighlighted(let post, let highlightID): return (post, highlightID)
    default: return nil
    }
  }
}

// MARK: - Two-column surfaces (Me, Search): leading source column | detail
//
// Scaffolding for a later increment. Me/Search still run on the legacy
// `RedditSplitNavigationModel` (via `RedditTwoColumnShell`) until migrated.

@Observable
@MainActor
final class ColumnNav {
  var selectedPostID: String?
  var contentPath: [Router.NavDest] = []
  var detailPath: [Router.NavDest] = []
  var preferredColumn: NavigationSplitViewColumn = .sidebar

  func reset() {
    selectedPostID = nil
    contentPath = []
    detailPath = []
    preferredColumn = .sidebar
  }
}

// MARK: - Single-stack surfaces (Inbox)

@Observable
@MainActor
final class StackNav {
  var path: [Router.NavDest] = []

  func reset() { path = [] }
}

// MARK: - Settings (sidebar selection | detail)

@Observable
@MainActor
final class SettingsNav {
  var selection: Router.NavDest.Setting? = .general
  var detailPath: [Router.NavDest] = []
  var preferredColumn: NavigationSplitViewColumn = .sidebar

  func reset() {
    selection = .general
    detailPath = []
    preferredColumn = .sidebar
  }
}
