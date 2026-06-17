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
          .measureTabBar(tabBarMetrics)
      }

      Tab("Inbox", systemImage: "bell.fill", value: AppNav.Tab.inbox) {
        WithAccountOnly { Inbox(nav: appNav.inbox) }
          .id("inbox-\(accountScopeKey)")
          .measureTabBar(tabBarMetrics)
      }

      Tab(meTabTitle, systemImage: "person.fill", value: AppNav.Tab.me) {
        WithAccountOnly { Me(nav: appNav.me) }
          .id("me-\(accountScopeKey)")
          .measureTabBar(tabBarMetrics)
      }

      Tab("Search", systemImage: "magnifyingglass", value: AppNav.Tab.search, role: .search) {
        WithAccountOnly { Search(nav: appNav.search) }
          .id("search-\(accountScopeKey)")
          .measureTabBar(tabBarMetrics)
      }

      Tab("Settings", systemImage: "gearshape.fill", value: AppNav.Tab.settings) {
        Settings(nav: appNav.settings)
          .measureTabBar(tabBarMetrics)
      }
    }
    .tabViewStyle(.sidebarAdaptable)
    .tabBarMinimizeBehavior(.onScrollDown)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          appNav.resetSelectedSurfaceToTabRoot()
        } label: {
          Label("Root", systemImage: "arrow.uturn.backward")
        }
        .disabled(!appNav.canResetSelectedSurfaceToTabRoot)
      }
    }
    .background(
      TabReselectBridge(tabOrder: Self.tabOrder) { tab in
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

    func attachIfPossible(from controller: UIViewController) {
      guard let tabBarController = findTabBarController(from: controller) else { return }
      guard self.tabBarController !== tabBarController || tabBarController.delegate !== self else { return }

      if tabBarController.delegate !== self {
        previousDelegate = tabBarController.delegate
      }
      self.tabBarController = tabBarController
      tabBarController.delegate = self
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
      previousDelegate?.tabBarController?(tabBarController, didSelect: viewController)
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
