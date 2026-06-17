//
//  NavigationModelTests.swift
//  winstonTests
//
//  Pure-model transition tests for the native navigation models in
//  Navigation/AppNav.swift. These pin the routing invariants the navigation
//  rebuild depends on (content vs. detail origin, detail-root vs. push, back
//  ordering) so every later refactor phase has a regression net. No SwiftUI /
//  app environment is required — the models are plain @Observable @MainActor
//  state machines, so we instantiate and assert.
//

import Testing
import SwiftUI
@testable import winston

// MARK: - PostsNav (three-column: communities | feed | post+comments)

@MainActor
struct PostsNavTests {
  @Test("content post-open sets the detail root and clears the detail path")
  func contentPostOpenSetsDetailRoot() {
    let nav = PostsNav()
    nav.selectedPostID = "stale"
    nav.detailPath = [.reddit(.user(User(id: "pre")))]

    let post = Post(id: "p1")
    nav.navigate(.reddit(.post(post)), from: .content)

    #expect(nav.detailPost === post)
    #expect(nav.detailPath.isEmpty)
    #expect(nav.selectedPostID == nil)
    #expect(nav.preferredColumn == .detail)
  }

  @Test("a user pushed from the detail column appends to detailPath")
  func detailUserPushAppendsToDetailPath() {
    let nav = PostsNav()
    nav.selectFeedPost(Post(id: "p1"))

    nav.navigate(.reddit(.user(User(id: "alice"))), from: .detail)

    #expect(nav.detailPath.count == 1)
    #expect(nav.contentPath.isEmpty)
    #expect(nav.preferredColumn == .detail)
  }

  @Test("Post → User → Subreddit from the detail preserves order in detailPath")
  func detailChainPreservesOrder() {
    let nav = PostsNav()
    nav.selectFeedPost(Post(id: "p1"))
    nav.navigate(.reddit(.user(User(id: "alice"))), from: .detail)
    nav.navigate(.reddit(.subFeed(Subreddit(id: "swift"))), from: .detail)

    #expect(nav.detailPath.count == 2)
    guard case .reddit(.user) = nav.detailPath[0] else {
      Issue.record("expected user at detailPath[0], got \(nav.detailPath[0])"); return
    }
    guard case .reddit(.subFeed) = nav.detailPath[1] else {
      Issue.record("expected subFeed at detailPath[1], got \(nav.detailPath[1])"); return
    }
  }

  @Test("content sub/user pushes content, never detail")
  func contentPushGoesToContentPath() {
    let nav = PostsNav()

    nav.navigate(.reddit(.subFeed(Subreddit(id: "swift"))), from: .content)
    nav.navigate(.reddit(.user(User(id: "alice"))), from: .content)

    #expect(nav.contentPath.count == 2)
    #expect(nav.detailPath.isEmpty)
    #expect(nav.detailPost == nil)
    #expect(nav.preferredColumn == .content)
  }

  @Test("back pops detailPath → detail root → contentPath → sidebar, in order")
  func backOrdering() {
    let nav = PostsNav()
    nav.community = "popular"
    nav.navigate(.reddit(.subFeed(Subreddit(id: "swift"))), from: .content) // contentPath = 1
    nav.selectFeedPost(Post(id: "p1"))                                       // detail root
    nav.navigate(.reddit(.user(User(id: "alice"))), from: .detail)          // detailPath = 1

    #expect(nav.goBackOneStep())          // pop detailPath
    #expect(nav.detailPath.isEmpty)
    #expect(nav.detailPost != nil)

    #expect(nav.goBackOneStep())          // clear detail root
    #expect(nav.detailPost == nil)
    #expect(nav.preferredColumn == .content)
    #expect(nav.contentPath.count == 1)

    #expect(nav.goBackOneStep())          // pop contentPath
    #expect(nav.contentPath.isEmpty)

    #expect(nav.goBackOneStep())          // collapse to sidebar
    #expect(nav.preferredColumn == .sidebar)
  }

