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
  }

  @Test("a user pushed from the detail column appends to detailPath")
  func detailUserPushAppendsToDetailPath() {
    let nav = PostsNav()
    nav.selectFeedPost(Post(id: "p1"))

    nav.navigate(.reddit(.user(User(id: "alice"))), from: .detail)

    #expect(nav.detailPath.count == 1)
    #expect(nav.contentPath.isEmpty)
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
  }

  @Test("back pops detailPath → open post → contentPath → feed root, in order")
  func backOrdering() {
    let nav = PostsNav()
    nav.scope = .popular
    nav.navigate(.reddit(.subFeed(Subreddit(id: "swift"))), from: .content) // contentPath = 1
    nav.selectFeedPost(Post(id: "p1"))                                       // open post
    nav.navigate(.reddit(.user(User(id: "alice"))), from: .detail)          // detailPath = 1

    #expect(nav.goBackOneStep())          // pop detailPath
    #expect(nav.detailPath.isEmpty)
    #expect(nav.detailPost != nil)

    #expect(nav.goBackOneStep())          // clear the open post
    #expect(nav.detailPost == nil)
    #expect(nav.contentPath.count == 1)

    #expect(nav.goBackOneStep())          // pop contentPath
    #expect(nav.contentPath.isEmpty)

    #expect(!nav.goBackOneStep())         // at the feed root — nothing left
    #expect(nav.scope == .popular)        // the feed scope is preserved
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
  }

  @Test("compactPath projects content + open post + detail pushes, and decomposes on pop")
  func compactPathProjectionRoundTrips() {
    let nav = PostsNav()
    nav.scope = .popular
    nav.navigate(.reddit(.subFeed(Subreddit(id: "swift"))), from: .content) // content push
    nav.selectFeedPost(Post(id: "p1"))                                       // open post
    nav.navigate(.reddit(.user(User(id: "alice"))), from: .detail)          // detail push

    #expect(nav.compactPath.count == 3) // [sub, post, user]

    // Pop the detail push (system back gesture shrinks the path).
    nav.compactPath = Array(nav.compactPath.dropLast())
    #expect(nav.detailPath.isEmpty)
    #expect(nav.detailPost != nil)
    #expect(nav.contentPath.count == 1)

    // Pop the open post.
    nav.compactPath = Array(nav.compactPath.dropLast())
    #expect(nav.detailPost == nil)
    #expect(nav.selectedPostID == nil)
    #expect(nav.contentPath.count == 1)

    // Pop the content push → back at the feed root.
    nav.compactPath = []
    #expect(nav.contentPath.isEmpty)
    #expect(nav.scope == .popular)
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

@Suite(.serialized)
@MainActor
struct AppNavBridgeTests {
  @Test("Posts tab-root reset preserves the feed scope and scroll position")
  func postsTabRootPreservesFeedContext() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.posts.scope = .subreddit(id: "swift")
    appNav.posts.feedScrollPositionID = "post-near-top"
    appNav.posts.contentPath = [.reddit(.user(User(id: "alice")))]
    appNav.posts.openPostInDetail(Post(id: "p1"))
    appNav.posts.navigate(.reddit(.subFeed(Subreddit(id: "ios"))), from: .detail)

    appNav.resetToTabRoot(.posts)

    #expect(appNav.posts.scope == .subreddit(id: "swift"))
    #expect(appNav.posts.feedScrollPositionID == "post-near-top")
    #expect(appNav.posts.selectedPostID == nil)
    #expect(appNav.posts.detailPost == nil)
    #expect(appNav.posts.detailHighlightID == nil)
    #expect(appNav.posts.contentPath.isEmpty)
    #expect(appNav.posts.detailPath.isEmpty)
  }

  @Test("Posts tab-root reset clears the open post but keeps the feed scope")
  func postsTabRootClearsPostKeepsScope() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.posts.scope = .home
    appNav.posts.openPostInDetail(Post(id: "p1"))

    appNav.resetToTabRoot(.posts)

    #expect(appNav.posts.scope == .home)
    #expect(appNav.posts.detailPost == nil)
    #expect(appNav.posts.contentPath.isEmpty)
    #expect(appNav.posts.detailPath.isEmpty)
    #expect(!appNav.canResetToTabRoot(.posts))
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

  @Test("Settings tab-root reset returns to the sidebar panel list (no selection)")
  func settingsTabRootReturnsToSidebar() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.settings.select(.postSwipe)
    appNav.settings.pushDetail(.reddit(.user(User(id: "alice"))))

    appNav.resetToTabRoot(.settings)

    // nil selection (not .general) is what reliably collapses the compact split to the
    // sidebar — a non-nil selection re-pushes the detail past the native reselect-pop.
    #expect(appNav.settings.selection == nil)
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

  @Test("Copied Reddit comment URL routes directly into Posts AppNav detail")
  func copiedRedditCommentURLRoutesIntoPostsDetail() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.selectedTab = .settings
    appNav.settings.select(.behavior)

    let opened = openParsedRedditURL(
      parseRedditURL("https://www.reddit.com/r/swift/comments/copiedpost123/navigation_regression/copiedcomment456/")
    )

    #expect(opened)
    #expect(appNav.selectedTab == .posts)
    #expect(appNav.posts.detailPost?.id == "copiedpost123")
    #expect(appNav.posts.detailHighlightID == "copiedcomment456")
    #expect(appNav.settings.selection == .behavior)
  }

  @Test("Posts compact detail scrolled returns surface scroll detail")
  func postsCompactDetailScrolledReturnsScrollDetail() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.posts.openPostInDetail(Post(id: "p1"))
    appNav.posts.tabInteractionState = PostsTabInteractionState(
      layout: .compact,
      contentCanScrollToTop: false,
      detailCanScrollToTop: true
    )

    #expect(appNav.handleTabReselect(.posts, tap: .single) == .surface(.scrollDetailToTop))
  }

  @Test("Posts compact detail at top returns detail back")
  func postsCompactDetailAtTopReturnsDetailBack() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.posts.openPostInDetail(Post(id: "p1"))
    appNav.posts.navigate(.reddit(.user(User(id: "author"))), from: .detail)
    appNav.posts.tabInteractionState = PostsTabInteractionState(layout: .compact)

    #expect(appNav.handleTabReselect(.posts, tap: .single) == .navigation(.backOneStep(.detail)))
  }

  @Test("Posts compact feed root single-tap is a no-op (scope picker reaches the list)")
  func postsCompactFeedRootIsNoop() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.posts.tabInteractionState = PostsTabInteractionState(layout: .compact)

    #expect(appNav.handleTabReselect(.posts, tap: .single) == .none)
  }

  @Test("Posts compact single-tap peels detail → content → feed root, one level per tap")
  func postsCompactWalkBackPeelsOneLevelPerTap() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.posts.scope = .popular
    appNav.posts.navigate(.reddit(.subFeed(Subreddit(id: "swift"))), from: .content) // contentPath = 1
    appNav.posts.selectFeedPost(Post(id: "p1"))                                       // open post
    appNav.posts.navigate(.reddit(.user(User(id: "author"))), from: .detail)          // detailPath = 1
    appNav.posts.tabInteractionState = PostsTabInteractionState(layout: .compact)

    // 1. pop the author off the detail stack
    var action = appNav.handleTabReselect(.posts, tap: .single)
    #expect(action == .navigation(.backOneStep(.detail)))
    TabReselectActionExecutor.execute(action, for: .posts, appNav: appNav)
    #expect(appNav.posts.detailPath.isEmpty)
    #expect(appNav.posts.detailPost != nil)

    // 2. clear the open post → back to the pushed sub-feed (still the content surface)
    action = appNav.handleTabReselect(.posts, tap: .single)
    #expect(action == .navigation(.backOneStep(.detail)))
    TabReselectActionExecutor.execute(action, for: .posts, appNav: appNav)
    #expect(appNav.posts.detailPost == nil)

    // 3. pop the pushed sub-feed → back to the Popular feed root
    action = appNav.handleTabReselect(.posts, tap: .single)
    #expect(action == .navigation(.backOneStep(.content)))
    TabReselectActionExecutor.execute(action, for: .posts, appNav: appNav)
    #expect(appNav.posts.contentPath.isEmpty)

    // 4. at the feed root → nothing left (the scope picker reaches the subreddit list)
    #expect(appNav.handleTabReselect(.posts, tap: .single) == .none)
    #expect(appNav.posts.scope == .popular)
  }

  @Test("Posts compact scrolled feed scrolls to top before anything else")
  func postsCompactScrolledFeedScrollsFirst() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.posts.scope = .popular
    appNav.posts.tabInteractionState = PostsTabInteractionState(
      layout: .compact,
      contentCanScrollToTop: true
    )

    #expect(appNav.handleTabReselect(.posts, tap: .single) == .surface(.scrollContentToTop))
  }

  @Test("Posts regular feed scroll wins before detail")
  func postsRegularFeedScrollWinsBeforeDetail() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.posts.openPostInDetail(Post(id: "p1"))
    appNav.posts.navigate(.reddit(.user(User(id: "author"))), from: .detail)
    appNav.posts.tabInteractionState = PostsTabInteractionState(
      layout: .regular,
      contentCanScrollToTop: true,
      detailCanScrollToTop: true
    )

    #expect(appNav.handleTabReselect(.posts, tap: .single) == .surface(.scrollContentToTop))
  }

  @Test("Posts regular detail scroll wins before detail back")
  func postsRegularDetailScrollWinsBeforeDetailBack() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.posts.openPostInDetail(Post(id: "p1"))
    appNav.posts.navigate(.reddit(.user(User(id: "author"))), from: .detail)
    appNav.posts.tabInteractionState = PostsTabInteractionState(
      layout: .regular,
      contentCanScrollToTop: false,
      detailCanScrollToTop: true
    )

    #expect(appNav.handleTabReselect(.posts, tap: .single) == .surface(.scrollDetailToTop))
  }

  @Test("Posts regular detail back is chosen before content back")
  func postsRegularDetailBackBeforeContentBack() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.posts.contentPath = [.reddit(.user(User(id: "source")))]
    appNav.posts.openPostInDetail(Post(id: "p1"))
    appNav.posts.navigate(.reddit(.user(User(id: "author"))), from: .detail)
    appNav.posts.tabInteractionState = PostsTabInteractionState(layout: .regular)

    let first = appNav.handleTabReselect(.posts, tap: .single)
    #expect(first == .navigation(.backOneStep(.detail)))
    TabReselectActionExecutor.execute(first, for: .posts, appNav: appNav)

    let second = appNav.handleTabReselect(.posts, tap: .single)
    #expect(second == .navigation(.backOneStep(.detail)))
    TabReselectActionExecutor.execute(second, for: .posts, appNav: appNav)

    #expect(appNav.handleTabReselect(.posts, tap: .single) == .navigation(.backOneStep(.content)))
  }

  @Test("Posts double tap resets a dirty surface to the feed root")
  func postsDoubleTapResetsToFeedRoot() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.posts.openPostInDetail(Post(id: "p1"))

    #expect(appNav.handleTabReselect(.posts, tap: .double) == .resetToTabRoot)
  }

  @Test("Double tap after an immediate single still ends at the feed root")
  func doubleTapAfterImmediateSingleEndsAtFeedRoot() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.posts.scope = .subreddit(id: "swift")
    appNav.posts.openPostInDetail(Post(id: "p1"))
    appNav.posts.navigate(.reddit(.user(User(id: "author"))), from: .detail)
    appNav.posts.tabInteractionState = PostsTabInteractionState(layout: .compact)

    let single = appNav.handleTabReselect(.posts, tap: .single)
    #expect(single == .navigation(.backOneStep(.detail)))
    TabReselectActionExecutor.execute(single, for: .posts, appNav: appNav)
    #expect(appNav.posts.detailPath.isEmpty)
    #expect(appNav.posts.detailPost != nil)

    let double = appNav.handleTabReselect(.posts, tap: .double)
    #expect(double == .resetToTabRoot)
    TabReselectActionExecutor.execute(double, for: .posts, appNav: appNav)

    // Reset clears the open post but keeps the feed scope (the subreddit list is a tap away).
    #expect(appNav.posts.scope == .subreddit(id: "swift"))
    #expect(appNav.posts.detailPost == nil)
    #expect(appNav.posts.detailPath.isEmpty)
  }

  @Test("Non-Posts tab reselect returns reset only when dirty")
  func nonPostsTabReselectReturnsResetOnlyWhenDirty() {
    let appNav = AppNav.shared
    appNav.resetAll()

    #expect(appNav.handleTabReselect(.search, tap: .single) == .none)

    appNav.search.contentPath = [.reddit(.user(User(id: "alice")))]

    #expect(appNav.handleTabReselect(.search, tap: .single) == .resetToTabRoot)
  }
}

