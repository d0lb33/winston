//
//  Tabber.swift
//  winston
//
//  Created by Igor Marcossi on 24/06/23.
//

import SwiftUI
import Defaults
import SpriteKit
@_spi(Advanced) import SwiftUIIntrospect
import ObjectiveC

struct Tabber: View, Equatable {
  static func == (lhs: Tabber, rhs: Tabber) -> Bool { true }
  private static let tabOrder: [AppNav.Tab] = [.posts, .inbox, .me, .search, .settings]

  @State private var appNav = AppNav.shared
  @State private var tabTapClassifier = TabTapClassifierBox()
  @State private var acceptsSwiftUISameSelection = false
  @ObservedObject private var wire = RedditWire.shared

  @Environment(\.useTheme) private var currentTheme
  @Environment(TabBarMetrics.self) private var tabBarMetrics
  @Default(.AppearanceDefSettings) private var appearanceDefSettings
  @Default(.VideoDefSettings) private var videoDefSettings

  init(theme: WinstonTheme) {
    Tabber.updateTabAndNavBar(tabTheme: theme.general.tabBarBG, navTheme: theme.general.navPanelBG)
  }

  static func updateTabAndNavBar(tabTheme: ThemeForegroundBG, navTheme: ThemeForegroundBG) {
    let toolbarAppearence = UINavigationBarAppearance()
    if !navTheme.blurry {
      toolbarAppearence.configureWithOpaqueBackground()
    }
    toolbarAppearence.backgroundColor = UIColor(navTheme.color())
    UINavigationBar.appearance().standardAppearance = toolbarAppearence

    let transparentAppearence = UITabBarAppearance()
    if !tabTheme.blurry {
      transparentAppearence.configureWithOpaqueBackground()
    }
    transparentAppearence.backgroundColor = UIColor(tabTheme.color())
    UITabBar.appearance().standardAppearance = transparentAppearence
  }

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
    let accountScopeKey = wire.accountScopeID?.uuidString ?? "none"
    let meTabTitle = appearanceDefSettings.showUsernameInTabBar ? (wire.me?.data?.name ?? "Me") : "Me"

    TabView(selection: tabSelection) {
      Tab("Posts", systemImage: "doc.text.image", value: AppNav.Tab.posts) {
        WithAccountOnly { SubredditsStack(nav: appNav.posts) }
          .id("posts-\(accountScopeKey)")
          .tabRootResetToolbar(appNav: appNav, tab: .posts)
          .measureTabBar(tabBarMetrics)
      }

      Tab("Inbox", systemImage: "bell.fill", value: AppNav.Tab.inbox) {
        WithAccountOnly { Inbox(nav: appNav.inbox) }
          .id("inbox-\(accountScopeKey)")
          .tabRootResetToolbar(appNav: appNav, tab: .inbox)
          .measureTabBar(tabBarMetrics)
      }

      Tab(meTabTitle, systemImage: "person.fill", value: AppNav.Tab.me) {
        WithAccountOnly { Me(nav: appNav.me) }
          .id("me-\(accountScopeKey)")
          .tabRootResetToolbar(appNav: appNav, tab: .me)
          .measureTabBar(tabBarMetrics)
      }

      Tab("Search", systemImage: "magnifyingglass", value: AppNav.Tab.search, role: .search) {
        WithAccountOnly { Search(nav: appNav.search) }
          .id("search-\(accountScopeKey)")
          .tabRootResetToolbar(appNav: appNav, tab: .search)
          .measureTabBar(tabBarMetrics)
      }

      Tab("Settings", systemImage: "gearshape.fill", value: AppNav.Tab.settings) {
        Settings(nav: appNav.settings)
          .tabRootResetToolbar(appNav: appNav, tab: .settings)
          .measureTabBar(tabBarMetrics)
      }
    }
    .tabViewStyle(.sidebarAdaptable)
    .tabBarMinimizeBehavior(.onScrollDown)
    .introspect(.tabView, on: .iOS(.v13...)) { tabBarController in
      TabReselectDelegateInstaller.install(on: tabBarController, tabOrder: Self.tabOrder, classifier: tabTapClassifier) { tab, tap in
        executeTabReselect(tab, tap: tap, source: "introspect")
      }
    }
    .environment(\.videoDefSettings, videoDefSettings)
    .openFromWebListener()
    .clipboardRedditLinkListener()
    .task {
      await Task.yield()
      acceptsSwiftUISameSelection = true
    }
    .task(priority: .background) {
      migrateOldDefaults()
      cleanCredentialOrphanEntities()
      removeDefaultThemeFromThemes()
      checkForOnboardingStatus()
      if !Defaults[.graphQLAccounts].isEmpty {
        Task(priority: .background) { await updatePostsInBox() }
      }
    }
    .accentColor(currentTheme.general.accentColor())
  }

  private func handleTabReselect(_ tab: AppNav.Tab, source: String) {
    guard let tap = tabTapClassifier.classify(
      tab: tab,
      eventID: nil,
      time: ProcessInfo.processInfo.systemUptime
    ) else {
      AppDiagnostics.asyncBreadcrumb("Tab reselect duplicate suppressed", metadata: ["tab": tab.rawValue, "source": source])
      return
    }
    executeTabReselect(tab, tap: tap, source: source)
  }

  private func executeTabReselect(_ tab: AppNav.Tab, tap: TabTapKind, source: String) {
    let action = appNav.handleTabReselect(tab, tap: tap)
    let st = appNav.posts.tabInteractionState
    AppDiagnostics.asyncBreadcrumb(
      "Tab reselected",
      metadata: [
        "tab": tab.rawValue,
        "tap": tap == .double ? "double" : "single",
        "action": action.diagnosticsName,
        "source": source,
        "scope": appNav.posts.scope.token,
        "layout": st.layout == .compact ? "compact" : "regular",
        "contentCanScroll": "\(st.contentCanScrollToTop)",
        "detailCanScroll": "\(st.detailCanScrollToTop)"
      ]
    )
    if tab == .posts {
      // Posts is binding-driven (compact NavigationStack via `compactPath`, wide split with
      // columns always shown), so our handler owns the reselect — the delegate suppresses
      // the native pop-to-root (see shouldSelectTab) and we apply immediately.
      TabReselectActionExecutor.execute(action, for: tab, appNav: appNav)
    } else {
      // The other tabs are still `NavigationSplitView`s that rely on the system's native
      // pop-to-root to collapse to their sidebar root; defer our model mutation one runloop
      // so its re-render doesn't interrupt that native collapse.
      DispatchQueue.main.async {
        TabReselectActionExecutor.execute(action, for: tab, appNav: appNav)
      }
    }
  }
}

