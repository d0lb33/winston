//
//  CommentTreeModelTests.swift
//  winstonTests
//
//  Model-level coverage for the flattened comment tree that drives collapse/expand. No live
//  Reddit — builds a deterministic forest from CommentData fixtures.
//

import Testing
import Foundation
@testable import winston

@Suite(.serialized)
@MainActor
struct CommentTreeModelTests {

  /// Build a CommentData with optional nested replies (mirrors the real listing shape).
  private func make(_ id: String, replies: [CommentData] = []) -> CommentData {
    var data = CommentData(id: id)
    data.author = "author-\(id)"
    data.body = "body \(id)"
    data.created = 1_700_000_000
    data.ups = 1
    if !replies.isEmpty {
      var listingData = ListingData<CommentData>(after: nil, dist: nil, modhash: nil, geo_filter: nil)
      listingData.children = replies.map { reply in
        // kind nil → the child Comment's id stays its bare data.id (no kind suffix).
        var child = ListingChild<CommentData>(kind: nil)
        child.data = reply
        return child
      }
      var listing = Listing<CommentData>(kind: "Listing")
      listing.data = listingData
      data.replies = .second(listing)
    }
    return data
  }

  /// Forest: A → B → B1; A → C; D (root, no children).
  private func makeModel() -> CommentTreeModel {
    let b1 = make("B1")
    let b = make("B", replies: [b1])
    let c = make("C")
    let a = make("A", replies: [b, c])
    let d = make("D")
    // Unique postID per model so persisted collapse state (Defaults[.collapsedCommentsByPost])
    // never leaks between tests or runs.
    let model = CommentTreeModel(postID: "test-\(UUID().uuidString)")
    model.setRoots([Comment(data: a), Comment(data: d)])
    return model
  }

  @Test("Flatten yields A,B,B1,C,D with correct depths")
  func flattenOrderAndDepth() {
    let model = makeModel()
    #expect(model.rows.map(\.id) == ["A", "B", "B1", "C", "D"])
    #expect(model.rows.map(\.depth) == [0, 1, 2, 1, 0])
    #expect(model.rows.allSatisfy { !$0.isCollapsed })
  }

  @Test("Collapsing A removes its whole subtree (B,B1,C), keeps A and D")
  func collapseRemovesSubtree() {
    let model = makeModel()
    model.toggleCollapse("A")
    #expect(model.rows.map(\.id) == ["A", "D"])
    let a = model.rows.first { $0.id == "A" }
    #expect(a?.isCollapsed == true)
    #expect(a?.hiddenReplyCount == 3) // B, B1, C
  }

  @Test("Expanding A restores B,B1,C in order")
  func expandRestoresSubtree() {
    let model = makeModel()
    model.toggleCollapse("A")
    model.toggleCollapse("A")
    #expect(model.rows.map(\.id) == ["A", "B", "B1", "C", "D"])
    #expect(model.rows.first { $0.id == "A" }?.isCollapsed == false)
  }

  @Test("Collapsing a mid-level node hides only its descendants")
  func collapseMidLevel() {
    let model = makeModel()
    model.toggleCollapse("B")
    #expect(model.rows.map(\.id) == ["A", "B", "C", "D"]) // B1 hidden; C/D remain
    #expect(model.rows.first { $0.id == "B" }?.isCollapsed == true)
    #expect(model.rows.first { $0.id == "B" }?.hiddenReplyCount == 1)
  }

  @Test("Collapsing a leaf only flips its flag (nothing to hide)")
  func collapseLeaf() {
    let model = makeModel()
    model.toggleCollapse("C")
    #expect(model.rows.map(\.id) == ["A", "B", "B1", "C", "D"])
    #expect(model.rows.first { $0.id == "C" }?.isCollapsed == true)
    #expect(model.rows.first { $0.id == "C" }?.hiddenReplyCount == 0)
  }

  @Test("Nested collapse: collapsing B then A, expanding A keeps B collapsed")
  func nestedCollapseStatePersists() {
    let model = makeModel()
    model.toggleCollapse("B")          // B1 hidden
    model.toggleCollapse("A")          // whole subtree hidden
    #expect(model.rows.map(\.id) == ["A", "D"])
    model.toggleCollapse("A")          // expand A
    // B is still collapsed, so B1 stays hidden.
    #expect(model.rows.map(\.id) == ["A", "B", "C", "D"])
    #expect(model.rows.first { $0.id == "B" }?.isCollapsed == true)
  }
}
