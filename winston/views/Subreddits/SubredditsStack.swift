//
//  SubredditsStack.swift
//  winston
//
//  Created by Igor Marcossi on 19/09/23.
//

import SwiftUI
import Defaults

struct SubredditsStack: View {
  @ObservedObject var router: Router
  @Default(.BehaviorDefSettings) private var behaviorDefSettings // handle default feed selection routing
  @Default(.GeneralDefSettings) private var generalDefSettings // handle default feed selection routing
  @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
  @State private var sidebarSize: CGSize = .zero
  /// Live width of the detail pane. Seeded with the launch width but kept in sync
  /// via `.onGeometryChange` so the feed reflows on rotate / resize / split changes
  /// instead of being stuck at the frozen `screenW` (which is captured once, in
  /// portrait, and never updates — the root of the broken landscape layout).
  @State private var detailWidth: CGFloat = .screenW

  var postContentWidth: CGFloat { .screenW - (!IPAD || columnVisibility == .detailOnly ? 0 : sidebarSize.width) }
  
  @State private var loaded = false
  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      if let redditCredentialSelectedID = generalDefSettings.redditCredentialSelectedID {
        Subreddits(selectedSub: $router.firstSelected, loaded: loaded, currentCredentialID: redditCredentialSelectedID)
          .equatable()
          .measure($sidebarSize).id("subreddits-list-\(redditCredentialSelectedID)")
          .injectInTabDestinations(viewControllerHolder: router.navController)
      }
    } detail: {
      NavigationStack(path: $router.path) {
        Group {
          if let firstSelected = router.firstSelected {
            switch firstSelected {
            case .reddit(.multiFeed(let multi)):
              MultiPostsView(multi: multi)
                .id("\(multi.id)-multi-first-tab")
            case .reddit(.subFeed(let sub)):
              SubredditPosts(subreddit: sub)
                .equatable()
                .id("\(sub.id)-sub-first-tab")
            case .reddit(.post(let post)):
              if let sub = post.winstonData?.subreddit {
                PostView(post: post, subreddit: sub)
                  .id("\(post.id)-post-first-tab")
              }
            case .reddit(.user(let user)):
              UserView(user: user)
                .id("\(user.id)-user-first-tab")
            default:
              EmptyView()
            }
          } else {
            VStack(spacing: 24) {
              Image(.winstonEyes)
                .resizable()
                .scaledToFit()
                .frame(width: 200)
              VStack {
                Text("Meow, I mean...")
                  .opacity(0.38)
                  .fontSize(24, .bold)
                Text("Where are the subs?")
                  .opacity(0.35)
              }
            }
          }
        }
        .injectInTabDestinations(viewControllerHolder: router.navController)
        .task(priority: .background) {
          if !loaded {
            // MARK: Route to default feed
            if behaviorDefSettings.preferenceDefaultFeed != "subList" && router.path.count == 0 { // we are in subList, can ignore
              let tempSubreddit = Subreddit(id: behaviorDefSettings.preferenceDefaultFeed)
              router.navigateTo(.reddit(.subFeed(tempSubreddit)))
            }

            withAnimation {
              loaded = true
            }
          }
        }
      }
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.width
      } action: { newWidth in
        if newWidth > 0 { detailWidth = newWidth }
      }
      .environment(\.contentWidth, detailWidth)
    }
//    .swipeAnywhere()
    .environment(\.contentWidth, postContentWidth)
  }
}
