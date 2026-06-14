//
//  CommentsTreeView.swift
//  winston
//
//  Drives a single ForEach over the flattened comment rows. Must be used inside
//  a List — each row is a List row, so large threads stay virtualized and
//  collapse animates as a clean diff.
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
  weak var post: Post?
  let postFullname: String
  let opAuthor: String?
  let swipeActions: SwipeActionsSet

  var body: some View {
    if loading && model.rows.isEmpty {
      HStack {
        Spacer()
        ProgressView()
        Spacer()
      }
      .padding(.vertical, 48)
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
          swipeActions: swipeActions
        )
      }
    }
  }
}
