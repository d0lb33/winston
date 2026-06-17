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
import Foundation
import SwiftUI
@testable import winston

// MARK: - Apollo read history import

struct ApolloReadHistoryImporterTests {
  @Test("preferences plist parser extracts normalized unique read post IDs")
  func preferencesParserExtractsNormalizedUniqueIDs() throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: [
        "ReadPostIDs": [
          " T3_ABC123 ",
          "abc123",
          "Bad-ID",
          "",
          "__1ReADO4",
          "WIO7BO"
        ]
      ],
      format: .binary,
      options: 0
    )

    let result = try ApolloReadHistoryImporter.parseReadPostIDs(fromPreferencesData: data)

    #expect(result.rawCount == 6)
    #expect(result.postIDs == ["abc123", "1reado4", "wio7bo"])
    #expect(result.validUniqueCount == 3)
    #expect(result.invalidCount == 2)
  }

  @Test("preferences plist parser reports missing ReadPostIDs")
  func preferencesParserReportsMissingReadPostIDs() throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["OtherKey": true],
      format: .binary,
      options: 0
    )

    do {
      _ = try ApolloReadHistoryImporter.parseReadPostIDs(fromPreferencesData: data)
      Issue.record("Expected missingReadPostIDs")
    } catch ApolloReadHistoryImportError.missingReadPostIDs {
      #expect(true)
    } catch {
      Issue.record("Expected missingReadPostIDs, got \(error)")
    }
  }

  @Test("preferences plist parser reports non-string ReadPostIDs")
  func preferencesParserReportsInvalidReadPostIDs() throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["ReadPostIDs": [1, 2, 3]],
      format: .binary,
      options: 0
    )

    do {
      _ = try ApolloReadHistoryImporter.parseReadPostIDs(fromPreferencesData: data)
      Issue.record("Expected invalidReadPostIDs")
    } catch ApolloReadHistoryImportError.invalidReadPostIDs {
      #expect(true)
    } catch {
      Issue.record("Expected invalidReadPostIDs, got \(error)")
    }
  }
}

// MARK: - Aurora sidebar communities

struct AuroraSidebarCommunitySortTests {
  @Test("community sort key normalizes display name")
  func communitySortKeyNormalizesDisplayName() {
    let key = AuroraSidebarCommunitySort.sortKey(displayName: "  R/Swift  ", name: nil, uuid: nil)

    #expect(key == "swift")
  }

  @Test("community sort key falls back to name then uuid")
  func communitySortKeyFallsBackToNameThenUUID() {
    #expect(AuroraSidebarCommunitySort.sortKey(displayName: nil, name: "r/Apple", uuid: "t5_apple") == "apple")
    #expect(AuroraSidebarCommunitySort.sortKey(displayName: "", name: nil, uuid: "t5_swift") == "t5_swift")
  }

  @Test("community sort orders alphabetically with uuid tie breaker")
  func communitySortOrdersAlphabeticallyWithTieBreaker() {
    let communities: [(displayName: String?, name: String?, uuid: String?)] = [
      ("r/swift", nil, "t5_swift_b"),
      ("r/apple", nil, "t5_apple"),
      ("Swift", nil, "t5_swift_a")
    ]

    let sorted = communities.sorted {
      AuroraSidebarCommunitySort.precedes(
        lhsDisplayName: $0.displayName,
        lhsName: $0.name,
        lhsUUID: $0.uuid,
        rhsDisplayName: $1.displayName,
        rhsName: $1.name,
        rhsUUID: $1.uuid
      )
    }

    #expect(sorted.map { $0.uuid } == ["t5_apple", "t5_swift_a", "t5_swift_b"])
  }
}

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

// MARK: - AppNav facade bridge

@MainActor
struct AppNavBridgeTests {
  @Test("Posts tab-root reset preserves selected feed and scroll position")
  func postsTabRootPreservesFeedContext() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.posts.community = "swift"
    appNav.posts.feedScrollPositionID = "post-near-top"
    appNav.posts.contentPath = [.reddit(.user(User(id: "alice")))]
    appNav.posts.openPostInDetail(Post(id: "p1"))
    appNav.posts.navigate(.reddit(.subFeed(Subreddit(id: "ios"))), from: .detail)

    appNav.resetToTabRoot(.posts)

