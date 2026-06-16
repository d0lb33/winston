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

enum DefaultLaunchFeed: Equatable {
  case home
  case popular
  case saved
  case subscriptionList

  init(settingsValue: String) {
    switch settingsValue {
    case "home":
      self = .home
    case "saved":
      self = .saved
    case "subList":
      self = .subscriptionList
    case "popular", "all":
      self = .popular
    default:
      self = .popular
    }
  }

  var selection: String? {
    switch self {
    case .home: return "home"
    case .popular: return "popular"
    case .saved: return "saved"
    case .subscriptionList: return nil
    }
  }

  @MainActor
  var initialSubreddit: Subreddit {
    Subreddit(id: selection ?? "popular")
  }

  var preferredColumn: NavigationSplitViewColumn {
    selection == nil ? .sidebar : .content
  }
}

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

enum RedditSplitForwardEntry: Equatable {
  case detailPush(Router.NavDest)
  case contentPush(Router.NavDest)
  /// Re-focus a column the user backed away from in compact layout.
  case focusColumn(NavigationSplitViewColumn)
}

struct RedditSplitForwardSnapshot: Equatable {
  var contentPath: [Router.NavDest]
  var detailPath: [Router.NavDest]
  var preferredColumn: NavigationSplitViewColumn
}

@MainActor
protocol RedditSplitForwardNavigating: ForwardEdgeNavigating {
  var contentPath: [Router.NavDest] { get set }
  var detailPath: [Router.NavDest] { get set }
  var preferredColumn: NavigationSplitViewColumn { get set }
  var forwardStack: [RedditSplitForwardEntry] { get set }
  var suppressNextForwardRecording: Bool { get set }
  var forwardContentColumn: NavigationSplitViewColumn { get }
  var hasForwardDetailRoot: Bool { get }
}

extension RedditSplitForwardNavigating {
  var forwardSnapshot: RedditSplitForwardSnapshot {
    RedditSplitForwardSnapshot(
      contentPath: contentPath,
      detailPath: detailPath,
      preferredColumn: preferredColumn
    )
  }

  var canGoForward: Bool {
    !forwardStack.isEmpty
  }

  func goForward() {
    guard let entry = forwardStack.popLast() else { return }
    suppressNextForwardRecording = true
    switch entry {
    case .detailPush(let destination):
      detailPath.append(destination)
      preferredColumn = .detail
    case .contentPush(let destination):
      contentPath.append(destination)
      preferredColumn = forwardContentColumn
    case .focusColumn(let column):
      preferredColumn = column
    }
  }

  func recordForwardTransition(from old: RedditSplitForwardSnapshot, to new: RedditSplitForwardSnapshot) {
    if suppressNextForwardRecording {
      suppressNextForwardRecording = false
      return
    }
    if let popped = Self.poppedSuffix(old.detailPath, new.detailPath) {
      appendForwardEntries(popped.reversed().map(RedditSplitForwardEntry.detailPush))
    }
    if let popped = Self.poppedSuffix(old.contentPath, new.contentPath) {
      appendForwardEntries(popped.reversed().map(RedditSplitForwardEntry.contentPush))
    }
    if Self.columnDepth(new.preferredColumn) < Self.columnDepth(old.preferredColumn),
       !(old.preferredColumn == .detail && !hasForwardDetailRoot) {
      appendForwardEntries([.focusColumn(old.preferredColumn)])
    }
  }

  func beginUserNavigation() {
    forwardStack = []
    suppressNextForwardRecording = true
  }

  private func appendForwardEntries(_ entries: [RedditSplitForwardEntry]) {
    forwardStack.append(contentsOf: entries)
  }

  private static func poppedSuffix(_ old: [Router.NavDest], _ new: [Router.NavDest]) -> [Router.NavDest]? {
    guard old.count > new.count, Array(old.prefix(new.count)) == new else { return nil }
    return Array(old.dropFirst(new.count))
  }

