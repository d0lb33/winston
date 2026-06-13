//
//  CommentSwipeActions.swift
//  winston
//
//  Native swipe actions for comment rows, populated from the user's configured
//  comment swipe actions (Settings → Comments → swipe actions). Replaces the
//  legacy drag-to-trigger SwipeUI system for comments.
//

import SwiftUI
import Defaults

/// Mapping mirrors the legacy drag-to-trigger system: dragging right revealed
/// `rightFirst`/`rightSecond`, so those become the leading-edge buttons;
/// dragging left revealed `leftFirst`/`leftSecond`, so those become the
/// trailing-edge buttons. A full swipe triggers the first button of the edge.
struct CommentSwipeActionsModifier: ViewModifier {
  @ObservedObject var comment: Comment
  let actionsSet: SwipeActionsSet
  let enabled: Bool
  /// True while either edge's buttons are revealed; lets the row suppress its
  /// collapse tap so dismissing the buttons doesn't also toggle the comment.
  @Binding var actionsArePresented: Bool

  @Default(.BehaviorDefSettings) private var behaviorDefSettings

  func body(content: Content) -> some View {
    if !enabled || behaviorDefSettings.enableSwipeAnywhere {
      content
    } else {
      content
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
          swipeButton(actionsSet.rightFirst)
          swipeButton(actionsSet.rightSecond)
        } onPresentationChanged: { presented in
          actionsArePresented = presented
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
          swipeButton(actionsSet.leftFirst)
          swipeButton(actionsSet.leftSecond)
        } onPresentationChanged: { presented in
          actionsArePresented = presented
        }
    }
  }

  @ViewBuilder
  private func swipeButton(_ action: AnySwipeAction) -> some View {
    if action.id != "none", action.enabled(comment) {
      let active = action.active(comment)
      Button {
        Task { await action.action(comment) }
      } label: {
        Label(active ? "Undo \(action.label.lowercased())" : action.label, systemImage: active ? action.icon.active : action.icon.normal)
      }
      .tint(Color.hex(active ? action.bgColor.active : action.bgColor.normal))
    }
  }
}

extension View {
  func commentSwipeActions(comment: Comment, actionsSet: SwipeActionsSet, enabled: Bool = true, actionsArePresented: Binding<Bool>) -> some View {
    modifier(CommentSwipeActionsModifier(comment: comment, actionsSet: actionsSet, enabled: enabled, actionsArePresented: actionsArePresented))
  }
}