enum TabReselectDelegateInstaller {
  @MainActor private static var associationKey: UInt8 = 0

  @MainActor
  static func install(
    on tabBarController: UITabBarController,
    tabOrder: [AppNav.Tab],
    classifier: TabTapClassifierBox,
    onReselect: @escaping (AppNav.Tab, TabTapKind) -> Void
  ) {
    let delegate: TabReselectDelegate
    if let existing = objc_getAssociatedObject(tabBarController, &associationKey) as? TabReselectDelegate {
      delegate = existing
    } else {
      delegate = TabReselectDelegate()
      objc_setAssociatedObject(tabBarController, &associationKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    delegate.tabOrder = tabOrder
    delegate.classifier = classifier
    delegate.onReselect = onReselect
    delegate.attach(to: tabBarController)
  }
}

@MainActor
private final class TabReselectDelegate: NSObject, UITabBarControllerDelegate {
  var tabOrder: [AppNav.Tab] = []
  var classifier: TabTapClassifierBox?
  var onReselect: ((AppNav.Tab, TabTapKind) -> Void)?
  private weak var previousDelegate: UITabBarControllerDelegate?
  private var lastSelectedIndex: Int?
  private var lastSelectedTabIdentifier: String?

  func attach(to tabBarController: UITabBarController) {
    guard tabBarController.delegate !== self else {
      updateLastSelectedIndex(in: tabBarController)
      return
    }
    previousDelegate = tabBarController.delegate
    tabBarController.delegate = self
    updateLastSelectedIndex(in: tabBarController)
    updateLastSelectedTabIdentifier(in: tabBarController)
  }

  func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
    if viewController === tabBarController.selectedViewController,
       let tab = tab(for: viewController, in: tabBarController) {
      emitReselect(tab)
      return tab != .posts
    }

    if let previousDelegate,
       previousDelegate !== self,
       let shouldSelect = previousDelegate.tabBarController?(tabBarController, shouldSelect: viewController) {
      return shouldSelect
    }

    return true
  }

  func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
    defer {
      updateLastSelectedIndex(in: tabBarController)
      previousDelegate?.tabBarController?(tabBarController, didSelect: viewController)
    }

    if #available(iOS 18.0, *) {
      return
    }

