//
//  AppNav.swift
//  winston
//
//  Native, selection-driven navigation model. Replaces the dual-source-of-truth
//  system (`Router.fullPath` + the legacy split-navigation choreography) with thin
//  per-surface state that lets `NavigationSplitView` own all compact↔regular column
//  collapse/expand — so navigation survives foldables, Stage Manager, Split View,
//  rotation, and arbitrary window resizing.
//
//  Introduced incrementally (navigation rebuild). The legacy `Nav`/`Router` types still
//  exist and remain wired until each surface is migrated. See
//  docs/navigation-rebuild-plan.md.
//
//  Vocabulary note: these models keep using `NavDest` as the routing vocabulary
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
  var selectedTab: Tab = .posts {
    didSet {
      if Nav.shared.activeTab != selectedTab.legacyTab {
        Nav.shared.activeTab = selectedTab.legacyTab
      }
    }
  }

  /// Per-surface navigation state. Each is the single source of truth for its tab.
  let posts = PostsNav()
  let me = ColumnNav()
  let search = ColumnNav()
  let inbox = StackNav()
  let settings = SettingsNav()

  enum Tab: String, CaseIterable, Hashable, Codable {
    case posts, inbox, me, search, settings

    init(_ legacyTab: Nav.TabIdentifier) {
      switch legacyTab {
      case .posts: self = .posts
      case .inbox: self = .inbox
      case .me: self = .me
      case .search: self = .search
      case .settings: self = .settings
      }
    }

    var legacyTab: Nav.TabIdentifier {
      switch self {
      case .posts: return .posts
      case .inbox: return .inbox
      case .me: return .me
      case .search: return .search
      case .settings: return .settings
      }
    }
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

  func navigate(_ destination: NavDest, reset: Bool = false) {
    navigate(to: selectedTab, destination, reset: reset)
  }

  func navigate(to tab: Tab, _ destination: NavDest, reset: Bool = false) {
    if reset {
      self.reset(tab)
    }
    switch tab {
    case .posts:
      posts.consumeDeepLink(path: [destination])
    case .inbox:
      inbox.consumeDeepLink(path: [destination])
    case .me:
      me.consumeDeepLink(path: [destination])
    case .search:
      search.consumeDeepLink(path: [destination])
    case .settings:
      settings.consumeDeepLink(path: [destination])
    }
    selectedTab = tab
  }

  @discardableResult
  func goBackOneStep() -> Bool {
    switch selectedTab {
    case .posts: return posts.goBackOneStep()
    case .inbox: return inbox.goBackOneStep()
    case .me: return me.goBackOneStep()
    case .search: return search.goBackOneStep()
    case .settings: return settings.goBackOneStep()
    }
  }

  func resetSelectedSurface() {
    reset(selectedTab)
  }

  var canResetSelectedSurfaceToTabRoot: Bool {
    canResetToTabRoot(selectedTab)
  }

  func canReselectTab(_ tab: Tab) -> Bool {
    switch tab {
    case .posts: return posts.canHandleTabReselect
    case .inbox, .me, .search, .settings: return canResetToTabRoot(tab)
    }
  }

  func canResetToTabRoot(_ tab: Tab) -> Bool {
    switch tab {
    case .posts: return posts.canResetToTabRoot
    case .inbox: return inbox.canResetToTabRoot
    case .me: return me.canResetToTabRoot
    case .search: return search.canResetToTabRoot
    case .settings: return settings.canResetToTabRoot
    }
  }

  func resetSelectedSurfaceToTabRoot() {
    resetToTabRoot(selectedTab)
  }

  func reselectSelectedTab() {
    reselectTab(selectedTab)
  }

  func reselectTab(_ tab: Tab) {
    switch tab {
    case .posts:
      posts.handleTabReselect()
    case .inbox, .me, .search, .settings:
      resetToTabRoot(tab)
    }
  }

  func resetToTabRoot(_ tab: Tab) {
    switch tab {
    case .posts: posts.resetToTabRoot()
    case .inbox: inbox.resetToTabRoot()
    case .me: me.resetToTabRoot()
    case .search: search.resetToTabRoot()
    case .settings: settings.resetToTabRoot()
    }
  }

  func reset(_ tab: Tab) {
    switch tab {
    case .posts: posts.reset()
    case .inbox: inbox.reset()
    case .me: me.reset()
    case .search: search.reset()
    case .settings: settings.reset()
    }
  }

  func resetAll() {
    posts.reset()
    me.reset()
    search.reset()
    inbox.reset()
    settings.reset()
    selectedTab = .posts
  }
}

