//
//  NavigationE2EHarness.swift
//  winston
//
//  Deterministic app mode for XCTest UI navigation coverage. This launches only
//  when the UI test passes `--winston-navigation-e2e`; normal app launches still
//  use AppContent and live Reddit/account state.
//

import SwiftUI
@_spi(Advanced) import SwiftUIIntrospect

enum NavigationE2ELaunch {
  static let argument = "--winston-navigation-e2e"

  static var isEnabled: Bool {
    ProcessInfo.processInfo.arguments.contains(argument)
  }
}

struct NavigationE2EHarnessView: View {
  private static let tabOrder: [AppNav.Tab] = [.posts, .inbox, .me, .search, .settings]

  @State private var appNav = AppNav.shared
  @State private var tabTapClassifier = TabTapClassifierBox()
  @State private var acceptsSwiftUISameSelection = false
  @State private var lastRootedTab = "none"
  @State private var lastAction = "none"
  @State private var bridgeStatus = "unattached"

  private var tabSelection: Binding<AppNav.Tab> {
    Binding(
      get: { appNav.selectedTab },
      set: { newTab in
        if appNav.selectedTab == newTab {
          guard acceptsSwiftUISameSelection else { return }
          handleTabReselect(newTab, source: "swiftui-selection")
          return
        } else {
          appNav.selectedTab = newTab
        }
      }
    )
  }

  var body: some View {
    TabView(selection: tabSelection) {
      Tab("Posts", systemImage: "doc.text.image", value: AppNav.Tab.posts) {
        NavigationE2EPostsSurface(appNav: appNav)
          .tabRootResetToolbar(appNav: appNav, tab: .posts)
      }

      Tab("Inbox", systemImage: "bell.fill", value: AppNav.Tab.inbox) {
        NavigationE2EStackSurface(
          title: "Inbox",
          rootID: "navE2E.inbox.root",
          pushID: "navE2E.inbox.push",
          pushedID: "navE2E.inbox.pushed",
          path: appNav.inbox
        )
        .tabRootResetToolbar(appNav: appNav, tab: .inbox)
      }

      Tab("Me", systemImage: "person.fill", value: AppNav.Tab.me) {
        NavigationE2EColumnSurface(
          title: "Me",
          rootID: "navE2E.me.root",
          pushID: "navE2E.me.push",
          detailID: "navE2E.me.detail",
          nav: appNav.me
        )
        .tabRootResetToolbar(appNav: appNav, tab: .me)
      }

      Tab("Search", systemImage: "magnifyingglass", value: AppNav.Tab.search, role: .search) {
        NavigationE2EColumnSurface(
          title: "Search",
          rootID: "navE2E.search.root",
          pushID: "navE2E.search.push",
          detailID: "navE2E.search.detail",
          nav: appNav.search
        )
        .tabRootResetToolbar(appNav: appNav, tab: .search)
      }

      Tab("Settings", systemImage: "gearshape.fill", value: AppNav.Tab.settings) {
        NavigationE2ESettingsSurface(nav: appNav.settings)
          .tabRootResetToolbar(appNav: appNav, tab: .settings)
      }
    }
    .tabViewStyle(.sidebarAdaptable)
    .introspect(.tabView, on: .iOS(.v13...)) { tabBarController in
      bridgeStatus = "attached-\(tabBarController.viewControllers?.count ?? 0)"
      TabReselectDelegateInstaller.install(on: tabBarController, tabOrder: Self.tabOrder, classifier: tabTapClassifier) { tab, tap in
        executeTabReselect(tab, tap: tap, source: "introspect")
      }
    }
    .overlay(alignment: .topLeading) {
      Text(verbatim: "Last Root: \(lastRootedTab)")
        .font(.caption2)
        .accessibilityIdentifier("navE2E.lastRootedTab")
        .opacity(0.01)
    }
    .overlay(alignment: .topTrailing) {
      VStack {
        Text(verbatim: "Bridge: \(bridgeStatus)")
          .accessibilityIdentifier("navE2E.bridgeStatus")
        Text(verbatim: "Last Action: \(lastAction)")
          .accessibilityIdentifier("navE2E.lastAction")
      }
      .font(.caption2)
      .opacity(0.01)
    }
    .safeAreaInset(edge: .top) {
      HStack(spacing: 8) {
        Button {
          _ = openParsedRedditURL(parseRedditURL(Self.copiedCommentURL))
        } label: {
          Text(verbatim: "Open Copied Comment Link")
        }
        .accessibilityIdentifier("navE2E.links.openCopiedComment")

        Text(verbatim: "Selected Tab: \(appNav.selectedTab.rawValue)")
          .accessibilityIdentifier("navE2E.selectedTab")
      }
      .font(.caption2)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(.thinMaterial)
    }
    .onAppear {
      appNav.resetAll()
    }
    .task {
      await Task.yield()
      acceptsSwiftUISameSelection = true
    }
  }

  private static let copiedCommentURL = "https://www.reddit.com/r/swift/comments/copiedpost123/navigation_regression/copiedcomment456/"

