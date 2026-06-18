//
//  RedditDestinations.swift
//  winston
//
//  The single, centralized navigation-destination host for Reddit `NavDest`
//  pushes, plus the write-only legacy-Router deep-link inbox shared by every
//  migrated surface.
//
//  Why this exists (the recurring deep-nav bug): a `.navigationDestination`
//  closure that only renders `RouterDestinationView(destination:)` does NOT
//  re-inject the owning navigator/origin into the pushed screen. SwiftUI does
//  not flow the environment set on a NavigationStack's *root content* down to
//  destinations pushed onto that stack, so a pushed `UserView` /
//  `AuroraSubFeedScreen` would fall back to `Nav.to` (legacy Router) or the
//  wrong column when its own links were tapped. `.redditDestinations(_:origin:)`
//  re-applies `.redditNavigation(navigator, origin:)` to every pushed screen so
//  a link tapped two levels deep still routes into the correct column.
//
//  This is the ONLY file allowed to reference `RouterDestinationView`
//  (enforced by scripts/nav-guards.sh).
//

import SwiftUI

// MARK: - Centralized destination hosts

extension View {
  /// Host Reddit `NavDest` destinations for a column's `NavigationStack`,
  /// re-applying the owning navigator + origin so pushed screens route their own
  /// link taps into the correct column. Use on Posts / Me / Search / Inbox stacks.
  func redditDestinations(
    _ navigator: any RedditNavigator,
    origin: RedditNavigationOrigin
  ) -> some View {
    navigationDestination(for: NavDest.self) { destination in
      RouterDestinationView(destination: destination)
        .redditNavigation(navigator, origin: origin)
    }
  }

  /// Host destinations for the COMPACT Posts stack — a single `NavigationStack` whose ROOT is
  /// the scope LIST page and whose path is `PostsNav.compactPath` (`.feed` + content pushes +
  /// the open post + detail pushes). The `.feed` route renders the scope's feed (the passed
  /// `feed` builder) at `.content` origin so a sub/user tapped on a feed card appends to
  /// `contentPath`. The open post carries `.detail` origin (links inside it append to
  /// `detailPath`) and is wired for tab-reselect scroll-to-top; any other pushed destination
  /// carries `.content` origin.
  func compactPostsDestinations(_ posts: PostsNav, @ViewBuilder feed: @escaping () -> some View) -> some View {
    navigationDestination(for: CompactRoute.self) { route in
      switch route {
      case .feed:
        feed()
          .redditNavigation(posts, origin: .content)
      case .dest(let destination):
        if let detail = PostsNav.postDetail(from: destination) {
          RedditPostDestination(
            post: detail.post,
            highlightID: detail.highlightID,
            scrollToTopRequest: posts.detailScrollToTopRequest,
            onScrollStateChanged: { posts.updateDetailCanScrollToTop($0) }
          )
          .redditNavigation(posts, origin: .detail)
        } else {
          // Origin depends on WHERE this screen sits in the flattened compact stack,
          // not its type. A sub/user pushed ON TOP of the open post lives in
          // `detailPath`, so its own link taps must append to the detail stack (a
          // nested push). Only screens BEFORE the open post (the feed's content
          // pushes) use `.content`, where a post tap replaces the detail. Without
          // this, a post tapped inside a profile that was opened from a post detail
          // takes the `.content` path → `openPostInDetail`, which clears `detailPath`
          // and collapses the stack back to a single post instead of pushing.
          let origin: RedditNavigationOrigin = posts.detailPath.contains(destination) ? .detail : .content
          RouterDestinationView(destination: destination)
            .redditNavigation(posts, origin: origin)
        }
      }
    }
  }

  /// Host destinations for the Settings detail stack. Pushed panels are always at
  /// detail origin, and must carry BOTH the reddit nav seam (reddit links inside a
  /// panel) and the settings nav seam (nested settings links).
  func settingsDestinations(_ nav: SettingsNav) -> some View {
    navigationDestination(for: NavDest.self) { destination in
      RouterDestinationView(destination: destination)
        .redditNavigation(nav, origin: .detail)
        .settingsNavigation(nav, origin: .detail)
    }
  }
}