  @Test("openPostInDetail (deep link / saved) clears the feed-list selection")
  func openPostInDetailClearsSelection() {
    let nav = PostsNav()
    nav.selectedPostID = "fromFeed"

    nav.openPostInDetail(Post(id: "p1"), highlightID: "c1")

    #expect(nav.selectedPostID == nil)
    #expect(nav.detailPost != nil)
    #expect(nav.detailHighlightID == "c1")
    #expect(nav.detailPath.isEmpty)
    #expect(nav.preferredColumn == .detail)
  }
}

// MARK: - ColumnNav (two-column: source | detail)

@MainActor
struct ColumnNavTests {
  @Test("defaults to the leading source column")
  func defaultsToSidebar() {
    #expect(ColumnNav().preferredColumn == .sidebar)
  }

  @Test("content post-open opens the detail; content non-post pushes the source")
  func contentRouting() {
    let nav = ColumnNav()

    nav.navigate(.reddit(.subFeed(Subreddit(id: "swift"))), from: .content)
    #expect(nav.contentPath.count == 1)
    #expect(nav.preferredColumn == .sidebar)

    let post = Post(id: "p1")
    nav.navigate(.reddit(.post(post)), from: .content)
    #expect(nav.detailPost === post)
    #expect(nav.preferredColumn == .detail)
  }

  @Test("a destination pushed from the detail appends to detailPath")
  func detailPushAppends() {
    let nav = ColumnNav()
    nav.openPostInDetail(Post(id: "p1"))
    nav.navigate(.reddit(.user(User(id: "alice"))), from: .detail)
    #expect(nav.detailPath.count == 1)
    #expect(nav.preferredColumn == .detail)
  }

  @Test("back pops detailPath → detail root → contentPath → sidebar")
  func backOrdering() {
    let nav = ColumnNav()
    nav.navigate(.reddit(.user(User(id: "alice"))), from: .content) // contentPath = 1
    nav.openPostInDetail(Post(id: "p1"))                            // detail root
    nav.navigate(.reddit(.subFeed(Subreddit(id: "swift"))), from: .detail) // detailPath = 1

    #expect(nav.goBackOneStep()); #expect(nav.detailPath.isEmpty); #expect(nav.detailPost != nil)
    #expect(nav.goBackOneStep()); #expect(nav.detailPost == nil); #expect(nav.preferredColumn == .sidebar)
    #expect(nav.goBackOneStep()); #expect(nav.contentPath.isEmpty)
    #expect(!nav.goBackOneStep()) // already at root
  }
}

// MARK: - SettingsNav (sidebar selection | detail)

@MainActor
struct SettingsNavTests {
  @Test("defaults to General")
  func defaultSelection() {
    #expect(SettingsNav().selection == .general)
  }

  @Test("selecting a nested panel collapses to its split root and seeds the detail")
  func selectNestedPanelCollapsesToSplitRoot() {
    let nav = SettingsNav()
    nav.select(.postSwipe)   // belongs to .behavior
    #expect(nav.selection == .behavior)
    #expect(nav.detailPath == [.setting(.postSwipe)])
    #expect(nav.preferredColumn == .detail)
  }

  @Test("selecting a root panel clears the detail stack")
  func selectRootPanelClearsDetail() {
    let nav = SettingsNav()
    nav.select(.postSwipe)
    nav.select(.behavior)
    #expect(nav.selection == .behavior)
    #expect(nav.detailPath.isEmpty)
  }

  @Test("pushDetail appends; back pops the detail then returns to the sidebar root")
  func pushAndBack() {
    let nav = SettingsNav()
    nav.select(.behavior)
    nav.pushDetail(.setting(.commentSwipe))
    #expect(nav.detailPath.count == 1)

    #expect(nav.goBackOneStep()); #expect(nav.detailPath.isEmpty)
    #expect(nav.goBackOneStep()); #expect(nav.selection == .general); #expect(nav.preferredColumn == .sidebar)
  }
}