  private func handleTabReselect(_ tab: AppNav.Tab, source: String) {
    guard let tap = tabTapClassifier.classify(
      tab: tab,
      eventID: nil,
      time: ProcessInfo.processInfo.systemUptime
    ) else { return }
    executeTabReselect(tab, tap: tap, source: source)
  }

  @discardableResult
  private func executeTabReselect(_ tab: AppNav.Tab, tap: TabTapKind, source: String) -> Bool {
    let action = appNav.handleTabReselect(tab, tap: tap)
    lastRootedTab = tab.rawValue
    lastAction = "\(tap == .double ? "double" : "single").\(action.diagnosticsName)"
    TabReselectActionExecutor.execute(action, for: tab, appNav: appNav)
    return action.suppressesNativeReselect
  }
}

private struct NavigationE2EPostsSurface: View {
  let appNav: AppNav

  var body: some View {
    @Bindable var posts = appNav.posts

    NavigationSplitView(preferredCompactColumn: $posts.preferredColumn) {
      List {
        Text(verbatim: "Subreddit Selector")
          .accessibilityIdentifier("navE2E.posts.selector")
        Button {
          posts.updateInteractionLayout(.compact)
          posts.updateRenderedActiveColumn(.sidebar)
        } label: {
          Text(verbatim: "Set Active Sidebar")
        }
        .accessibilityIdentifier("navE2E.posts.activeSidebar")
      }
      .navigationTitle(Text(verbatim: "Posts"))
      .onAppear { posts.updateRenderedActiveColumn(.sidebar) }
    } content: {
      NavigationStack(path: $posts.contentPath) {
        List {
          Text(verbatim: "Popular Feed Root")
            .accessibilityIdentifier("navE2E.posts.feedRoot")
          Text(verbatim: "Scroll Position: \(posts.feedScrollPositionID ?? "none")")
            .accessibilityIdentifier("navE2E.posts.scrollPosition")
          Text(verbatim: "Interaction: \(interactionStateLabel(posts.tabInteractionState))")
            .accessibilityIdentifier("navE2E.posts.interactionState")
          Text(verbatim: "Content Scroll Request: \(posts.contentScrollToTopRequest)")
            .accessibilityIdentifier("navE2E.posts.contentScrollRequest")
          Button {
            posts.updateInteractionLayout(.compact)
            posts.updateRenderedActiveColumn(.content)
          } label: {
            Text(verbatim: "Set Compact Content")
          }
          .accessibilityIdentifier("navE2E.posts.compactContent")
          Button {
            posts.updateInteractionLayout(.regular)
          } label: {
            Text(verbatim: "Set Regular Layout")
          }
          .accessibilityIdentifier("navE2E.posts.regularLayout")
          Button {
            posts.updateContentCanScrollToTop(true)
          } label: {
            Text(verbatim: "Mark Feed Scrolled")
          }
          .accessibilityIdentifier("navE2E.posts.markFeedScrolled")
          Button {
            let post = Post(id: "popular-post-1")
            posts.community = "popular"
            posts.feedScrollPositionID = "popular-post-8"
            posts.selectedPostID = post.id
            posts.selectFeedPost(post)
          } label: {
            Text(verbatim: "Open Popular Post")
          }
          .accessibilityIdentifier("navE2E.posts.openPost")
        }
        .navigationTitle(Text(verbatim: "Popular"))
        .navigationDestination(for: NavDest.self) { destination in
          NavigationE2EDestinationView(destination: destination)
        }
      }
      .onAppear { posts.updateRenderedActiveColumn(.content) }
    } detail: {
      NavigationStack(path: $posts.detailPath) {
        if posts.detailPost != nil {
          VStack(spacing: 16) {
            Text(verbatim: "Post Detail")
              .accessibilityIdentifier("navE2E.posts.detailRoot")
            Text(verbatim: "Detail Post: \(posts.detailPost?.id ?? posts.selectedPostID ?? "none")")
              .accessibilityIdentifier("navE2E.posts.detailPostID")
            Text(verbatim: "Detail Highlight: \(posts.detailHighlightID ?? "none")")
              .accessibilityIdentifier("navE2E.posts.detailHighlightID")
            Text(verbatim: "Posts Column: \(columnName(posts.preferredColumn))")
              .accessibilityIdentifier("navE2E.posts.preferredColumn")
            Text(verbatim: "Detail Scroll Request: \(posts.detailScrollToTopRequest)")
              .accessibilityIdentifier("navE2E.posts.detailScrollRequest")
            Button {
              posts.updateInteractionLayout(.compact)
              posts.updateRenderedActiveColumn(.detail)
            } label: {
              Text(verbatim: "Set Compact Detail")
            }
            .accessibilityIdentifier("navE2E.posts.compactDetail")
            Button {
              posts.updateDetailCanScrollToTop(true)
            } label: {
              Text(verbatim: "Mark Detail Scrolled")
            }
            .accessibilityIdentifier("navE2E.posts.markDetailScrolled")
            Button {
              posts.navigate(.reddit(.user(User(id: "author"))), from: .detail)
            } label: {
              Text(verbatim: "Open Author")
            }
            .accessibilityIdentifier("navE2E.posts.openAuthor")
          }
          .navigationTitle(Text(verbatim: "Post"))
          .navigationDestination(for: NavDest.self) { destination in
            NavigationE2EDestinationView(destination: destination)
          }
        } else {
          Text(verbatim: "No Post Selected")
            .accessibilityIdentifier("navE2E.posts.emptyDetail")
        }
      }
      .onAppear { posts.updateRenderedActiveColumn(.detail) }
    }
    .onAppear {
      posts.updateInteractionLayout(.compact)
      posts.updateRenderedActiveColumn(.content)
    }
    .onChange(of: posts.contentScrollToTopRequest) { _, _ in
      posts.updateContentCanScrollToTop(false)
    }
    .onChange(of: posts.detailScrollToTopRequest) { _, _ in
      posts.updateDetailCanScrollToTop(false)
    }
  }
}