// MARK: - Destination factory

struct RouterDestinationView: View {
  let destination: NavDest

  var body: some View {
    switch destination {
    case .reddit(let reddDest):
      switch reddDest {
      case .post(let (post)):
        RedditPostDestination(post: post)
      case .postHighlighted(let post, let highlightID):
        RedditPostDestination(post: post, highlightID: highlightID)
      case .subFeed(let sub):
        AuroraSubFeedScreen(subreddit: sub)
          .diagnosticScreen("reddit.subFeed.\(sub.id)")
      case .subInfo(let sub):
        SubredditInfo(subreddit: sub)
          .diagnosticScreen("reddit.subInfo.\(sub.id)")
      case .multiFeed(let multi):
        MultiPostsView(multi: multi)
          .diagnosticScreen("reddit.multiFeed.\(multi.id)")
      case .multiInfo(_):
        EmptyView()
          .diagnosticScreen("reddit.multiInfo")
      case .user(let user):
        UserView(user: user)
          .diagnosticScreen("reddit.user.\(user.id)")
      }
    case .setting(let settingsDest):
      switch settingsDest {
      case .general:
        GeneralPanel()
          .diagnosticScreen("setting.general")
      case .behavior:
        BehaviorPanel()
          .diagnosticScreen("setting.behavior")
      case .appearance:
        AppearancePanel()
          .diagnosticScreen("setting.appearance")
      case .accounts:
        AccountsPanel()
          .diagnosticScreen("setting.accounts")
      case .diagnostics:
        DiagnosticsPanel()
          .diagnosticScreen("setting.diagnostics")
      case .about:
        AboutPanel()
          .diagnosticScreen("setting.about")
      case .commentSwipe:
        CommentSwipePanel()
          .diagnosticScreen("setting.commentSwipe")
      case .postSwipe:
        PostSwipePanel()
          .diagnosticScreen("setting.postSwipe")
      case .accessibility:
        AccessibilityPanel()
          .diagnosticScreen("setting.accessibility")
      case .filteredSubreddits:
        FilteredSubredditsSettings()
          .diagnosticScreen("setting.filteredSubreddits")
      case .faq:
        FAQPanel()
          .diagnosticScreen("setting.faq")
      case .appIcon:
        AppIconSetting()
          .diagnosticScreen("setting.appIcon")
      case .designLab:
        DesignLabGallery()
          .diagnosticScreen("setting.designLab")
      }
    }
  }
}

private struct RedditPostDestination: View {
  @ObservedObject var post: Post
  var highlightID: String?
  /// Wired by the compact Posts stack so a tab reselect can scroll the open post to the top
  /// and so the post reports its scroll state. Defaults make plain pushes (crossposts, etc.)
  /// behave exactly as before.
  var scrollToTopRequest: Int = 0
  var onScrollStateChanged: (Bool) -> Void = { _ in }

  private var subreddit: Subreddit? {
    post.winstonData?.subreddit ?? post.data.map { Subreddit(id: $0.subreddit) }
  }

  var body: some View {
    if let subreddit {
      AuroraPostDetail(post: post, subreddit: subreddit, highlightID: highlightID,
                       scrollToTopRequest: scrollToTopRequest, onScrollStateChanged: onScrollStateChanged)
        .diagnosticScreen(diagnosticName)
    } else {
      ProgressView()
        .progressViewStyle(.circular)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
          post.fetchItself()
        }
        .diagnosticScreen(diagnosticName)
    }
  }

  private var diagnosticName: String {
    if let highlightID {
      return "reddit.postHighlighted.\(post.id).\(highlightID)"
    }
    return "reddit.post.\(post.id)"
  }
}

// MARK: - Legacy-Router deep-link inbox (write-only)