  private static func columnDepth(_ column: NavigationSplitViewColumn) -> Int {
    if column == .detail { return 2 }
    if column == .content { return 1 }
    return 0
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
final class PostsNav: RedditNavigator, RedditSplitForwardNavigating {
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

  var forwardStack: [RedditSplitForwardEntry] = []
  @ObservationIgnored var suppressNextForwardRecording = false
  var forwardContentColumn: NavigationSplitViewColumn { .content }
  var hasForwardDetailRoot: Bool { selectedPostID != nil || detailPost != nil }

  init(launchFeed: DefaultLaunchFeed = .popular) {
    community = launchFeed.selection
    preferredColumn = launchFeed.preferredColumn
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

  func goBackOneStep() -> Bool {
    if !detailPath.isEmpty {
      beginUserNavigation()
      detailPath.removeLast()
      preferredColumn = .detail
      return true
    }

    if selectedPostID != nil || detailPost != nil || detailHighlightID != nil {
      beginUserNavigation()
      selectedPostID = nil
      detailPost = nil
      detailHighlightID = nil
      preferredColumn = .content
      return true
    }

    if !contentPath.isEmpty {
      beginUserNavigation()
      contentPath.removeLast()
      preferredColumn = .content
      return true
    }

    if community != nil || preferredColumn != .sidebar {
      beginUserNavigation()
      preferredColumn = .sidebar
      return true
    }

    return false
  }

  func reset(to launchFeed: DefaultLaunchFeed = .popular) {
    community = launchFeed.selection
    resetContentAndDetail()
    preferredColumn = launchFeed.preferredColumn
  }

  func resetToSidebarRoot() {
    community = nil
    resetContentAndDetail()
    preferredColumn = .sidebar
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

/// Single source of truth for the two-column surfaces (Me, Search). The leading column
/// is a source view (profile / search), not a communities sidebar, so there is no
/// `community` selection — the detail is driven by `detailPost`. Same native model as
/// `PostsNav`: the detail stack is owned here (`detailPath`), so nothing reconciles
/// across size-class transitions. Forward history is shared with Posts through
/// `RedditSplitForwardNavigating`.
@Observable
@MainActor
final class ColumnNav: RedditNavigator, RedditSplitForwardNavigating {
  /// The post shown in the detail column (set from a source-view tap / link / deep link).
  var detailPost: Post?
  var detailHighlightID: String?
  /// Pushes that stay in the leading (source) column.
  var contentPath: [Router.NavDest] = []
  /// The open post's detail navigation stack.
  var detailPath: [Router.NavDest] = []
  /// Which column the collapsed layout shows. Leading source = `.sidebar`; post = `.detail`.
  var preferredColumn: NavigationSplitViewColumn = .sidebar
  var forwardStack: [RedditSplitForwardEntry] = []
  @ObservationIgnored var suppressNextForwardRecording = false
  var forwardContentColumn: NavigationSplitViewColumn { .sidebar }
  var hasForwardDetailRoot: Bool { detailPost != nil }

  func navigate(_ destination: Router.NavDest, from origin: RedditNavigationOrigin) {
    switch origin {
    case .content:
      if let detail = PostsNav.postDetail(from: destination) {
        openPostInDetail(detail.post, highlightID: detail.highlightID)
      } else {
        beginUserNavigation()
        contentPath.append(destination)
        preferredColumn = .sidebar
      }
    case .detail:
      beginUserNavigation()
      detailPath.append(destination)
      preferredColumn = .detail
    }
  }

  func openPostInDetail(_ post: Post, highlightID: String? = nil) {
    beginUserNavigation()
    detailPost = post
    detailHighlightID = highlightID
    detailPath = []
    preferredColumn = .detail
  }

  func resetContentAndDetail() {
    beginUserNavigation()
    detailPost = nil
    detailHighlightID = nil
    contentPath = []
    detailPath = []
    preferredColumn = .sidebar
  }

  func goBackOneStep() -> Bool {
    if !detailPath.isEmpty {
      beginUserNavigation()
      detailPath.removeLast()
      preferredColumn = .detail
      return true
    }

    if detailPost != nil || detailHighlightID != nil {
      beginUserNavigation()
      detailPost = nil
      detailHighlightID = nil
      preferredColumn = .sidebar
      return true
    }

    if !contentPath.isEmpty {
      beginUserNavigation()
      contentPath.removeLast()
      preferredColumn = .sidebar
      return true
    }

    if preferredColumn != .sidebar {
      beginUserNavigation()
      preferredColumn = .sidebar
      return true
    }

    return false
  }

  func reset() { resetContentAndDetail() }
}

// MARK: - Single-stack surfaces (Inbox)

@Observable
@MainActor
final class StackNav {
  var path: [Router.NavDest] = []

  func goBackOneStep() -> Bool {
    guard !path.isEmpty else { return false }
    path.removeLast()
    return true
  }

  func reset() { path = [] }
}

// MARK: - Settings (sidebar selection | detail)

/// Single source of truth for the Settings split (sidebar selection | detail). Same
/// native model as the others: the detail stack is owned here (`detailPath`). The leading
/// column is a selection list (no push stack), so `contentPath` is unused — it only
/// exists to satisfy `RedditSplitForwardNavigating`. Conforms to `RedditNavigator` so
/// reddit destinations opened from a settings panel push into the detail.
@Observable
@MainActor
final class SettingsNav: RedditNavigator, RedditSplitForwardNavigating {
  /// Selected settings panel (the sidebar root). Drives the detail column's root.
  var selection: Router.NavDest.Setting? = .general
  /// Unused for settings (the sidebar is selection-based, not a push stack); always empty.
  var contentPath: [Router.NavDest] = []
  /// Pushes deeper into the detail column (a sub-panel / reddit link opened from a panel).
  var detailPath: [Router.NavDest] = []
  var preferredColumn: NavigationSplitViewColumn = .sidebar
  var forwardStack: [RedditSplitForwardEntry] = []
  @ObservationIgnored var suppressNextForwardRecording = false
  var forwardContentColumn: NavigationSplitViewColumn { .sidebar }
  var hasForwardDetailRoot: Bool { selection != nil }

  // MARK: Settings navigation

  /// Select a panel from the sidebar. Collapses sub-panels to their split root (e.g. Post
  /// Swipe → Behavior) and seeds the detail stack with the specific panel.
  func select(_ setting: Router.NavDest.Setting) {
    beginUserNavigation()
    selection = setting.splitRoot
    detailPath = setting == setting.splitRoot ? [] : [.setting(setting)]
    preferredColumn = .detail
  }

  /// Push a destination deeper into the detail stack (a link tapped inside a panel).
  func pushDetail(_ destination: Router.NavDest) {
    beginUserNavigation()
    detailPath.append(destination)
    preferredColumn = .detail
  }

  // MARK: RedditNavigator (reddit destinations opened from a settings panel)

  func navigate(_ destination: Router.NavDest, from origin: RedditNavigationOrigin) {
    pushDetail(destination)
  }

  func reset() {
    forwardStack = []
    suppressNextForwardRecording = false
    selection = .general
    contentPath = []
    detailPath = []
    preferredColumn = .sidebar
  }

  func goBackOneStep() -> Bool {
    if !detailPath.isEmpty {
      beginUserNavigation()
      detailPath.removeLast()
      preferredColumn = .detail
      return true
    }

    if selection != .general || preferredColumn != .sidebar {
      beginUserNavigation()
      selection = .general
      detailPath = []
      preferredColumn = .sidebar
      return true
    }

    return false
  }
}