struct TabTapClassifierTests {
  private final class EventToken {}

  @Test("duplicate callbacks for one physical tap emit one single")
  func duplicateCallbacksForOnePhysicalTapEmitOneSingle() {
    var classifier = TabTapClassifier()
    let token = EventToken()
    let eventID = ObjectIdentifier(token)

    #expect(classifier.classify(tab: .posts, eventID: eventID, time: 10) == .single)
    #expect(classifier.classify(tab: .posts, eventID: eventID, time: 10.01) == nil)
  }

  @Test("two physical taps inside interval emit single then double")
  func twoPhysicalTapsInsideIntervalEmitSingleThenDouble() {
    var classifier = TabTapClassifier()

    #expect(classifier.classify(tab: .posts, eventID: nil, time: 10) == .single)
    #expect(classifier.classify(tab: .posts, eventID: nil, time: 10.2) == .double)
  }

  @Test("two physical taps outside interval emit two singles")
  func twoPhysicalTapsOutsideIntervalEmitTwoSingles() {
    var classifier = TabTapClassifier()

    #expect(classifier.classify(tab: .posts, eventID: nil, time: 10) == .single)
    #expect(classifier.classify(tab: .posts, eventID: nil, time: 11) == .single)
  }

  @Test("switching tabs resets double tap pairing")
  func switchingTabsResetsDoubleTapPairing() {
    var classifier = TabTapClassifier()

    #expect(classifier.classify(tab: .posts, eventID: nil, time: 10) == .single)
    #expect(classifier.classify(tab: .search, eventID: nil, time: 10.2) == .single)
    #expect(classifier.classify(tab: .posts, eventID: nil, time: 10.4) == .single)
  }
}