// MARK: - StackNav (single-stack: Inbox)

@MainActor
struct StackNavTests {
  @Test("push appends, back pops, back on empty returns false, reset clears")
  func pushBackReset() {
    let nav = StackNav()
    #expect(!nav.goBackOneStep())

    nav.path.append(.reddit(.user(User(id: "alice"))))
    nav.path.append(.reddit(.post(Post(id: "p1"))))
    #expect(nav.path.count == 2)

    #expect(nav.goBackOneStep()); #expect(nav.path.count == 1)
    nav.reset()
    #expect(nav.path.isEmpty)
    #expect(!nav.goBackOneStep())
  }

  @Test("navigate pushes onto the single stack regardless of origin")
  func navigatePushesRegardlessOfOrigin() {
    let nav = StackNav()
    nav.navigate(.reddit(.post(Post(id: "p1"))), from: .content)
    nav.navigate(.reddit(.user(User(id: "alice"))), from: .detail)
    #expect(nav.path.count == 2)
  }

  @Test("consumeDeepLink appends a delivered path in order")
  func consumeDeepLinkAppendsInOrder() {
    let nav = StackNav()
    nav.consumeDeepLink(path: [
      .reddit(.post(Post(id: "p1"))),
      .reddit(.user(User(id: "alice")))
    ])
    #expect(nav.path.count == 2)
    guard case .reddit(.post) = nav.path[0] else { Issue.record("expected post first"); return }
    guard case .reddit(.user) = nav.path[1] else { Issue.record("expected user second"); return }
  }
}

// MARK: - TabInteractionCenter

@MainActor
struct TabInteractionCenterTests {
  @Test("scrolled active owner requests scroll to top")
  func scrolledActiveOwnerRequestsScrollToTop() {
    let center = TabInteractionCenter()
    center.activateScrollOwner("posts.feed", for: .posts, initialIsAtTop: false)

    center.selectedTabTappedAgain(.posts)

    #expect(center.requests[.posts]?.kind == .scrollToTop)
  }

  @Test("at-top active owner requests one-step back")
  func atTopActiveOwnerRequestsBack() {
    let center = TabInteractionCenter()
    center.activateScrollOwner("posts.detail.p1", for: .posts, initialIsAtTop: true)

    center.selectedTabTappedAgain(.posts)

    #expect(center.requests[.posts]?.kind == .goBack)
  }

  @Test("hidden owner cannot overwrite active owner top state")
  func hiddenOwnerWritesAreIgnored() {
    let center = TabInteractionCenter()
    center.activateScrollOwner("posts.feed", for: .posts, initialIsAtTop: false)

    center.setIsAtTop(.posts, true, ownerID: "posts.detail.p1")
    center.selectedTabTappedAgain(.posts)

    #expect(center.requests[.posts]?.kind == .scrollToTop)
  }

  @Test("returning from detail uses the feed owner's scroll state")
  func returningFromDetailUsesFeedOwnerState() {
    let center = TabInteractionCenter()
    center.activateScrollOwner("posts.detail.p1", for: .posts, initialIsAtTop: true)
    center.activateScrollOwner("posts.feed", for: .posts, initialIsAtTop: false)

    center.selectedTabTappedAgain(.posts)

    #expect(center.requests[.posts]?.kind == .scrollToTop)
  }

  @Test("second reselect inside double-tap interval resets to root")
  func doubleTapResetsToRoot() async throws {
    let center = TabInteractionCenter()
    center.activateScrollOwner("posts.feed", for: .posts, initialIsAtTop: false)

    center.selectedTabTappedAgain(.posts)
    try await Task.sleep(for: .milliseconds(80))
    center.selectedTabTappedAgain(.posts)

    #expect(center.requests[.posts]?.kind == .resetToRoot)
  }
}

