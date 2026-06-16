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
  
  @ObservedObject private var nav = Nav.shared
  @ObservedObject private var wire = RedditWire.shared
  @StateObject private var tabInteractions = TabInteractionCenter()
  
  @State private var tabReselectDetectionEnabled = false
  
  @Environment(\.useTheme) private var currentTheme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(TabBarMetrics.self) private var tabBarMetrics
  @Default(.AppearanceDefSettings) private var appearanceDefSettings
  
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
  
  var body: some View {
    let accountScopeKey = wire.accountScopeID?.uuidString ?? "none"
    let tabSelection = Binding<Nav.TabIdentifier>(
      get: { nav.activeTab },
      set: { tab in
        if tab == nav.activeTab {
          guard tabReselectDetectionEnabled else { return }
          AppDiagnostics.asyncBreadcrumb("Selected tab tapped again", metadata: ["tab": tab.rawValue, "source": "selectionBinding"])
          tabInteractions.selectedTabTappedAgain(tab)
        } else {
          nav.activeTab = tab
        }
      }
    )

    TabView(selection: tabSelection) {
      
      WithAccountOnly {
        SubredditsStack(router: nav[.posts])
      }
      .id("posts-\(accountScopeKey)")
      .measureTabBar(tabBarMetrics)
      .tag(Nav.TabIdentifier.posts)
      .tabItem { Label("Posts", systemImage: "doc.text.image") }
      
      WithAccountOnly {
        Inbox(router: nav[.inbox])
      }
      .id("inbox-\(accountScopeKey)")
      .measureTabBar(tabBarMetrics)
      .tag(Nav.TabIdentifier.inbox)
      .tabItem { Label("Inbox", systemImage: "bell.fill") }
      
      WithAccountOnly {
        Me(router: nav[.me])
      }
      .id("me-\(accountScopeKey)")
      .measureTabBar(tabBarMetrics)
      .tag(Nav.TabIdentifier.me)
      .tabItem { Label(appearanceDefSettings.showUsernameInTabBar ? wire.me?.data?.name ?? "Me" : "Me", systemImage: "person.fill") }
//      
      WithAccountOnly {
        Search(router: nav[.search])
      }
      .id("search-\(accountScopeKey)")
      .measureTabBar(tabBarMetrics)
      .tag(Nav.TabIdentifier.search)
      .tabItem { Label("Search", systemImage: "magnifyingglass") }
      
      Settings(router: nav[.settings])
        .measureTabBar(tabBarMetrics)
        .tag(Nav.TabIdentifier.settings)
        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
      
    }
    .background(TabBarReselectAccessor(tabInteractions: tabInteractions).allowsHitTesting(false))
    .environmentObject(tabInteractions)
    .onAppear {
      tabInteractions.selectedTabChanged(to: nav.activeTab)
      DispatchQueue.main.async {
        tabReselectDetectionEnabled = true
      }
    }
    .onChange(of: nav.activeTab) { _, tab in
      tabInteractions.selectedTabChanged(to: tab)
    }
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

private struct TabBarReselectAccessor: UIViewRepresentable {
  @ObservedObject var tabInteractions: TabInteractionCenter

  func makeUIView(context: Context) -> AccessorView {
    let view = AccessorView()
    view.coordinator = context.coordinator
    context.coordinator.tabInteractions = tabInteractions
    return view
  }

  func updateUIView(_ uiView: AccessorView, context: Context) {
    context.coordinator.tabInteractions = tabInteractions
    context.coordinator.attachIfPossible(from: uiView)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  @MainActor
  final class AccessorView: UIView {
    weak var coordinator: Coordinator?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard window != nil else {
        coordinator?.detach()
        return
      }
      coordinator?.resetAttachAttempts()
      coordinator?.attachIfPossible(from: self)
    }
  }

  @MainActor
  final class Coordinator: NSObject {
    weak var tabInteractions: TabInteractionCenter?
    private weak var sourceView: UIView?
    private weak var attachedTabBar: UITabBar?
    private weak var pendingSelectedControl: UIControl?
    private var attachedControls: [UIControl] = []
    private var attachAttempts = 0
    private let maxAttachAttempts = 8

    func resetAttachAttempts() {
      attachAttempts = 0
    }

    func attachIfPossible(from view: UIView) {
      sourceView = view

      guard view.window != nil else {
        scheduleRetry()
        return
      }

      guard let tabBarController = findTabBarController(from: view) else {
        scheduleRetry()
        return
      }

      attach(to: tabBarController.tabBar)
    }

    func detach() {
      for control in attachedControls {
        control.removeTarget(self, action: #selector(tabButtonTouchDown(_:)), for: .touchDown)
        control.removeTarget(self, action: #selector(tabButtonTouchUpInside(_:)), for: .touchUpInside)
        control.removeTarget(self, action: #selector(tabButtonTouchCancelled(_:)), for: .touchCancel)
        control.removeTarget(self, action: #selector(tabButtonTouchCancelled(_:)), for: .touchDragExit)
      }
      attachedControls = []
      attachedTabBar = nil
      pendingSelectedControl = nil
    }

    private func attach(to tabBar: UITabBar) {
      let controls = tabControls(in: tabBar)
      guard !controls.isEmpty else {
        scheduleRetry()
        return
      }

      if attachedTabBar !== tabBar || controls != attachedControls {
        detach()
        for control in controls {
          control.addTarget(self, action: #selector(tabButtonTouchDown(_:)), for: .touchDown)
          control.addTarget(self, action: #selector(tabButtonTouchUpInside(_:)), for: .touchUpInside)
          control.addTarget(self, action: #selector(tabButtonTouchCancelled(_:)), for: .touchCancel)
          control.addTarget(self, action: #selector(tabButtonTouchCancelled(_:)), for: .touchDragExit)
        }
        attachedControls = controls
        attachedTabBar = tabBar
        AppDiagnostics.asyncBreadcrumb("Tab bar reselect control accessor attached", metadata: ["controls": "\(controls.count)"])
      }

      attachAttempts = 0
    }

    private func scheduleRetry() {
      guard attachAttempts < maxAttachAttempts else { return }
      attachAttempts += 1
      DispatchQueue.main.async { [weak self] in
        guard let self, let sourceView else { return }
        self.attachIfPossible(from: sourceView)
      }
    }

    @objc private func tabButtonTouchDown(_ sender: UIControl) {
      guard isSelectedControl(sender) else {
        pendingSelectedControl = nil
        return
      }
      pendingSelectedControl = sender
    }

    @objc private func tabButtonTouchUpInside(_ sender: UIControl) {
      guard pendingSelectedControl === sender else { return }
      pendingSelectedControl = nil
      let tab = Nav.shared.activeTab
      AppDiagnostics.asyncBreadcrumb("Selected tab tapped again", metadata: ["tab": tab.rawValue, "source": "tabButtonControl"])
      tabInteractions?.selectedTabTappedAgain(tab)
    }

    @objc private func tabButtonTouchCancelled(_ sender: UIControl) {
      if pendingSelectedControl === sender {
        pendingSelectedControl = nil
      }
    }

    private func isSelectedControl(_ control: UIControl) -> Bool {
      guard let tabBar = attachedTabBar,
            let items = tabBar.items,
            let selectedItem = tabBar.selectedItem,
            let selectedIndex = items.firstIndex(of: selectedItem)
      else { return false }

      let controls = tabControls(in: tabBar)
      guard selectedIndex < controls.count else { return false }
      return controls[selectedIndex] === control
    }

    private func tabControls(in tabBar: UITabBar) -> [UIControl] {
      tabBar.subviews
        .compactMap { $0 as? UIControl }
        .filter { !$0.isHidden && $0.alpha > 0.01 && $0.frame.width > 0 && $0.frame.height > 0 }
        .sorted { $0.frame.minX < $1.frame.minX }
    }

    private func findTabBarController(from view: UIView) -> UITabBarController? {
      if let responderController = sequence(first: view.next, next: { $0?.next })
        .first(where: { $0 is UITabBarController }) as? UITabBarController {
        return responderController
      }

      guard let root = view.window?.rootViewController else { return nil }
      return findTabBarController(in: root)
    }

    private func findTabBarController(in controller: UIViewController) -> UITabBarController? {
      if let tabBarController = controller as? UITabBarController {
        return tabBarController
      }

      if let presented = controller.presentedViewController,
         let tabBarController = findTabBarController(in: presented) {
        return tabBarController
      }

      for child in controller.children {
        if let tabBarController = findTabBarController(in: child) {
          return tabBarController
        }
      }

      if let navigationController = controller as? UINavigationController {
        for viewController in navigationController.viewControllers {
          if let tabBarController = findTabBarController(in: viewController) {
            return tabBarController
          }
        }
      }

      return nil
    }
  }
}