    guard let selectedIndex = selectedIndex(in: tabBarController),
          selectedIndex == lastSelectedIndex,
          let tab = tab(for: viewController, in: tabBarController)
    else { return }

    emitReselect(tab)
  }

  @available(iOS 18.0, *)
  func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
    // Tapping the already-selected tab is a "reselect". Handle it ourselves (scroll-to-top
    // → step back one level → reveal the sidebar) and return false to suppress UIKit's own
    // iOS-18+ reselect behavior, which otherwise pops the whole NavigationSplitView
    // straight to its sidebar root and clobbers the one-level-at-a-time peel-back.
    if tab.identifier == tabBarController.selectedTab?.identifier,
       let appTab = appTab(for: tab, in: tabBarController) {
      emitReselect(appTab)
      // Posts owns its reselect (binding-driven) → suppress the native pop-to-root. The
      // other tabs are still NavigationSplitViews that need the native pop to collapse.
      return appTab != .posts
    }

    if let previousDelegate,
       previousDelegate !== self,
       let shouldSelect = previousDelegate.tabBarController?(tabBarController, shouldSelectTab: tab) {
      return shouldSelect
    }

    return true
  }

  @available(iOS 18.0, *)
  func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
    defer {
      lastSelectedTabIdentifier = selectedTab.identifier
      previousDelegate?.tabBarController?(tabBarController, didSelectTab: selectedTab, previousTab: previousTab)
    }

    guard (selectedTab === previousTab || selectedTab.identifier == lastSelectedTabIdentifier),
          let tab = appTab(for: selectedTab, in: tabBarController)
    else { return }

    emitReselect(tab)
  }

  private func emitReselect(_ tab: AppNav.Tab) {
    guard let tap = classifier?.classify(
      tab: tab,
      eventID: nil,
      time: ProcessInfo.processInfo.systemUptime
    ) else { return }
    onReselect?(tab, tap)
  }

  private func updateLastSelectedIndex(in tabBarController: UITabBarController) {
    lastSelectedIndex = selectedIndex(in: tabBarController)
  }

  private func selectedIndex(in tabBarController: UITabBarController) -> Int? {
    guard let selected = tabBarController.selectedViewController,
          let controllers = tabBarController.viewControllers
    else { return nil }
    return controllers.firstIndex(where: { $0 === selected })
  }

  private func updateLastSelectedTabIdentifier(in tabBarController: UITabBarController) {
    if #available(iOS 18.0, *) {
      lastSelectedTabIdentifier = tabBarController.selectedTab?.identifier
    }
  }

  private func tab(for viewController: UIViewController, in tabBarController: UITabBarController) -> AppNav.Tab? {
    if let tab = tab(forTitle: viewController.tabBarItem.title) {
      return tab
    }

    guard let controllers = tabBarController.viewControllers,
          let index = controllers.firstIndex(where: { $0 === viewController }),
          tabOrder.indices.contains(index)
    else { return nil }
    return tabOrder[index]
  }

  private func tab(forTitle title: String?) -> AppNav.Tab? {
    switch title {
    case "Posts": return .posts
    case "Inbox": return .inbox
    case "Search": return .search
    case "Settings": return .settings
    case "Me": return .me
      default: return nil
    }
  }

  @available(iOS 18.0, *)
  private func appTab(for selectedCandidate: UITab, in tabBarController: UITabBarController) -> AppNav.Tab? {
    if let appTab = tab(forTitle: selectedCandidate.title) {
      return appTab
    }

    guard let index = tabBarController.tabs.firstIndex(where: { $0 === selectedCandidate }),
          tabOrder.indices.contains(index)
    else { return nil }
    return tabOrder[index]
  }
}

struct TabRootResetToolbarModifier: ViewModifier {
  let appNav: AppNav
  let tab: AppNav.Tab

  func body(content: Content) -> some View {
    content
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            AppDiagnostics.asyncBreadcrumb("Tab root button tapped", metadata: ["tab": tab.rawValue])
            appNav.resetToTabRoot(tab)
          } label: {
            Label("Root", systemImage: "arrow.uturn.backward")
          }
          .disabled(!appNav.canResetToTabRoot(tab))
          .accessibilityIdentifier("tabRootResetButton.\(tab.rawValue)")
        }
      }
  }
}

extension View {
  func tabRootResetToolbar(appNav: AppNav, tab: AppNav.Tab) -> some View {
    modifier(TabRootResetToolbarModifier(appNav: appNav, tab: tab))
  }
}