// MARK: - AuroraFeedModel

@MainActor
struct AuroraFeedModelTests {
  @Test("cancelled initial load stays non-terminal")
  func cancelledInitialLoadStaysNonTerminal() async {
    let model = AuroraFeedModel(
      subreddit: Subreddit(id: "FacebookAIslop"),
      pageLoader: { _, _, _, _, _ in .cancelled }
    )

    await model.loadInitialIfNeeded(sort: .hot, contentWidth: 320)

    #expect(model.posts.isEmpty)
    #expect(model.phase == .idle)
    #expect(!model.reachedEnd)
  }

  @Test("stale generation result is ignored")
  func staleGenerationResultIsIgnored() async {
    let model = AuroraFeedModel(
      subreddit: Subreddit(id: "first"),
      pageLoader: { _, _, _, _, _ in
        try? await Task.sleep(nanoseconds: 50_000_000)
        return .success(posts: [Post(id: "late")], after: nil)
      }
    )

    let task = Task { @MainActor in
      await model.loadInitialIfNeeded(sort: .hot, contentWidth: 320)
    }
    while model.phase != .loading {
      await Task.yield()
    }

    model.prepare(for: Subreddit(id: "second"))
    await task.value

    #expect(model.feedIdentity == "second")
    #expect(model.posts.isEmpty)
    #expect(model.phase == .idle)
  }

  @Test("real empty initial load enters empty phase")
  func realEmptyInitialLoadEntersEmptyPhase() async {
    let model = AuroraFeedModel(
      subreddit: Subreddit(id: "empty"),
      pageLoader: { _, _, _, _, _ in .success(posts: [], after: nil) }
    )

    await model.loadInitialIfNeeded(sort: .hot, contentWidth: 320)

    #expect(model.posts.isEmpty)
    #expect(model.phase == .empty)
    #expect(model.reachedEnd)
  }

  @Test("non-empty initial load applies posts")
  func nonEmptyInitialLoadAppliesPosts() async {
    let model = AuroraFeedModel(
      subreddit: Subreddit(id: "swift"),
      pageLoader: { _, _, _, _, _ in .success(posts: [Post(id: "p1")], after: "next") }
    )

    await model.loadInitialIfNeeded(sort: .hot, contentWidth: 320)

    #expect(model.posts.map(\.id) == ["p1"])
    #expect(model.visiblePosts.map(\.id) == ["p1"])
    #expect(model.phase == .loaded)
    #expect(!model.reachedEnd)
  }

  @Test("metadata refresh does not change stable feed identity")
  func metadataRefreshDoesNotChangeStableFeedIdentity() {
    let subreddit = Subreddit(id: "FacebookAIslop")
    let model = AuroraFeedModel(subreddit: subreddit)
    let identity = model.feedIdentity

    var refreshed = SubredditData(id: "bm3ek2")
    refreshed.name = "t5_bm3ek2"
    refreshed.display_name = "FacebookAIslop"
    refreshed.display_name_prefixed = "r/FacebookAIslop"
    subreddit.data = refreshed

    #expect(subreddit.id == "bm3ek2")
    #expect(model.feedIdentity == identity)
  }
}

// MARK: - FeedPaginationCompletion

struct FeedPaginationCompletionTests {
  @Test("cancelled multi-feed load does not reach end")
  func cancelledLoadDoesNotReachEnd() {
    #expect(!FeedPaginationCompletion.reachedEnd(nextAfter: nil, cancelled: true))
  }

  @Test("nil cursor reaches end only after a non-cancelled load")
  func nilCursorReachesEndAfterNonCancelledLoad() {
    #expect(FeedPaginationCompletion.reachedEnd(nextAfter: nil, cancelled: false))
    #expect(!FeedPaginationCompletion.reachedEnd(nextAfter: "next", cancelled: false))
  }
}
