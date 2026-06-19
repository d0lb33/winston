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

import Foundation
import SwiftUI
import Defaults

/// The source a Posts feed is showing. Home, Popular, Saved, a subreddit, and the
/// saved-lists screens are all the same kind of thing — a feed scope — selected from a
/// picker (compact) or a sidebar (wide). Replaces the old stringly `community` token so the
/// compact shell never depends on `NavigationSplitView`'s collapsed-column choreography.
enum FeedScope: Hashable, Codable {
  case home
  case popular
  case saved
  case subreddit(id: String)
  case savedList(id: UUID)
  case savedListsOverview

  /// The legacy string token (sidebar selection / deep-link feed / saved-list route id).
  init?(token: String?) {
    guard let token else { return nil }
    switch token {
    case "home": self = .home
    case "popular", "all": self = .popular
    case "saved": self = .saved
    case SavedListsRoute.overviewID: self = .savedListsOverview
    default:
      if let listID = SavedListsRoute.listID(from: token) { self = .savedList(id: listID) }
      else { self = .subreddit(id: token) }
    }
  }

  var token: String {
    switch self {
    case .home: return "home"
    case .popular: return "popular"
    case .saved: return "saved"
    case .subreddit(let id): return id
    case .savedList(let id): return SavedListsRoute.id(for: id)
    case .savedListsOverview: return SavedListsRoute.overviewID
    }
  }

  /// True for scopes the `AuroraFeedModel` can load as a normal post feed.
  var isPostFeed: Bool {
    switch self {
    case .home, .popular, .subreddit: return true
    case .saved, .savedList, .savedListsOverview: return false
    }
  }

  /// The feed token an `AuroraFeedModel` should load for this scope (nil for the
  /// special saved-lists screens, which are not post feeds).
  var feedSubredditID: String? {
    switch self {
    case .home: return "home"
    case .popular: return "popular"
    case .saved: return "saved"
    case .subreddit(let id): return id
    case .savedList, .savedListsOverview: return nil
    }
  }
}

/// The compact Posts `NavigationStack` path vocabulary. The root is the scope LIST page; the
/// feed is PUSHED (`.feed`) so it gets a back button, and posts/subs/users pushed on top of the
/// feed travel as `.dest(NavDest)`. Local to the compact Posts shell — it deliberately does NOT
/// touch `NavDest` (the app-wide vocabulary shared with Me/Search/Inbox/Settings).
enum CompactRoute: Hashable {
  case feed
  case dest(NavDest)
}

enum TabTapKind: Equatable {
  case single
  case double
}

enum PostsTabLayoutMode: Equatable {
  case compact
  case regular
}

enum PostsTabColumn: Equatable {
  case sidebar
  case content
  case detail
}

struct PostsTabInteractionState: Equatable {
  var layout: PostsTabLayoutMode = .regular
  var contentCanScrollToTop = false
  var detailCanScrollToTop = false
}

enum PostsSurfaceCommand: Equatable {
  case scrollContentToTop
  case scrollDetailToTop
}

enum PostsNavigationAction: Equatable {
  case backOneStep(PostsTabColumn)
  /// Compact only: pop the scope's feed off the stack, back to the root scope list.
  case popFeedToRoot
}

enum TabReselectAction: Equatable {
  case surface(PostsSurfaceCommand)
  case navigation(PostsNavigationAction)
  case resetToTabRoot
  case none

  var diagnosticsName: String {
    switch self {
    case .surface(.scrollContentToTop): return "surface.scrollContentToTop"
    case .surface(.scrollDetailToTop): return "surface.scrollDetailToTop"
    case .navigation(.backOneStep(let column)): return "navigation.backOneStep.\(column.diagnosticsName)"
    case .navigation(.popFeedToRoot): return "navigation.popFeedToRoot"
    case .resetToTabRoot: return "resetToTabRoot"
    case .none: return "none"
    }
  }
}

