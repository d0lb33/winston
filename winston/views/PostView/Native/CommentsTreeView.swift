//
//  CommentsTreeView.swift
//  winston
//
//  Drives a single ForEach over the flattened comment rows. Must be used inside
//  a List — each row is a List row, so large threads stay virtualized and
//  collapse animates as a direct diff.
//
//  IMPORTANT: do not apply an extra `.id()` to the rows. The ForEach already
//  identifies by CommentRow.id; an additional `.id()` that disagrees makes List
//  bind a row's gesture/state to the wrong comment (collapse hit the wrong row).
//  ScrollViewReader targets the same CommentRow.id, so scrolling still works.
//

import SwiftUI

struct CommentsTreeView: View {
  let model: CommentTreeModel
  let loading: Bool
  let errorMessage: String?
  weak var post: Post?
  let postFullname: String
  let opAuthor: String?
  let swipeActions: SwipeActionsSet
  /// Comment id (bare, no `t1_` prefix) to visually highlight after a deep-link jump.
  let highlightedID: String?
  let maxMediaHeightPct: CGFloat
  let contentWidth: CGFloat

  init(
    model: CommentTreeModel,
    loading: Bool,
    errorMessage: String? = nil,
    post: Post?,
    postFullname: String,
    opAuthor: String?,
    swipeActions: SwipeActionsSet,
    highlightedID: String? = nil,
    maxMediaHeightPct: CGFloat,
    contentWidth: CGFloat = 0
  ) {
    self.model = model
    self.loading = loading
    self.errorMessage = errorMessage
    self.post = post
    self.postFullname = postFullname
    self.opAuthor = opAuthor
    self.swipeActions = swipeActions
    self.highlightedID = highlightedID
    self.maxMediaHeightPct = maxMediaHeightPct
    self.contentWidth = contentWidth
  }

  var body: some View {
    let _ = ScrollPerfDiagnostics.bump("commentsTree.body")
    if loading && model.rows.isEmpty {
      HStack {
        Spacer()
        ProgressView()
        Spacer()
      }
      .padding(.vertical, 48)
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
    } else if let errorMessage, model.rows.isEmpty {
      ContentUnavailableView(
        "Couldn't Load Comments",
        systemImage: "exclamationmark.bubble",
        description: Text(errorMessage)
      )
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
    } else if model.rows.isEmpty {
      ContentUnavailableView(
        "No Comments",
        systemImage: "bubble.left.and.bubble.right",
        description: Text("Be the first to comment.")
      )
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
    } else {
      ForEach(model.rows) { row in
        CommentRowView(
          row: row,
          comment: row.comment,
          model: model,
          post: post,
          postFullname: postFullname,
          opAuthor: opAuthor,
          swipeActions: swipeActions,
          highlightedID: highlightedID,
          maxMediaHeightPct: maxMediaHeightPct,
          contentWidth: contentWidth
        )
        .onAppear {
          ScrollPerfDiagnostics.bump(row.kind.appearDiagnosticsCategory)
        }
        .onDisappear {
          ScrollPerfDiagnostics.bump(row.kind.disappearDiagnosticsCategory)
        }
      }
    }
  }
}

private extension CommentRowKind {
  var appearDiagnosticsCategory: String {
    switch self {
    case .comment: return "commentRow.appear.comment"
    case .more: return "commentRow.appear.more"
    case .continueThread: return "commentRow.appear.continue"
    }
  }

  var disappearDiagnosticsCategory: String {
    switch self {
    case .comment: return "commentRow.disappear.comment"
    case .more: return "commentRow.disappear.more"
    case .continueThread: return "commentRow.disappear.continue"
    }
  }
}
