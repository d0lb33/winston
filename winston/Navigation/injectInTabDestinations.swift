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
        switch dest {
        case .reddit(let reddDest):
          switch reddDest {
          case .post(let (post)):
            if let sub = post.winstonData?.subreddit {
              PostView(post: post, subreddit: sub)
                .diagnosticScreen("reddit.post.\(post.id)")
            }
          case .postHighlighted(let post, let highlightID):
            if let sub = post.winstonData?.subreddit {
              PostView(post: post, subreddit: sub, highlightID: highlightID)
                .diagnosticScreen("reddit.postHighlighted.\(post.id).\(highlightID)")
            }
          case .subFeed(let sub):
            SubredditPosts(subreddit: sub).equatable()
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
          case .themes:
            ThemesPanel()
              .diagnosticScreen("setting.themes")
          case .themeStore:
            ThemeStore()
              .diagnosticScreen("setting.themeStore")
          case .appIcon:
            AppIconSetting()
              .diagnosticScreen("setting.appIcon")
          }
        }
      })
  }
}


fileprivate struct AttachViewControllerToRouterView: UIViewRepresentable {
  var viewControllerHolder: ViewControllerHolder
  var disable: Bool
  func makeUIView(context: Context) -> some UIView {
    return UIView()
  }
  
  func updateUIView(_ uiView: UIViewType, context: Context) {
    DispatchQueue.main.async {
      if let controller = uiView.parentViewController {
        viewControllerHolder.controller = controller
      }
      if disable {
        viewControllerHolder.removeGestureFromViews()
      } else {
        viewControllerHolder.addGestureToViews()
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
