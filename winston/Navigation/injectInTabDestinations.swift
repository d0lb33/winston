//
//  injectInTabDestinations.swift
//  winston
//
//  Created by Igor Marcossi on 02/09/23.
//

import SwiftUI
import Defaults

struct AttachViewControllerToRouterModifier: ViewModifier {
  var viewControllerHolder: ViewControllerHolder
  
  @Default(.BehaviorDefSettings) private var behaviorDefSettings
  
  func body(content: Content) -> some View {
    content
      .background { AttachViewControllerToRouterView(viewControllerHolder: viewControllerHolder, disable: !behaviorDefSettings.enableSwipeAnywhere) }
  }
}

extension View {
  func injectInTabDestinations(viewControllerHolder: ViewControllerHolder) -> some View {
    self
      .modifier(AttachViewControllerToRouterModifier(viewControllerHolder: viewControllerHolder))
      .navigationDestination(for: Router.NavDest.self, destination: { dest in
        RouterDestinationView(destination: dest)
      })
  }
}

struct RouterDestinationView: View {
  let destination: Router.NavDest

  var body: some View {
    switch destination {
    case .reddit(let reddDest):
      switch reddDest {
      case .post(let (post)):
        RedditPostDestination(post: post)
      case .postHighlighted(let post, let highlightID):
        RedditPostDestination(post: post, highlightID: highlightID)
      case .subFeed(let sub):
        AuroraSubFeedScreen(subreddit: sub)
          .diagnosticScreen("reddit.subFeed.\(sub.id)")
      case .subInfo(let sub):
        SubredditInfo(subreddit: sub)
          .diagnosticScreen("reddit.subInfo.\(sub.id)")
      case .multiFeed(let multi):
        MultiPostsView(multi: multi)
          .diagnosticScreen("reddit.multiFeed.\(multi.id)")
      case .multiInfo(_):
        EmptyView()
          .diagnosticScreen("reddit.multiInfo")
      case .user(let user):
        UserView(user: user)
          .diagnosticScreen("reddit.user.\(user.id)")
      }
    case .setting(let settingsDest):
      switch settingsDest {
      case .general:
        GeneralPanel()
          .diagnosticScreen("setting.general")
      case .behavior:
        BehaviorPanel()
          .diagnosticScreen("setting.behavior")
      case .appearance:
        AppearancePanel()
          .diagnosticScreen("setting.appearance")
      case .accounts:
        AccountsPanel()
          .diagnosticScreen("setting.accounts")
      case .diagnostics:
        DiagnosticsPanel()
          .diagnosticScreen("setting.diagnostics")
      case .about:
        AboutPanel()
          .diagnosticScreen("setting.about")
      case .commentSwipe:
        CommentSwipePanel()
          .diagnosticScreen("setting.commentSwipe")
      case .postSwipe:
        PostSwipePanel()
          .diagnosticScreen("setting.postSwipe")
      case .accessibility:
        AccessibilityPanel()
          .diagnosticScreen("setting.accessibility")
      case .filteredSubreddits:
        FilteredSubredditsSettings()
          .diagnosticScreen("setting.filteredSubreddits")
      case .faq:
        FAQPanel()
          .diagnosticScreen("setting.faq")
      case .appIcon:
        AppIconSetting()
          .diagnosticScreen("setting.appIcon")
      case .designLab:
        DesignLabGallery()
          .diagnosticScreen("setting.designLab")
      }
    }
  }
}

private struct RedditPostDestination: View {
  @ObservedObject var post: Post
  var highlightID: String?

  private var subreddit: Subreddit? {
    post.winstonData?.subreddit ?? post.data.map { Subreddit(id: $0.subreddit) }
  }

  var body: some View {
    if let subreddit {
      AuroraPostDetail(post: post, subreddit: subreddit, highlightID: highlightID)
        .diagnosticScreen(diagnosticName)
    } else {
      ProgressView()
        .progressViewStyle(.circular)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
          post.fetchItself()
        }
        .diagnosticScreen(diagnosticName)
    }
  }

  private var diagnosticName: String {
    if let highlightID {
      return "reddit.postHighlighted.\(post.id).\(highlightID)"
    }
    return "reddit.post.\(post.id)"
  }
}


fileprivate struct AttachViewControllerToRouterView: UIViewRepresentable {
  var viewControllerHolder: ViewControllerHolder
  var disable: Bool

  final class Coordinator {
    var lastDisable: Bool?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> some UIView {
    return UIView()
  }

  func updateUIView(_ uiView: UIViewType, context: Context) {
    // updateUIView runs on every re-render of the host view — including every
    // keystroke while typing in Search. Re-assigning the controller re-adds the
    // full-swipe gestures (controller.didSet), and re-attaching the swipe
    // gesture churns UIKit. Only do that work when something actually changed.
    let coordinator = context.coordinator
    let disable = self.disable
    let holder = viewControllerHolder
    DispatchQueue.main.async {
      if let controller = uiView.parentViewController, holder.controller !== controller {
        holder.controller = controller
      }
      if coordinator.lastDisable != disable {
        coordinator.lastDisable = disable
        if disable {
          holder.removeGestureFromViews()
        } else {
          holder.addGestureToViews()
        }
      }
    }
  }
}

fileprivate extension UIView {
  var parentViewController: UIViewController? {
    sequence(first: self) {
      $0.next
    }.first(where: { $0 is UIViewController }) as? UIViewController
  }
}