// MARK: - Navigation E2E scenarios

@MainActor
@Suite(.serialized)
struct NavigationScenarioTests {
  @Test("Posts journey: Popular feed scroll → post → subreddit/user pushes → same-tab root")
  func postsPopularJourneyReturnsToFeedRootWithoutLosingContext() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.selectedTab = .posts

    let popularPost = Post(id: "popular-post-4")
    appNav.posts.scope = .popular
    appNav.posts.feedScrollPositionID = "popular-post-8"
    appNav.posts.selectedPostID = popularPost.id
    appNav.posts.selectFeedPost(popularPost)

    appNav.posts.navigate(.reddit(.subFeed(Subreddit(id: "swift"))), from: .detail)
    appNav.posts.navigate(.reddit(.user(User(id: "alice"))), from: .detail)

    appNav.resetSelectedSurfaceToTabRoot()

    #expect(appNav.selectedTab == .posts)
    #expect(appNav.posts.scope == .popular)
    #expect(appNav.posts.feedScrollPositionID == "popular-post-8")
    #expect(appNav.posts.selectedPostID == nil)
    #expect(appNav.posts.detailPost == nil)
    #expect(appNav.posts.detailPath.isEmpty)
    #expect(appNav.posts.contentPath.isEmpty)
    #expect(!appNav.canResetSelectedSurfaceToTabRoot)
  }

  @Test("Posts journey: community feed keeps its scope on same-tab reset")
  func postsCommunityJourneyReturnsToCurrentSubredditRoot() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.selectedTab = .posts

    let swiftPost = Post(id: "swift-post-2")
    appNav.posts.scope = .subreddit(id: "swift")
    appNav.posts.feedScrollPositionID = "swift-post-12"
    appNav.posts.contentPath = [.reddit(.user(User(id: "source-profile")))]
    appNav.posts.selectedPostID = swiftPost.id
    appNav.posts.selectFeedPost(swiftPost)
    appNav.posts.navigate(.reddit(.user(User(id: "post-author"))), from: .detail)

    appNav.resetToTabRoot(.posts)

    #expect(appNav.posts.scope == .subreddit(id: "swift"))
    #expect(appNav.posts.feedScrollPositionID == "swift-post-12")
    #expect(appNav.posts.contentPath.isEmpty)
    #expect(appNav.posts.detailPath.isEmpty)
    #expect(appNav.posts.detailPost == nil)
  }

  @Test("Posts journey: a deep-linked post resets to the feed root, keeping scope")
  func postsDeepLinkedPostResetsToFeedRoot() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.selectedTab = .posts

    appNav.posts.scope = .home
    appNav.posts.openPostInDetail(Post(id: "deep-linked-post"))

    appNav.resetSelectedSurfaceToTabRoot()

    #expect(appNav.posts.scope == .home)
    #expect(appNav.posts.detailPost == nil)
    #expect(!appNav.canResetSelectedSurfaceToTabRoot)
  }

  @Test("Same-tab root reset clears a deep tab in one atomic jump")
  func sameTabRootResetDoesNotWalkBackOneRouteAtATime() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.selectedTab = .posts

    appNav.posts.scope = .popular
    appNav.posts.contentPath = [.reddit(.subFeed(Subreddit(id: "swift")))]
    appNav.posts.openPostInDetail(Post(id: "popular-post-1"))
    appNav.posts.detailPath = [
      .reddit(.user(User(id: "author"))),
      .reddit(.subFeed(Subreddit(id: "ios")))
    ]

    appNav.resetSelectedSurfaceToTabRoot()

    #expect(appNav.posts.contentPath.isEmpty)
    #expect(appNav.posts.detailPath.isEmpty)
    #expect(appNav.posts.detailPost == nil)
    #expect(appNav.posts.scope == .popular)

    appNav.resetSelectedSurfaceToTabRoot()

    #expect(appNav.posts.contentPath.isEmpty)
    #expect(appNav.posts.detailPath.isEmpty)
    #expect(appNav.posts.detailPost == nil)
    #expect(appNav.posts.scope == .popular)
  }

  @Test("Switching tabs preserves each tab stack until that tab is explicitly rooted")
  func tabStacksAreIsolatedUntilTheirOwnRootReset() {
    let appNav = AppNav.shared
    appNav.resetAll()

    appNav.posts.openPostInDetail(Post(id: "p-post"))
    appNav.inbox.path = [.reddit(.post(Post(id: "inbox-post")))]
    appNav.me.contentPath = [.reddit(.user(User(id: "me-push")))]
    appNav.search.openPostInDetail(Post(id: "search-post"))
    appNav.settings.select(.postSwipe)

    appNav.selectedTab = .me
    appNav.resetSelectedSurfaceToTabRoot()

    #expect(appNav.me.contentPath.isEmpty)
    #expect(appNav.posts.detailPost != nil)
    #expect(appNav.inbox.path.count == 1)
    #expect(appNav.search.detailPost != nil)
    #expect(appNav.settings.selection == .behavior)

    appNav.selectedTab = .inbox
    appNav.resetSelectedSurfaceToTabRoot()

    #expect(appNav.inbox.path.isEmpty)
    #expect(appNav.posts.detailPost != nil)
    #expect(appNav.search.detailPost != nil)
    #expect(appNav.settings.selection == .behavior)
  }

  @Test("Search tab journey clears source and detail stacks at tab root")
  func searchJourneyRootsToSearchSurface() {
    let appNav = AppNav.shared
    appNav.resetAll()
    appNav.selectedTab = .search

    appNav.search.contentPath = [.reddit(.subFeed(Subreddit(id: "swift")))]
    appNav.search.openPostInDetail(Post(id: "search-result-post"), highlightID: "comment-1")
    appNav.search.navigate(.reddit(.user(User(id: "comment-author"))), from: .detail)

    appNav.resetSelectedSurfaceToTabRoot()

    #expect(appNav.search.contentPath.isEmpty)
    #expect(appNav.search.detailPath.isEmpty)
    #expect(appNav.search.detailPost == nil)
    #expect(appNav.search.detailHighlightID == nil)
    #expect(appNav.search.preferredColumn == .sidebar)
  }

  @Test("Me, Inbox, and Settings each root to their expected tab surfaces")
  func secondaryTabsRootToExpectedSurfaces() {
    let appNav = AppNav.shared
    appNav.resetAll()

    appNav.selectedTab = .me
    appNav.me.contentPath = [.reddit(.user(User(id: "nested-user")))]
    appNav.me.openPostInDetail(Post(id: "profile-post"))
    appNav.resetSelectedSurfaceToTabRoot()
    #expect(appNav.me.contentPath.isEmpty)
    #expect(appNav.me.detailPost == nil)
    #expect(appNav.me.preferredColumn == .sidebar)

    appNav.selectedTab = .inbox
    appNav.inbox.path = [.reddit(.post(Post(id: "message-post"))), .reddit(.user(User(id: "sender")))]
    appNav.resetSelectedSurfaceToTabRoot()
    #expect(appNav.inbox.path.isEmpty)

    appNav.selectedTab = .settings
    appNav.settings.select(.commentSwipe)
    appNav.settings.pushDetail(.reddit(.subFeed(Subreddit(id: "winstonapp"))))
    appNav.resetSelectedSurfaceToTabRoot()
    #expect(appNav.settings.selection == nil)
    #expect(appNav.settings.detailPath.isEmpty)
    #expect(appNav.settings.preferredColumn == .sidebar)
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
