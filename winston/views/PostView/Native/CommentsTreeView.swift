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

struct CommentScrollPosition: Equatable {
  let id: String
  let anchorY: CGFloat

  var unitPoint: UnitPoint {
    UnitPoint(x: 0.5, y: min(1, max(0, anchorY)))
  }
}

private struct CommentRowFrame: Equatable {
  let minY: CGFloat
  let maxY: CGFloat
  let viewportHeight: CGFloat

  var height: CGFloat { max(maxY - minY, 1) }
  var isVisible: Bool {
    let limit = viewportHeight > 0 ? viewportHeight : .greatestFiniteMagnitude
    return maxY > 0 && minY < limit
  }
}

@MainActor
private final class CommentVisibleRowsBox {
  private var frames: [String: CommentRowFrame] = [:]

  func update(_ frame: CommentRowFrame, id: String) { frames[id] = frame }
  func remove(_ id: String) { frames.removeValue(forKey: id) }

  func position(for id: String) -> CommentScrollPosition? {
    guard let frame = frames[id], frame.isVisible else { return nil }
    let denominator = frame.viewportHeight - frame.height
    let anchorY = abs(denominator) > 1 ? frame.minY / denominator : 0.5
    return CommentScrollPosition(id: id, anchorY: min(1, max(0, anchorY)))
  }
}

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
  let viewportHeight: CGFloat
  let onToggleCollapse: ((CommentScrollPosition) -> Void)?

  @State private var visibleRows = CommentVisibleRowsBox()

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
    contentWidth: CGFloat = 0,
    viewportHeight: CGFloat = 0,
    onToggleCollapse: ((CommentScrollPosition) -> Void)? = nil
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
    self.viewportHeight = viewportHeight
    self.onToggleCollapse = onToggleCollapse
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
          contentWidth: contentWidth,
          onToggleCollapse: { id in
            let position = visibleRows.position(for: id) ?? CommentScrollPosition(id: id, anchorY: 0.38)
            if let onToggleCollapse {
              onToggleCollapse(position)
            } else {
              model.toggleCollapse(id)
            }
          }
        )
        .background {
          Color.clear
            .onGeometryChange(for: CommentRowFrame.self) { proxy in
              let frame = proxy.frame(in: .named("auroraPostDetail"))
              return CommentRowFrame(minY: frame.minY, maxY: frame.maxY, viewportHeight: viewportHeight)
            } action: { frame in
              visibleRows.update(frame, id: row.id)
            }
        }
        .onAppear {
          ScrollPerfDiagnostics.bump(row.kind.appearDiagnosticsCategory)
        }
        .onDisappear {
          ScrollPerfDiagnostics.bump(row.kind.disappearDiagnosticsCategory)
          visibleRows.remove(row.id)
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