/// A surface model that can absorb deep links arriving on the legacy `Router`.
///
/// Path semantics (central to the deep-nav fix): the FIRST post in a delivered
/// path becomes the detail root, and EVERY subsequent destination appends to the
/// detail stack — a legacy `post → user → subreddit` path becomes Post (root) →
/// User → Subreddit inside the open post, never three content-column pushes. A
/// leading non-post destination pushes content; a leading feed-token subreddit
/// selects the sidebar feed (Posts only).
@MainActor
protocol RedditDeepLinkConsuming: RedditNavigator {
  /// Open a post as the detail root (link / deep link / saved item).
  func openDeepLinkPostRoot(_ post: Post, highlightID: String?)
  /// True while a post is open in the detail column (so the rest of a path appends to detail).
  var hasOpenDetailRoot: Bool { get }
  /// Select a sidebar feed token (Posts only). Returns true when consumed here.
  func setDeepLinkFeed(_ token: String) -> Bool
}

extension RedditDeepLinkConsuming {
  func setDeepLinkFeed(_ token: String) -> Bool { false }

  func consumeDeepLink(path: [NavDest]) {
    for (index, destination) in path.enumerated() {
      if let detail = PostsNav.postDetail(from: destination) {
        openDeepLinkPostRoot(detail.post, highlightID: detail.highlightID)
      } else if index == 0,
                case .reddit(.subFeed(let sub)) = destination,
                feedsAndSuch.contains(sub.id),
                setDeepLinkFeed(sub.id) {
        // consumed as a sidebar feed selection
      } else if hasOpenDetailRoot {
        navigate(destination, from: .detail)
      } else {
        navigate(destination, from: .content)
      }
    }
  }
}

extension PostsNav: RedditDeepLinkConsuming {
  func openDeepLinkPostRoot(_ post: Post, highlightID: String?) {
    // `openPostInDetail` presents the feed, so the compact stack is root list → feed → post.
    openPostInDetail(post, highlightID: highlightID)
  }
  var hasOpenDetailRoot: Bool { detailPost != nil || selectedPostID != nil }
  func setDeepLinkFeed(_ token: String) -> Bool {
    guard let scope = FeedScope(token: token) else { return false }
    presentScopeFeed(scope)
    return true
  }
}

extension ColumnNav: RedditDeepLinkConsuming {
  func openDeepLinkPostRoot(_ post: Post, highlightID: String?) {
    openPostInDetail(post, highlightID: highlightID)
  }
  var hasOpenDetailRoot: Bool { detailPost != nil }
}

extension SettingsNav {
  /// Settings deep links select sidebar panels (or push reddit links into the detail).
  func consumeDeepLink(path: [NavDest]) {
    for destination in path {
      if case .setting(let setting) = destination {
        select(setting)
      } else {
        pushDetail(destination)
      }
    }
  }
}

/// Consumes deep links delivered on the legacy `Router` (`Nav.to` / contextual /
/// shortcuts) as a write-only inbox: translate into the surface model, then clear
/// the Router so it no longer drives the surface. Replaces the hand-rolled
/// consume/onChange copies that lived in each surface.
private struct RouterDeepLinkInboxModifier: ViewModifier {
  @ObservedObject var router: Router
  let consume: ([NavDest]) -> Void
  let onRootReset: () -> Void

  func body(content: Content) -> some View {
    content
      .onAppear {
        consumeContextual()
        consumePath(router.fullPath)
      }
      .onChange(of: router.contextualDestination) { _, _ in consumeContextual() }
      .onChange(of: router.fullPath) { _, path in consumePath(path) }
      .onChange(of: router.rootResetToken) { _, _ in onRootReset() }
  }

  private func consumeContextual() {
    guard let destination = router.contextualDestination else { return }
    router.contextualDestination = nil
    consume([destination])
  }

  private func consumePath(_ path: [NavDest]) {
    guard !path.isEmpty else { return }
    consume(path)
    router.resetNavPath()
  }
}

extension View {
  func routerDeepLinkInbox(
    router: Router,
    consume: @escaping ([NavDest]) -> Void,
    onRootReset: @escaping () -> Void
  ) -> some View {
    modifier(RouterDeepLinkInboxModifier(router: router, consume: consume, onRootReset: onRootReset))
  }
}
