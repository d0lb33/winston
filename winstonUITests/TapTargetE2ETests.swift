//
//  TapTargetE2ETests.swift
//  winstonUITests
//
//  Drives the real comment + feed-card views (gated by `--winston-taptarget-e2e`) to verify
//  tap targets: a comment collapses on a tap ANYWHERE horizontally (gutter, padding, body)
//  except on its controls (author, vote, link); a feed card's header/title opens the post.
//
//  Detection uses each comment's BODY text (a plain, queryable staticText). Region taps are
//  placed with absolute window coordinates anchored to the parent's on-screen row, so we can
//  hit the left gutter / trailing padding that no narrow element covers.
//

import XCTest

final class TapTargetE2ETests: XCTestCase {
  private var app: XCUIApplication!

  // Fixture body strings (the deterministic tree built by TapTargetE2EHarness).
  private let alphaBody = "Tap anywhere on this comment to collapse it. The gutter, the padding, and this body text all collapse."
  private let betaBody = "First reply to alpha."          // child of alpha (collapse target)
  private let deltaLink = "Tap this link — it should open and must not collapse the comment"
  private let deltaChildBody = "Reply under the link comment."
  private let cardTitle = "Winston won as the best app in the universe"

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    app = XCUIApplication()
    app.launchArguments = ["--winston-taptarget-e2e"]
    app.launch()
  }

  override func tearDown() { app = nil; super.tearDown() }

  // MARK: - Helpers

  private func body(_ s: String) -> XCUIElement { app.staticTexts[s] }
  private func lastActionContains(_ s: String) -> Bool {
    app.staticTexts["taptarget.lastAction"].label.contains(s)
  }

  /// Tap an absolute window point at `x`, aligned vertically with `anchor`'s center.
  private func tapRow(x: CGFloat, alignedWith anchor: XCUIElement) {
    let y = anchor.frame.midY
    app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
  }

  private var screenWidth: CGFloat { app.windows.firstMatch.frame.width }

  // MARK: - Comment collapse: tap anywhere horizontally

  func testTapLeftGutterCollapsesComment() {
    XCTAssertTrue(body(alphaBody).waitForExistence(timeout: 8))
    XCTAssertTrue(body(betaBody).waitForExistence(timeout: 5))
    tapRow(x: 6, alignedWith: body(alphaBody))            // far-left gutter / padding
    XCTAssertTrue(body(betaBody).waitForNonExistence(timeout: 3))
  }

  func testTapTrailingPaddingCollapsesComment() {
    XCTAssertTrue(body(betaBody).waitForExistence(timeout: 8))
    // Right portion of the body row (past the short body text, below the header's controls) —
    // empty space that must still collapse.
    tapRow(x: screenWidth - 40, alignedWith: body(alphaBody))
    XCTAssertTrue(body(betaBody).waitForNonExistence(timeout: 3))
  }

  func testTapBodyCollapsesComment() {
    XCTAssertTrue(body(betaBody).waitForExistence(timeout: 8))
    body(alphaBody).tap()                                  // the body text itself
    XCTAssertTrue(body(betaBody).waitForNonExistence(timeout: 3))
  }

  func testCollapsedCommentExpandsOnTap() {
    XCTAssertTrue(body(betaBody).waitForExistence(timeout: 8))
    body(alphaBody).tap()
    XCTAssertTrue(body(betaBody).waitForNonExistence(timeout: 3))
    // When collapsed the body is hidden; the author row is still there — tap it to expand.
    app.buttons["RootAlpha"].firstMatch.tap()
    XCTAssertTrue(body(betaBody).waitForExistence(timeout: 3))
  }

  // MARK: - Comment controls must NOT collapse

  func testTapAuthorDoesNotCollapse() {
    XCTAssertTrue(body(betaBody).waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["RootAlpha"].firstMatch.waitForExistence(timeout: 5))
    app.buttons["RootAlpha"].firstMatch.tap()
    XCTAssertTrue(body(betaBody).exists)                   // no collapse
    XCTAssertTrue(lastActionContains("author"))           // author navigation fired
  }

  func testTapVoteDoesNotCollapse() {
    XCTAssertTrue(body(betaBody).waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["Upvote"].firstMatch.waitForExistence(timeout: 5))
    app.buttons["Upvote"].firstMatch.tap()
    XCTAssertTrue(body(betaBody).exists)                   // alpha did not collapse
  }

  func testTapLinkInCommentDoesNotCollapse() {
    XCTAssertTrue(body(deltaChildBody).waitForExistence(timeout: 8))
    XCTAssertTrue(body(deltaLink).waitForExistence(timeout: 5))
    body(deltaLink).tap()                                  // the link spans delta's body
    XCTAssertTrue(body(deltaChildBody).exists)             // link consumed the tap (no collapse)
  }

  // MARK: - Feed card: header/title opens the post (media no longer steals the tap)

  func testTapCardTitleOpensPost() {
    let title = app.staticTexts[cardTitle]
    var tries = 0
    while !title.isHittable && tries < 8 {
      app.swipeUp()
      tries += 1
    }
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    XCTAssertTrue(lastActionContains("openPost"))
  }
}