// MARK: - Posts (three-column: communities sidebar | feed | post+comments)

/// Single source of truth for the Posts split. The detail stack is owned *here*
/// (`detailPath`) instead of an external `Router.fullPath`, so there is nothing to
/// reconcile across size-class transitions — `NavigationSplitView` re-renders straight
/// from this state on resize.
///
/// `preferredColumn` is *derived* from the current selection (post open → detail; else
/// content). There is no history/forward stack and no Router coupling — those were the
/// source of the resize/fold bugs.
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

  /// The feed row nearest the top of the content column. `NavigationSplitView` can
  /// temporarily remove the compact content column while detail is visible; keeping this
  /// outside the feed view lets the list restore after an interactive back gesture.
  var feedScrollPositionID: String?

  /// Explicit post for the detail root when it did not come from the feed list (a link
  /// tap, a deep link, a saved item).
  var detailPost: Post?
  var detailHighlightID: String?

  /// Pushes that stay in the content column (a sub/user opened from a card while the
  /// feed remains visible).
  var contentPath: [NavDest] = []

  /// The open post's detail navigation stack (comment-author profile, crosspost, etc.).
  /// Owned here — this is what replaces the external `Router.fullPath`.
  var detailPath: [NavDest] = []

  /// Which column the collapsed (compact) layout shows. Derived from state, never from a
  /// history stack.
  var preferredColumn: NavigationSplitViewColumn = .content

  init(launchFeed: DefaultLaunchFeed = .popular) {
    community = launchFeed.selection
    preferredColumn = launchFeed.preferredColumn
  }

  // MARK: RedditNavigator

  func navigate(_ destination: NavDest, from origin: RedditNavigationOrigin) {
    switch origin {
    case .content:
      if let detail = Self.postDetail(from: destination) {
        openPostInDetail(detail.post, highlightID: detail.highlightID)
      } else {
        contentPath.append(destination)
        preferredColumn = .content
      }
    case .detail:
      detailPath.append(destination)
      preferredColumn = .detail
    }
  }

  // MARK: Intents

  /// Open a post in the detail column from a non-feed source (link/deep link/saved).
  func openPostInDetail(_ post: Post, highlightID: String? = nil) {
    selectedPostID = nil
    detailPost = post
    detailHighlightID = highlightID
    detailPath = []
    preferredColumn = .detail
  }

  /// Promote a feed-list selection to the detail column. Keeps `selectedPostID` for the
  /// row highlight.
  func selectFeedPost(_ post: Post) {
    detailPost = post
    detailHighlightID = nil
    detailPath = []
    preferredColumn = .detail
  }

  /// Clear the detail and any in-column pushes (e.g. when the sidebar feed changes).
  func resetContentAndDetail() {
    selectedPostID = nil
    feedScrollPositionID = nil
    detailPost = nil
    detailHighlightID = nil
    contentPath = []
    detailPath = []
    preferredColumn = .content
  }

  func goBackOneStep() -> Bool {
    if !detailPath.isEmpty {
      detailPath.removeLast()
      preferredColumn = .detail
      return true
    }

    if selectedPostID != nil || detailPost != nil || detailHighlightID != nil {
      selectedPostID = nil
      detailPost = nil
      detailHighlightID = nil
      preferredColumn = .content
      return true
    }

    if !contentPath.isEmpty {
      contentPath.removeLast()
      preferredColumn = .content
      return true
    }

    if community != nil || preferredColumn != .sidebar {
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

  var canResetToTabRoot: Bool {
    !detailPath.isEmpty ||
    selectedPostID != nil ||
    detailPost != nil ||
    detailHighlightID != nil ||
    !contentPath.isEmpty ||
    (community != nil && preferredColumn != .content) ||
    (community == nil && preferredColumn != .sidebar)
  }

  func resetToTabRoot() {
    let feedScrollPositionID = feedScrollPositionID
    selectedPostID = nil
    detailPost = nil
    detailHighlightID = nil
    contentPath = []
    detailPath = []
    self.feedScrollPositionID = feedScrollPositionID
    preferredColumn = community == nil ? .sidebar : .content
  }

  func revealSubredditSelector() {
    let feedScrollPositionID = feedScrollPositionID
    selectedPostID = nil
    detailPost = nil
    detailHighlightID = nil
    contentPath = []
    detailPath = []
    self.feedScrollPositionID = feedScrollPositionID
    preferredColumn = .sidebar
  }

  func handleTabReselect() {
    if isShowingSubredditSelector {
      return
    } else if isAtFeedRoot {
      revealSubredditSelector()
    } else if canResetToTabRoot {
      resetToTabRootFromTabReselect()
    } else if preferredColumn != .sidebar {
      revealSubredditSelector()
    }
  }

  var canHandleTabReselect: Bool {
    !isShowingSubredditSelector && (canResetToTabRoot || preferredColumn != .sidebar)
  }

  private func resetToTabRootFromTabReselect() {
    let feedScrollPositionID = feedScrollPositionID
    selectedPostID = nil
    detailPost = nil
    detailHighlightID = nil
    contentPath = []
    detailPath = []
    self.feedScrollPositionID = feedScrollPositionID
    preferredColumn = community == nil ? .sidebar : .content
  }

  private var isShowingSubredditSelector: Bool {
    isAtFeedRoot &&
    preferredColumn == .sidebar
  }

  private var isAtFeedRoot: Bool {
    community != nil &&
    selectedPostID == nil &&
    detailPost == nil &&
    detailHighlightID == nil &&
    contentPath.isEmpty &&
    detailPath.isEmpty
  }

  static func postDetail(from destination: NavDest) -> (post: Post, highlightID: String?)? {
    guard case .reddit(let reddit) = destination else { return nil }
    switch reddit {
    case .post(let post): return (post, nil)
    case .postHighlighted(let post, let highlightID): return (post, highlightID)
    default: return nil
    }
  }
}

// MARK: - Two-column surfaces (Me, Search): leading source column | detail

/// Single source of truth for the two-column surfaces (Me, Search). The leading column
/// is a source view (profile / search), not a communities sidebar, so there is no
/// `community` selection — the detail is driven by `detailPost`. Same native model as
/// `PostsNav`: the detail stack is owned here (`detailPath`), so nothing reconciles
/// across size-class transitions.
@Observable
@MainActor
final class ColumnNav: RedditNavigator {
  /// The post shown in the detail column (set from a source-view tap / link / deep link).
  var detailPost: Post?
  var detailHighlightID: String?
  /// Pushes that stay in the leading (source) column.
  var contentPath: [NavDest] = []
  /// The open post's detail navigation stack.
  var detailPath: [NavDest] = []
  /// Which column the collapsed layout shows. Leading source = `.sidebar`; post = `.detail`.
  var preferredColumn: NavigationSplitViewColumn = .sidebar

  func navigate(_ destination: NavDest, from origin: RedditNavigationOrigin) {
    switch origin {
    case .content:
      if let detail = PostsNav.postDetail(from: destination) {
        openPostInDetail(detail.post, highlightID: detail.highlightID)
      } else {
        contentPath.append(destination)
        preferredColumn = .sidebar
      }
    case .detail:
      detailPath.append(destination)
      preferredColumn = .detail
    }
  }

  func openPostInDetail(_ post: Post, highlightID: String? = nil) {
    detailPost = post
    detailHighlightID = highlightID
    detailPath = []
    preferredColumn = .detail
  }

  func resetContentAndDetail() {
    detailPost = nil
    detailHighlightID = nil
    contentPath = []
    detailPath = []
    preferredColumn = .sidebar
  }

  func goBackOneStep() -> Bool {
    if !detailPath.isEmpty {
      detailPath.removeLast()
      preferredColumn = .detail
      return true
    }

    if detailPost != nil || detailHighlightID != nil {
      detailPost = nil
      detailHighlightID = nil
      preferredColumn = .sidebar
      return true
    }

    if !contentPath.isEmpty {
      contentPath.removeLast()
      preferredColumn = .sidebar
      return true
    }

    if preferredColumn != .sidebar {
      preferredColumn = .sidebar
      return true
    }

    return false
  }

  func reset() { resetContentAndDetail() }

  var canResetToTabRoot: Bool {
    detailPost != nil ||
    detailHighlightID != nil ||
    !contentPath.isEmpty ||
    !detailPath.isEmpty ||
    preferredColumn != .sidebar
  }

  func resetToTabRoot() {
    resetContentAndDetail()
  }
}

// MARK: - Single-stack surfaces (Inbox)

@Observable
@MainActor
final class StackNav: RedditNavigator {
  var path: [NavDest] = []

  /// Single stack: every destination (whatever its origin) pushes onto `path`.
  func navigate(_ destination: NavDest, from origin: RedditNavigationOrigin) {
    path.append(destination)
  }

  /// Deep links delivered on the legacy Router push onto the stack in order.
  func consumeDeepLink(path destinations: [NavDest]) {
    path.append(contentsOf: destinations)
  }

  func goBackOneStep() -> Bool {
    guard !path.isEmpty else { return false }
    path.removeLast()
    return true
  }

  func reset() { path = [] }

  var canResetToTabRoot: Bool { !path.isEmpty }

  func resetToTabRoot() {
    path = []
  }
}

// MARK: - Settings (sidebar selection | detail)

/// Single source of truth for the Settings split (sidebar selection | detail). Same
/// native model as the others: the detail stack is owned here (`detailPath`). The leading
/// column is a selection list (no push stack), so `contentPath` is unused. Conforms to
/// `RedditNavigator` so reddit destinations opened from a settings panel push into the
/// detail.
@Observable
@MainActor
final class SettingsNav: RedditNavigator {
  /// Selected settings panel (the sidebar root). Drives the detail column's root.
  var selection: NavDest.Setting? = .general
  /// Unused for settings (the sidebar is selection-based, not a push stack); always empty.
  var contentPath: [NavDest] = []
  /// Pushes deeper into the detail column (a sub-panel / reddit link opened from a panel).
  var detailPath: [NavDest] = []
  var preferredColumn: NavigationSplitViewColumn = .sidebar

  // MARK: Settings navigation

  /// Select a panel from the sidebar. Collapses sub-panels to their split root (e.g. Post
  /// Swipe → Behavior) and seeds the detail stack with the specific panel.
  func select(_ setting: NavDest.Setting) {
    selection = setting.splitRoot
    detailPath = setting == setting.splitRoot ? [] : [.setting(setting)]
    preferredColumn = .detail
  }

  /// Push a destination deeper into the detail stack (a link tapped inside a panel).
  func pushDetail(_ destination: NavDest) {
    detailPath.append(destination)
    preferredColumn = .detail
  }

  // MARK: RedditNavigator (reddit destinations opened from a settings panel)

  func navigate(_ destination: NavDest, from origin: RedditNavigationOrigin) {
    pushDetail(destination)
  }

  func reset() {
    selection = .general
    contentPath = []
    detailPath = []
    preferredColumn = .sidebar
  }

  var canResetToTabRoot: Bool {
    selection != .general ||
    !contentPath.isEmpty ||
    !detailPath.isEmpty ||
    preferredColumn != .sidebar
  }

  func resetToTabRoot() {
    selection = .general
    contentPath = []
    detailPath = []
    preferredColumn = .sidebar
  }

  func goBackOneStep() -> Bool {
    if !detailPath.isEmpty {
      detailPath.removeLast()
      preferredColumn = .detail
      return true
    }

    if selection != .general || preferredColumn != .sidebar {
      selection = .general
      detailPath = []
      preferredColumn = .sidebar
      return true
    }

    return false
  }
}