private func columnName(_ column: NavigationSplitViewColumn) -> String {
  if column == .sidebar { return "sidebar" }
  if column == .content { return "content" }
  if column == .detail { return "detail" }
  return "unknown"
}

private func interactionStateLabel(_ state: PostsTabInteractionState) -> String {
  let layout = state.layout == .compact ? "compact" : "regular"
  return "\(layout).\(state.activeColumn.diagnosticsName).contentScroll=\(state.contentCanScrollToTop).detailScroll=\(state.detailCanScrollToTop)"
}

private struct NavigationE2EColumnSurface: View {
  let title: String
  let rootID: String
  let pushID: String
  let detailID: String
  let nav: ColumnNav

  var body: some View {
    @Bindable var nav = nav

    NavigationSplitView(preferredCompactColumn: $nav.preferredColumn) {
      NavigationStack(path: $nav.contentPath) {
        List {
          Text(verbatim: "\(title) Root")
            .accessibilityIdentifier(rootID)
          Button {
            nav.openPostInDetail(Post(id: "\(title.lowercased())-post"))
          } label: {
            Text(verbatim: "Open Detail")
          }
          .accessibilityIdentifier(pushID)
        }
        .navigationTitle(Text(verbatim: title))
      }
    } detail: {
      NavigationStack(path: $nav.detailPath) {
        if nav.detailPost != nil {
          Text(verbatim: "\(title) Detail")
            .accessibilityIdentifier(detailID)
            .navigationTitle(Text(verbatim: "Detail"))
        } else {
          Text(verbatim: "No Detail")
            .accessibilityIdentifier("\(detailID).empty")
        }
      }
    }
  }
}

private struct NavigationE2EStackSurface: View {
  let title: String
  let rootID: String
  let pushID: String
  let pushedID: String
  let path: StackNav

  var body: some View {
    @Bindable var path = path

    NavigationStack(path: $path.path) {
      List {
        Text(verbatim: "\(title) Root")
          .accessibilityIdentifier(rootID)
        Button {
          path.path.append(.reddit(.post(Post(id: "message-post"))))
        } label: {
          Text(verbatim: "Open Message")
        }
        .accessibilityIdentifier(pushID)
      }
      .navigationTitle(Text(verbatim: title))
      .navigationDestination(for: NavDest.self) { _ in
        Text(verbatim: "\(title) Pushed")
          .accessibilityIdentifier(pushedID)
      }
    }
  }
}

private struct NavigationE2ESettingsSurface: View {
  let nav: SettingsNav

  var body: some View {
    @Bindable var nav = nav

    NavigationSplitView(preferredCompactColumn: $nav.preferredColumn) {
      List(selection: $nav.selection) {
        Button {
          nav.select(.general)
        } label: {
          Text(verbatim: "General")
        }
        .accessibilityIdentifier("navE2E.settings.general")
        Button {
          nav.select(.behavior)
        } label: {
          Text(verbatim: "Behavior")
        }
        .accessibilityIdentifier("navE2E.settings.behavior")
      }
      .navigationTitle(Text(verbatim: "Settings"))
    } detail: {
      NavigationStack(path: $nav.detailPath) {
        VStack(spacing: 16) {
          Text(verbatim: nav.selection == .general ? "Settings General" : "Settings Detail")
            .accessibilityIdentifier(nav.selection == .general ? "navE2E.settings.root" : "navE2E.settings.detail")
          Button {
            nav.select(.behavior)
          } label: {
            Text(verbatim: "Open Behavior")
          }
          .accessibilityIdentifier("navE2E.settings.openBehavior")
        }
      }
    }
  }
}

private struct NavigationE2EDestinationView: View {
  let destination: NavDest

  var body: some View {
    switch destination {
    case .reddit(.user):
      Text(verbatim: "User Detail")
        .accessibilityIdentifier("navE2E.posts.detailUser")
    case .reddit(.subFeed):
      Text(verbatim: "Subreddit Detail")
        .accessibilityIdentifier("navE2E.posts.detailSubreddit")
    default:
      Text(verbatim: "Nested Detail")
        .accessibilityIdentifier("navE2E.posts.nestedDetail")
    }
  }
}