extension PostsTabColumn {
  var diagnosticsName: String {
    switch self {
    case .sidebar: return "sidebar"
    case .content: return "content"
    case .detail: return "detail"
    }
  }
}

struct TabTapClassifier {
  var doubleTapInterval: CFTimeInterval = 0.32
  var duplicateCallbackInterval: CFTimeInterval = 0.08

  private var lastEventID: ObjectIdentifier?
  private var lastFallbackCallbackTab: AppNav.Tab?
  private var lastFallbackCallbackTime: CFTimeInterval?
  private var lastPhysicalTapTab: AppNav.Tab?
  private var lastPhysicalTapTime: CFTimeInterval?

  mutating func classify(tab: AppNav.Tab, eventID: ObjectIdentifier?, time: CFTimeInterval) -> TabTapKind? {
    if let eventID {
      guard lastEventID != eventID else { return nil }
      lastEventID = eventID
    } else if let lastTab = lastFallbackCallbackTab,
              let lastTime = lastFallbackCallbackTime,
              lastTab == tab,
              time - lastTime <= duplicateCallbackInterval {
      return nil
    }

    lastFallbackCallbackTab = tab
    lastFallbackCallbackTime = time

    guard lastPhysicalTapTab == tab,
          let lastPhysicalTapTime,
          time - lastPhysicalTapTime <= doubleTapInterval
    else {
      lastPhysicalTapTab = tab
      lastPhysicalTapTime = time
      return .single
    }

    self.lastPhysicalTapTab = nil
    self.lastPhysicalTapTime = nil
    return .double
  }
}

@MainActor
final class TabTapClassifierBox {
  private var classifier = TabTapClassifier()

  func classify(tab: AppNav.Tab, eventID: ObjectIdentifier?, time: CFTimeInterval) -> TabTapKind? {
    classifier.classify(tab: tab, eventID: eventID, time: time)
  }
}

