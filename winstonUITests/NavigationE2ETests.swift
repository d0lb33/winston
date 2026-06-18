//
//  NavigationE2ETests.swift
//  winstonUITests
//

import XCTest

final class NavigationE2ETests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    app = XCUIApplication()
    app.launchArguments = ["--winston-navigation-e2e"]
    app.launch()
  }

  override func tearDown() {
    XCUIDevice.shared.orientation = .portrait
    app = nil
    super.tearDown()
  }

  // Compact single-tap reselect: from a pushed feed, scroll the open post to top, then peel
  // back one level per tap (author → post → feed root), and finally pop the feed back to the
  // root scope list — exercising the real reselect wiring + compactPath.
  func testPostsCompactSameTabReselectScrollsThenBacksToFeedRoot() {
    XCTAssertTrue(text("navE2E.posts.rootList").waitForExistence(timeout: 5))
    XCTAssertTrue(bridgeStatusLabel().contains("attached"))

    button("navE2E.posts.pickPopular").tap()
    XCTAssertTrue(text("navE2E.posts.feedRoot").waitForExistence(timeout: 5))

    button("navE2E.posts.openPost").tap()
    XCTAssertTrue(text("navE2E.posts.detailRoot").waitForExistence(timeout: 5))
    button("navE2E.posts.markDetailScrolled").tap()
    button("navE2E.posts.openAuthor").tap()
    XCTAssertTrue(text("navE2E.posts.detailUser").waitForExistence(timeout: 5))

    selectTab("Posts")
    XCTAssertTrue(text("navE2E.lastAction").label.contains("single.surface.scrollDetailToTop"))
    XCTAssertTrue(text("navE2E.posts.detailUser").waitForExistence(timeout: 5))

    waitPastDoubleTapInterval()
    selectTab("Posts")
    XCTAssertTrue(text("navE2E.lastAction").label.contains("single.navigation.backOneStep.detail"))
    XCTAssertTrue(text("navE2E.posts.detailRoot").waitForExistence(timeout: 5))
    XCTAssertFalse(text("navE2E.posts.detailUser").exists)

    waitPastDoubleTapInterval()
    selectTab("Posts")
    XCTAssertTrue(text("navE2E.posts.feedRoot").waitForExistence(timeout: 5))
    XCTAssertTrue(text("navE2E.posts.scrollPosition").label.contains("popular-post-8"))
    XCTAssertFalse(text("navE2E.posts.detailUser").exists)

    // At the feed root, the next reselect pops the feed back to the root scope list.
    waitPastDoubleTapInterval()
    selectTab("Posts")
    XCTAssertTrue(text("navE2E.lastAction").label.contains("single.navigation.popFeedToRoot"))
    XCTAssertTrue(text("navE2E.posts.rootList").waitForExistence(timeout: 5))
    XCTAssertFalse(text("navE2E.posts.feedRoot").exists)
  }

  // Compact reselect at the root scope list is a no-op (nothing is pushed above it).
  func testPostsCompactRootListSingleTapIsNoop() {
    XCTAssertTrue(text("navE2E.posts.rootList").waitForExistence(timeout: 5))

    selectTab("Posts")

    XCTAssertTrue(text("navE2E.lastAction").label.contains("single.none"))
    XCTAssertTrue(text("navE2E.posts.rootList").waitForExistence(timeout: 5))
  }

  // Picking a scope pushes the feed; reselecting at the feed root pops back to the root list.
  func testPostsCompactPickScopePushesFeedThenReselectPopsToRootList() {
    XCTAssertTrue(text("navE2E.posts.rootList").waitForExistence(timeout: 5))

    button("navE2E.posts.pickPopular").tap()
    XCTAssertTrue(text("navE2E.posts.feedRoot").waitForExistence(timeout: 5))

    selectTab("Posts")
    XCTAssertTrue(text("navE2E.lastAction").label.contains("single.navigation.popFeedToRoot"))
    XCTAssertTrue(text("navE2E.posts.rootList").waitForExistence(timeout: 5))
    XCTAssertFalse(text("navE2E.posts.feedRoot").exists)
  }

  func testPostsRegularSameTabReselectScrollsFeedBeforeDetailBack() {
    XCTAssertTrue(text("navE2E.posts.rootList").waitForExistence(timeout: 5))
    button("navE2E.posts.pickPopular").tap()
    XCTAssertTrue(text("navE2E.posts.feedRoot").waitForExistence(timeout: 5))
    button("navE2E.posts.regularLayout").tap()
    button("navE2E.posts.markFeedScrolled").tap()
    button("navE2E.posts.openPost").tap()
    XCTAssertTrue(text("navE2E.posts.detailRoot").waitForExistence(timeout: 5))

    selectTab("Posts")
    XCTAssertTrue(text("navE2E.lastAction").label.contains("single.surface.scrollContentToTop"))
    XCTAssertTrue(text("navE2E.posts.detailRoot").waitForExistence(timeout: 5))

    waitPastDoubleTapInterval()
    selectTab("Posts")
    XCTAssertTrue(text("navE2E.lastAction").label.contains("single.navigation.backOneStep.detail"))
    XCTAssertTrue(text("navE2E.posts.feedRoot").waitForExistence(timeout: 5))
  }

  // NOTE: Double-tap-to-reset is covered by unit tests (`postsDoubleTapResetsToRootList`,
  // `doubleTapAfterImmediateSingleEndsAtRootList`) rather than a UI test: XCUITest cannot
  // synthesize two tab-bar taps inside the 0.32s double-tap window.

  func testEachTabCanReturnToItsRootWithSameTabReselect() {
    assertColumnTabRoots(tab: "Me", rootID: "navE2E.me.root", pushID: "navE2E.me.push", detailID: "navE2E.me.detail")
    assertColumnTabRoots(tab: "Search", rootID: "navE2E.search.root", pushID: "navE2E.search.push", detailID: "navE2E.search.detail")

    selectTab("Inbox")
    XCTAssertTrue(text("navE2E.inbox.root").waitForExistence(timeout: 5))
    button("navE2E.inbox.push").tap()
    XCTAssertTrue(text("navE2E.inbox.pushed").waitForExistence(timeout: 5))
    selectTab("Inbox")
    XCTAssertTrue(text("navE2E.inbox.root").waitForExistence(timeout: 5))
    XCTAssertFalse(text("navE2E.inbox.pushed").exists)

    selectTab("Settings")
    XCTAssertTrue(text("navE2E.settings.root").waitForExistence(timeout: 5))
    button("navE2E.settings.openBehavior").tap()
    XCTAssertTrue(text("navE2E.settings.detail").waitForExistence(timeout: 5))
    selectTab("Settings")
    XCTAssertTrue(button("navE2E.settings.general").waitForExistence(timeout: 5))
    XCTAssertFalse(text("navE2E.settings.detail").exists)
  }

  func testCopiedRedditCommentLinkOpensPostsDetailAcrossColumnChanges() {
    selectTab("Settings")
    XCTAssertTrue(text("navE2E.settings.root").waitForExistence(timeout: 5))

    button("navE2E.links.openCopiedComment").tap()

    assertCopiedCommentIsOpen()

    XCUIDevice.shared.orientation = .landscapeLeft
    assertCopiedCommentIsOpen()

    XCUIDevice.shared.orientation = .portrait
    assertCopiedCommentIsOpen()
  }

  private func assertColumnTabRoots(tab: String, rootID: String, pushID: String, detailID: String) {
    selectTab(tab)
    XCTAssertTrue(text(rootID).waitForExistence(timeout: 5))
    button(pushID).tap()
    XCTAssertTrue(text(detailID).waitForExistence(timeout: 5))
    selectTab(tab)
    XCTAssertTrue(text(rootID).waitForExistence(timeout: 5))
    XCTAssertFalse(text(detailID).exists)
  }

  private func assertCopiedCommentIsOpen() {
    XCTAssertTrue(text("navE2E.posts.detailRoot").waitForExistence(timeout: 5))
    XCTAssertTrue(text("navE2E.selectedTab").label.contains("posts"))
    XCTAssertTrue(text("navE2E.posts.detailPostID").label.contains("copiedpost123"))
    XCTAssertTrue(text("navE2E.posts.detailHighlightID").label.contains("copiedcomment456"))
  }

  private func selectTab(_ title: String) {
    let tabBarButton = app.tabBars.buttons[title]
    if tabBarButton.waitForExistence(timeout: 2) {
      tabBarButton.tap()
      return
    }

    let sidebarButton = app.buttons[title]
    XCTAssertTrue(sidebarButton.waitForExistence(timeout: 5), "Missing tab or sidebar item: \(title)")
    sidebarButton.tap()
  }

  private func waitPastDoubleTapInterval() {
    Thread.sleep(forTimeInterval: 0.38)
  }

  private func button(_ identifier: String) -> XCUIElement {
    app.buttons[identifier]
  }

  private func text(_ identifier: String) -> XCUIElement {
    app.staticTexts[identifier]
  }

  private func bridgeStatusLabel() -> String {
    let marker = text("navE2E.bridgeStatus")
    XCTAssertTrue(marker.waitForExistence(timeout: 2))
    return marker.label
  }
}