    #expect(appNav.posts.community == "swift")
    #expect(appNav.posts.feedScrollPositionID == "post-near-top")
    #expect(appNav.posts.selectedPostID == nil)
    #expect(appNav.posts.detailPost == nil)
    #expect(appNav.posts.detailHighlightID == nil)
    #expect(appNav.posts.contentPath.isEmpty)
    #expect(appNav.posts.detailPath.isEmpty)
    #expect(appNav.posts.preferredColumn == .content)
  }

  @Test("Posts tab-root reset shows sidebar when no feed is selected")
  func postsTabRootShowsSidebarWhenNoFeedSelected() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.posts.community = nil
    appNav.posts.openPostInDetail(Post(id: "p1"))

    appNav.resetToTabRoot(.posts)

    #expect(appNav.posts.community == nil)
    #expect(appNav.posts.preferredColumn == .sidebar)
    #expect(appNav.posts.detailPost == nil)
    #expect(appNav.posts.contentPath.isEmpty)
    #expect(appNav.posts.detailPath.isEmpty)
  }

  @Test("Column tab-root reset clears source and detail navigation")
  func columnTabRootClearsSourceAndDetailNavigation() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.search.contentPath = [.reddit(.user(User(id: "alice")))]
    appNav.search.openPostInDetail(Post(id: "p1"), highlightID: "c1")
    appNav.search.navigate(.reddit(.subFeed(Subreddit(id: "swift"))), from: .detail)

    appNav.resetToTabRoot(.search)

    #expect(appNav.search.contentPath.isEmpty)
    #expect(appNav.search.detailPath.isEmpty)
    #expect(appNav.search.detailPost == nil)
    #expect(appNav.search.detailHighlightID == nil)
    #expect(appNav.search.preferredColumn == .sidebar)
  }

  @Test("Inbox tab-root reset clears stack")
  func inboxTabRootClearsStack() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.inbox.path = [.reddit(.user(User(id: "alice"))), .reddit(.post(Post(id: "p1")))]

    appNav.resetToTabRoot(.inbox)

    #expect(appNav.inbox.path.isEmpty)
  }

  @Test("Settings tab-root reset returns to General")
  func settingsTabRootReturnsToGeneral() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.settings.select(.postSwipe)
    appNav.settings.pushDetail(.reddit(.user(User(id: "alice"))))

    appNav.resetToTabRoot(.settings)

    #expect(appNav.settings.selection == .general)
    #expect(appNav.settings.contentPath.isEmpty)
    #expect(appNav.settings.detailPath.isEmpty)
    #expect(appNav.settings.preferredColumn == .sidebar)
  }

  @Test("canResetSelectedSurfaceToTabRoot follows selected tab state")
  func canResetSelectedSurfaceToTabRootFollowsSelectedTab() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.selectedTab = .me

    #expect(!appNav.canResetSelectedSurfaceToTabRoot)
    appNav.me.contentPath = [.reddit(.user(User(id: "alice")))]
    #expect(appNav.canResetSelectedSurfaceToTabRoot)
  }

  @Test("resetAccountScopedSurfaces clears account tabs and preserves Settings")
  func resetAccountScopedSurfaces() {
    let appNav = AppNav.shared
    appNav.resetAll()

    appNav.posts.openPostInDetail(Post(id: "p1"))
    appNav.me.openPostInDetail(Post(id: "p2"))
    appNav.search.contentPath = [.reddit(.user(User(id: "alice")))]
    appNav.inbox.path = [.reddit(.post(Post(id: "p3")))]
    appNav.settings.select(.appearance)
    appNav.selectedTab = .settings

    appNav.resetAccountScopedSurfaces()

    #expect(appNav.posts.detailPost == nil)
    #expect(appNav.me.detailPost == nil)
    #expect(appNav.search.contentPath.isEmpty)
    #expect(appNav.inbox.path.isEmpty)
    #expect(appNav.settings.selection == .appearance)
    #expect(appNav.selectedTab == .settings)
  }

  @Test("Nav.to routes into the selected AppNav surface")
  func navToRoutesIntoSelectedSurface() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.selectedTab = .search

    let post = Post(id: "p1")
    Nav.to(.reddit(.post(post)))

    #expect(appNav.selectedTab == .search)
    #expect(appNav.search.detailPost === post)
    #expect(appNav.search.preferredColumn == .detail)
  }

  @Test("Nav.fullTo selects a tab and routes into its AppNav surface")
  func navFullToSelectsAndRoutes() {
    let appNav = AppNav.shared
    appNav.resetAll()

    Nav.fullTo(.inbox, .reddit(.user(User(id: "alice"))), false)

    #expect(appNav.selectedTab == .inbox)
    #expect(appNav.inbox.path.count == 1)
    guard case .reddit(.user) = appNav.inbox.path[0] else {
      Issue.record("expected user destination in inbox path")
      return
    }
  }

  @Test("Nav.back delegates to the selected AppNav surface")
  func navBackDelegatesToSelectedSurface() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.selectedTab = .me
    appNav.me.contentPath = [.reddit(.user(User(id: "alice")))]

    Nav.back()

    #expect(appNav.me.contentPath.isEmpty)
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
