//
//  Tabber.swift
//  winston
//
//  Created by Igor Marcossi on 24/06/23.
//

import SwiftUI
import Defaults
import SpriteKit

struct Tabber: View, Equatable {
  static func == (lhs: Tabber, rhs: Tabber) -> Bool { true }
  private static let tabOrder: [AppNav.Tab] = [.posts, .inbox, .me, .search, .settings]

  @State private var appNav = AppNav.shared
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
      set: { appNav.selectedTab = $0 }
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
    .background(
      TabReselectBridge(tabOrder: Self.tabOrder) { tab in
        AppDiagnostics.asyncBreadcrumb("Tab reselected", metadata: ["tab": tab.rawValue])
        appNav.resetToTabRoot(tab)
      }
      .allowsHitTesting(false)
    )
    .environment(\.videoDefSettings, videoDefSettings)
    .openFromWebListener()
    .clipboardRedditLinkListener()
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
}

private struct TabRootResetToolbarModifier: ViewModifier {
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

private extension View {
  func tabRootResetToolbar(appNav: AppNav, tab: AppNav.Tab) -> some View {
    modifier(TabRootResetToolbarModifier(appNav: appNav, tab: tab))
  }
}

private struct TabReselectBridge: UIViewControllerRepresentable {
  let tabOrder: [AppNav.Tab]
  let onReselect: (AppNav.Tab) -> Void

  func makeUIViewController(context: Context) -> UIViewController {
    let controller = HostController()
    context.coordinator.tabOrder = tabOrder
    context.coordinator.onReselect = onReselect
    controller.onReady = { [weak coordinator = context.coordinator] controller in
      coordinator?.attachIfPossible(from: controller)
    }
    return controller
  }

  func updateUIViewController(_ controller: UIViewController, context: Context) {
    context.coordinator.tabOrder = tabOrder
    context.coordinator.onReselect = onReselect
    context.coordinator.attachIfPossible(from: controller)
  }

  func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
    coordinator.detach()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  @MainActor
  final class HostController: UIViewController {
    var onReady: ((UIViewController) -> Void)?

    override func didMove(toParent parent: UIViewController?) {
      super.didMove(toParent: parent)
      onReady?(self)
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      onReady?(self)
    }
  }

  @MainActor
  final class Coordinator: NSObject, UITabBarControllerDelegate {
    var tabOrder: [AppNav.Tab] = []
    var onReselect: ((AppNav.Tab) -> Void)?
    private weak var tabBarController: UITabBarController?
    private weak var previousDelegate: UITabBarControllerDelegate?
    private var lastSelectedIndex: Int?

    func attachIfPossible(from controller: UIViewController) {
      if let tabBarController = findTabBarController(from: controller) {
        attach(to: tabBarController)
        return
      }

      Task { @MainActor [weak self, weak controller] in
        await Task.yield()
        guard let self, let controller else { return }
        if let tabBarController = self.findTabBarController(from: controller) ?? self.findTabBarControllerInConnectedScenes() {
          self.attach(to: tabBarController)
        }
      }
    }

    private func attach(to tabBarController: UITabBarController) {
      guard self.tabBarController !== tabBarController || tabBarController.delegate !== self else {
        updateLastSelectedIndex(in: tabBarController)
        return
      }

      if tabBarController.delegate !== self {
        previousDelegate = tabBarController.delegate
      }
      self.tabBarController = tabBarController
      tabBarController.delegate = self
      updateLastSelectedIndex(in: tabBarController)
      AppDiagnostics.asyncBreadcrumb("Tab reselect bridge attached", metadata: [
        "tabs": "\(tabBarController.viewControllers?.count ?? 0)",
        "selectedIndex": lastSelectedIndex.map(String.init) ?? "nil"
      ])
    }

    func detach() {
      guard let tabBarController, tabBarController.delegate === self else { return }
      tabBarController.delegate = previousDelegate
      self.tabBarController = nil
      previousDelegate = nil
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
      if viewController === tabBarController.selectedViewController,
         let tab = tab(for: viewController, in: tabBarController) {
        onReselect?(tab)
        return false
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

      guard let selectedIndex = selectedIndex(in: tabBarController),
            selectedIndex == lastSelectedIndex,
            let tab = tab(for: viewController, in: tabBarController)
      else { return }

      onReselect?(tab)
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

    private func tab(for viewController: UIViewController, in tabBarController: UITabBarController) -> AppNav.Tab? {
      guard let controllers = tabBarController.viewControllers,
            let index = controllers.firstIndex(where: { $0 === viewController }),
            tabOrder.indices.contains(index)
      else { return nil }
      return tabOrder[index]
    }

    private func findTabBarController(from controller: UIViewController) -> UITabBarController? {
      var current: UIViewController? = controller
      while let candidate = current {
        if let tabBarController = candidate as? UITabBarController {
          return tabBarController
        }
        current = candidate.parent
      }

      guard let root = controller.view.window?.rootViewController else { return nil }
      return findTabBarController(in: root)
    }

    private func findTabBarControllerInConnectedScenes() -> UITabBarController? {
      UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .compactMap(\.rootViewController)
        .compactMap { findTabBarController(in: $0) }
        .first
    }

    private func findTabBarController(in controller: UIViewController) -> UITabBarController? {
      if let tabBarController = controller as? UITabBarController {
        return tabBarController
      }
      for child in controller.children {
        if let tabBarController = findTabBarController(in: child) {
          return tabBarController
        }
      }
      if let presented = controller.presentedViewController {
        return findTabBarController(in: presented)
      }
      return nil
    }
  }
}