@MainActor
enum TabReselectActionExecutor {
  static func execute(_ action: TabReselectAction, for tab: AppNav.Tab, appNav: AppNav) {
    switch action {
    case .surface(let command):
      guard tab == .posts else { return }
      appNav.posts.requestSurfaceCommand(command)
    case .navigation(.backOneStep(let column)):
      guard tab == .posts else { return }
      switch column {
      case .detail: _ = appNav.posts.goBackDetailOneStepForTabReselect()
      case .content: _ = appNav.posts.goBackContentOneStepForTabReselect()
      case .sidebar: break
      }
    case .navigation(.popFeedToRoot):
      guard tab == .posts else { return }
      appNav.posts.popCompactFeedToRootList()
    case .resetToTabRoot:
      appNav.resetToTabRoot(tab)
    case .none:
      break
    }
  }
}

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

  /// The feed scope to launch into. There is no "show the subreddit list" scope — the
  /// scope picker (compact) / scopes sidebar (wide) is always one tap away — so a
  /// `subscriptionList` preference launches into the Home (subscriptions) feed.
  var scope: FeedScope {
    switch self {
    case .home: return .home
    case .popular: return .popular
    case .saved: return .saved
    case .subscriptionList: return .home
    }
  }

  @MainActor
  var initialSubreddit: Subreddit {
    Subreddit(id: scope.feedSubredditID ?? "popular")
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
  let posts = PostsNav(launchFeed: DefaultLaunchFeed(settingsValue: Defaults[.BehaviorDefSettings].preferenceDefaultFeed))
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
    handleTabReselect(tab, tap: .single) != .none
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
    let action = handleTabReselect(tab, tap: .single)
    TabReselectActionExecutor.execute(action, for: tab, appNav: self)
  }

  func handleTabReselect(_ tab: Tab, tap: TabTapKind) -> TabReselectAction {
    switch tab {
    case .posts:
      // Double tap: jump straight back to the tab root — on compact that's the root scope list
      // (drops the feed too), on wide the bare feed root with the sidebar still showing.
      if tap == .double {
        return canResetToTabRoot(.posts) ? .resetToTabRoot : .none
      }
      return posts.tabReselectAction()
    case .inbox, .me, .search, .settings:
      return canResetToTabRoot(tab) ? .resetToTabRoot : .none
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
  /// The feed the Posts surface is showing. Replaces the old stringly `community` token; a
  /// feed source picked from the scope picker (compact) or the scopes sidebar (wide).
  var scope: FeedScope = .popular

  /// Feed-list selection — the post highlighted in the WIDE feed column. (The compact shell
  /// pushes the post instead, but still routes through this via the feed `List(selection:)`.)
  var selectedPostID: String?

  /// Legacy external scroll slot. `AuroraFeed` keeps live restoration state in
  /// `AuroraFeedScrollStateStore` so scroll frames do not write into this observed model.
  var feedScrollPosition: AuroraFeedScrollPosition?
  /// Low-frequency signal for non-observed feed scroll runtime state to clear restoration.
  var feedScrollResetRequest = 0

  /// Compact only: whether the scope's feed is PUSHED on top of the root scope list. `false`
  /// == showing the root list (the Apollo-style home). The wide split ignores this — it always
  /// shows the feed column. Set true by `presentScopeFeed` (root list / wide sidebar / deep
  /// link); cleared when the compact stack pops past the feed (the `compactPath` setter).
  var compactFeedPresented = false

  /// The open post (a feed tap, a link, a deep link, or a saved item).
  var detailPost: Post?
  var detailHighlightID: String?

  /// Pushes that live alongside the feed (a sub/user opened from a feed card before any
  /// post is open). Wide: the content column's stack. Compact: the stack entries between
  /// the feed root and the open post.
  var contentPath: [NavDest] = []

  /// The open post's navigation stack (comment-author profile, crosspost, etc.).
  var detailPath: [NavDest] = []

  var tabInteractionState = PostsTabInteractionState()
  var contentScrollToTopRequest = 0
  var detailScrollToTopRequest = 0

  init(launchFeed: DefaultLaunchFeed = .popular) {
    scope = launchFeed.scope
  }

  // MARK: Compact stack projection

  /// The compact shell renders ONE `NavigationStack` whose ROOT is the scope LIST page and
  /// whose path is a projection of this model: `[.feed] + [content pushes] + (open post) +
  /// [detail pushes]` — but only when a feed is presented; otherwise `[]` (at the root list).
  /// Reading rebuilds the path; writing (a system back gesture / programmatic pop) decomposes
  /// the shorter path back into `compactFeedPresented` / `contentPath` / `detailPost` /
  /// `detailPath`. There is no second source of truth — the same state drives compact and
  /// wide, so fold/unfold preserves it.
  var compactPath: [CompactRoute] {
    get {
      guard compactFeedPresented else { return [] }
      var path: [CompactRoute] = [.feed]
      path.append(contentsOf: contentPath.map(CompactRoute.dest))
      if let detailPost {
        path.append(.dest(Self.navDest(for: detailPost, highlightID: detailHighlightID)))
        path.append(contentsOf: detailPath.map(CompactRoute.dest))
      }
      return path
    }
    set {
      // Popped past the feed (empty, or somehow not led by `.feed`) → back at the root list.
      guard case .feed? = newValue.first else {
        compactFeedPresented = false
        resetContentAndDetail()
        return
      }
      compactFeedPresented = true
      // Drop the leading `.feed`; the rest are `.dest(NavDest)` pushes. Decompose them with
      // the same index math the feed-relative projection used.
      let suffix: [NavDest] = newValue.dropFirst().compactMap { route in
        if case .dest(let destination) = route { return destination }
        return nil
      }
      let postIndex = contentPath.count
      if detailPost != nil {
        if suffix.count <= postIndex {
          // The open post (and anything pushed onto it) was popped.
          detailPost = nil
          detailHighlightID = nil
          selectedPostID = nil
          detailPath = []
          contentPath = Array(suffix.prefix(postIndex))
        } else {
          // Post still on the stack; everything above it is the detail path.
          detailPath = Array(suffix.dropFirst(postIndex + 1))
        }
      } else {
        contentPath = suffix
      }
    }
  }

  static func navDest(for post: Post, highlightID: String?) -> NavDest {
    .reddit(highlightID.map { .postHighlighted(post, $0) } ?? .post(post))
  }

  // MARK: RedditNavigator

  func navigate(_ destination: NavDest, from origin: RedditNavigationOrigin) {
    switch origin {
    case .content:
      // Any content-level navigation implies a feed context (a feed-card tap, or a deep link).
      // On compact this ensures the push is visible above the root list; on wide it's moot.
      compactFeedPresented = true
      if let detail = Self.postDetail(from: destination) {
        openPostInDetail(detail.post, highlightID: detail.highlightID)
      } else {
        contentPath.append(destination)
      }
    case .detail:
      detailPath.append(destination)
    }
  }

  // MARK: Intents

  /// Open a post from a non-feed source (link / deep link / saved item). On compact this sits
  /// above the feed (root list → feed → post), so present the feed.
  func openPostInDetail(_ post: Post, highlightID: String? = nil) {
    compactFeedPresented = true
    selectedPostID = nil
    detailPost = post
    detailHighlightID = highlightID
    detailPath = []
  }

  /// Promote a feed-list selection to the open post. Keeps `selectedPostID` for the wide
  /// feed row highlight.
  func selectFeedPost(_ post: Post) {
    compactFeedPresented = true
    detailPost = post
    detailHighlightID = nil
    detailPath = []
  }

  /// Push the feed for `scope` (compact root-list pick, wide sidebar pick, or deep link). The
  /// scope change drives `AuroraRoot.onChange(of: scope)` → resetContentAndDetail + model sync.
  func presentScopeFeed(_ scope: FeedScope) {
    self.scope = scope
    compactFeedPresented = true
  }

  /// Compact only: pop the feed off the stack, back to the root scope list. Keeps `scope`
  /// (the list highlights it) but drops the feed's pushes + scroll position.
  func popCompactFeedToRootList() {
    compactFeedPresented = false
    resetContentAndDetail()
  }

  /// Clear the open post and any in-feed pushes (e.g. when the feed scope changes).
  func resetContentAndDetail() {
    selectedPostID = nil
    requestFeedScrollReset()
    detailPost = nil
    detailHighlightID = nil
    contentPath = []
    detailPath = []
    updateContentCanScrollToTop(false)
    updateDetailCanScrollToTop(false)
  }

  func goBackOneStep() -> Bool {
    if !detailPath.isEmpty { detailPath.removeLast(); return true }
    if hasOpenPost {
      selectedPostID = nil
      detailPost = nil
      detailHighlightID = nil
      return true
    }
    if !contentPath.isEmpty { contentPath.removeLast(); return true }
    return false
  }

  func reset(to launchFeed: DefaultLaunchFeed = .popular) {
    scope = launchFeed.scope
    compactFeedPresented = false
    resetContentAndDetail()
  }

  var canResetToTabRoot: Bool {
    let base = !detailPath.isEmpty || selectedPostID != nil || detailPost != nil ||
      detailHighlightID != nil || !contentPath.isEmpty
    // Compact: a presented feed is itself resettable (double-tap drops it → the root list).
    // Wide has no root list, so the flag is moot there and must not change its behavior.
    if tabInteractionState.layout == .compact { return base || compactFeedPresented }
    return base
  }

  /// Clear everything back to the tab root. On compact that's the root scope list (double-tap
  /// jumps "all the way back to the subreddit selection"); on wide there is no list, so the
  /// flag is moot and this lands on the bare feed root with the sidebar still showing.
  func resetToTabRoot() {
    compactFeedPresented = false
    selectedPostID = nil
    detailPost = nil
    detailHighlightID = nil
    contentPath = []
    detailPath = []
    requestFeedScrollReset()
  }

  func requestFeedScrollReset() {
    feedScrollPosition = nil
    feedScrollResetRequest += 1
  }

  func tabReselectAction() -> TabReselectAction {
    switch tabInteractionState.layout {
    case .compact:
      return compactTabReselectAction()
    case .regular:
      return regularTabReselectAction()
    }
  }

  func requestSurfaceCommand(_ command: PostsSurfaceCommand) {
    switch command {
    case .scrollContentToTop:
      contentScrollToTopRequest += 1
    case .scrollDetailToTop:
      detailScrollToTopRequest += 1
    }
  }

  func updateInteractionLayout(_ layout: PostsTabLayoutMode) {
    guard tabInteractionState.layout != layout else { return }
    tabInteractionState.layout = layout
  }

  func updateContentCanScrollToTop(_ canScroll: Bool) {
    guard tabInteractionState.contentCanScrollToTop != canScroll else { return }
    tabInteractionState.contentCanScrollToTop = canScroll
  }

  func updateDetailCanScrollToTop(_ canScroll: Bool) {
    guard tabInteractionState.detailCanScrollToTop != canScroll else { return }
    tabInteractionState.detailCanScrollToTop = canScroll
  }

  /// A post is open and on top of the stack (the detail surface).
  var hasOpenPost: Bool {
    detailPost != nil || selectedPostID != nil || detailHighlightID != nil
  }

  func goBackDetailOneStepForTabReselect() -> Bool {
    if !detailPath.isEmpty { detailPath.removeLast(); return true }
    if hasOpenPost {
      selectedPostID = nil
      detailPost = nil
      detailHighlightID = nil
      return true
    }
    return false
  }

  func goBackContentOneStepForTabReselect() -> Bool {
    guard !contentPath.isEmpty else { return false }
    contentPath.removeLast()
    return true
  }

  // Compact single tap: peel back ONE layer — scroll the active surface to the top, then pop
  // one navigation level, and finally pop the feed itself back to the root scope list. The
  // active surface is DERIVED from the model (a post open → the detail surface; otherwise the
  // feed), not from any collapsed-column inference. At the root list there is nothing above,
  // so reselect is a no-op.
  private func compactTabReselectAction() -> TabReselectAction {
    guard compactFeedPresented else { return .none }
    if hasOpenPost {
      if tabInteractionState.detailCanScrollToTop { return .surface(.scrollDetailToTop) }
      return .navigation(.backOneStep(.detail))
    }
    if tabInteractionState.contentCanScrollToTop { return .surface(.scrollContentToTop) }
    if !contentPath.isEmpty { return .navigation(.backOneStep(.content)) }
    // At the feed's own root → pop the feed back to the root scope list.
    return .navigation(.popFeedToRoot)
  }

  private func regularTabReselectAction() -> TabReselectAction {
    if tabInteractionState.contentCanScrollToTop { return .surface(.scrollContentToTop) }
    if tabInteractionState.detailCanScrollToTop { return .surface(.scrollDetailToTop) }
    if !detailPath.isEmpty || hasOpenPost { return .navigation(.backOneStep(.detail)) }
    if !contentPath.isEmpty { return .navigation(.backOneStep(.content)) }
    return canResetToTabRoot ? .resetToTabRoot : .none
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
  /// Bumped on a Search-tab reselect so the Search surface presents + focuses its
  /// search field (opens the keyboard). Only the `search` instance consumes it.
  var searchFieldFocusRequest = 0
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
    selection != nil ||
    !contentPath.isEmpty ||
    !detailPath.isEmpty ||
    preferredColumn != .sidebar
  }

  /// Reset to the Settings tab root: the sidebar panel list with nothing selected. Clearing
  /// `selection` to nil (not `.general`) is what actually makes a compact split collapse to
  /// the sidebar — a non-nil selection re-pushes the detail the instant the native
  /// reselect-pop tries to collapse it. The wide split just shows the empty-detail state,
  /// which is the correct "no panel chosen" root there too.
  func resetToTabRoot() {
    selection = nil
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
