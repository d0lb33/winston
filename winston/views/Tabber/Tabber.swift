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
  @EnvironmentObject private var accountSwitcher: AccountSwitcherTransmitter
  
  @State private var tabReselectDetectionEnabled = false
  
  @Environment(\.useTheme) private var currentTheme
  @Environment(\.colorScheme) private var colorScheme
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
  
  var body: some View {
    let accountScopeKey = wire.accountScopeID?.uuidString ?? "none"
    let meTabTitle = appearanceDefSettings.showUsernameInTabBar ? (wire.me?.data?.name ?? "Me") : "Me"
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
      Tab("Posts", systemImage: "doc.text.image", value: Nav.TabIdentifier.posts) {
        WithAccountOnly { SubredditsStack(router: nav[.posts]) }
          .id("posts-\(accountScopeKey)")
          .measureTabBar(tabBarMetrics)
      }

      Tab("Inbox", systemImage: "bell.fill", value: Nav.TabIdentifier.inbox) {
        WithAccountOnly { Inbox(router: nav[.inbox]) }
          .id("inbox-\(accountScopeKey)")
          .measureTabBar(tabBarMetrics)
      }

      Tab(meTabTitle, systemImage: "person.fill", value: Nav.TabIdentifier.me) {
        WithAccountOnly { Me(router: nav[.me]) }
          .id("me-\(accountScopeKey)")
          .measureTabBar(tabBarMetrics)
      }

      Tab("Search", systemImage: "magnifyingglass", value: Nav.TabIdentifier.search, role: .search) {
        WithAccountOnly { Search(router: nav[.search]) }
          .id("search-\(accountScopeKey)")
          .measureTabBar(tabBarMetrics)
      }

      Tab("Settings", systemImage: "gearshape.fill", value: Nav.TabIdentifier.settings) {
        Settings(router: nav[.settings])
          .measureTabBar(tabBarMetrics)
      }
    }
    .tabViewStyle(.sidebarAdaptable)
    .tabBarMinimizeBehavior(.onScrollDown)
    .overlay {      TabBarOverlay {
        handleMeTabTap()
      }
    }
    .background(TabBarReselectAccessor(tabInteractions: tabInteractions, accountSwitcher: accountSwitcher, meTabTitle: meTabTitle).allowsHitTesting(false))
    .environmentObject(tabInteractions)
    .environment(\.videoDefSettings, videoDefSettings)
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

  private func handleMeTabTap() {
    if nav.activeTab == .me {
      AppDiagnostics.asyncBreadcrumb("Selected tab tapped again", metadata: ["tab": Nav.TabIdentifier.me.rawValue, "source": "meTabOverlay"])
      tabInteractions.selectedTabTappedAgain(.me)
    } else {
      nav.activeTab = .me
    }
  }
}

private struct TabBarReselectAccessor: UIViewRepresentable {
  @ObservedObject var tabInteractions: TabInteractionCenter
  let accountSwitcher: AccountSwitcherTransmitter
  let meTabTitle: String

  func makeUIView(context: Context) -> AccessorView {
    let view = AccessorView()
    view.coordinator = context.coordinator
    context.coordinator.tabInteractions = tabInteractions
    context.coordinator.transmitter = accountSwitcher
    context.coordinator.meTabTitle = meTabTitle
    return view
  }

  func updateUIView(_ uiView: AccessorView, context: Context) {
    context.coordinator.tabInteractions = tabInteractions
    context.coordinator.transmitter = accountSwitcher
    context.coordinator.meTabTitle = meTabTitle
    context.coordinator.attachIfPossible(from: uiView)
    context.coordinator.handleTabBarRevealRequest(from: uiView)
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
    var transmitter: AccountSwitcherTransmitter?
    var meTabTitle = "Me"
    private weak var sourceView: UIView?
    private weak var attachedTabBar: UITabBar?
    private weak var pendingSelectedControl: UIControl?
    private var attachedControls: [UIControl] = []
    private weak var meLongPressControl: UIControl?
    private var meLongPress: UILongPressGestureRecognizer?
    private var lastHandledTabBarRevealRequestID: UUID?
    private let haptics = UIImpactFeedbackGenerator(style: .soft)
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

    func handleTabBarRevealRequest(from view: UIView) {
      guard let request = tabInteractions?.tabBarRevealRequest,
            lastHandledTabBarRevealRequestID != request.id else { return }
      lastHandledTabBarRevealRequestID = request.id

      guard let tabBarController = findTabBarController(from: view) else { return }
      revealTabBar(tabBarController, tab: request.tab)
    }

    func detach() {
      for control in attachedControls {
        control.removeTarget(self, action: #selector(tabButtonTouchDown(_:)), for: .touchDown)
        control.removeTarget(self, action: #selector(tabButtonTouchUpInside(_:)), for: .touchUpInside)
        control.removeTarget(self, action: #selector(tabButtonTouchCancelled(_:)), for: .touchCancel)
        control.removeTarget(self, action: #selector(tabButtonTouchCancelled(_:)), for: .touchDragExit)
      }
      detachMeLongPress()
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
        attachMeLongPress(controls: controls)
        AppDiagnostics.asyncBreadcrumb("Tab bar reselect control accessor attached", metadata: ["controls": "\(controls.count)"])
      }

      attachAttempts = 0
    }

    private func revealTabBar(_ tabBarController: UITabBarController, tab: Nav.TabIdentifier) {
      guard #available(iOS 18.0, *) else { return }
      tabBarController.setTabBarHidden(false, animated: true)
      AppDiagnostics.asyncBreadcrumb("Tab bar reveal performed", metadata: ["tab": tab.rawValue])
    }

    // MARK: Account switcher — long-press the Me tab control

    private func attachMeLongPress(controls: [UIControl]) {
      detachMeLongPress()
      guard let control = meTabControl(in: controls) else { return }
      let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleMeLongPress(_:)))
      recognizer.minimumPressDuration = 0.18
      control.addGestureRecognizer(recognizer)
      meLongPress = recognizer
      meLongPressControl = control
    }

    private func detachMeLongPress() {
      if let meLongPress, let meLongPressControl {
        meLongPressControl.removeGestureRecognizer(meLongPress)
      }
      meLongPress = nil
      meLongPressControl = nil
    }

    @objc private func handleMeLongPress(_ sender: UILongPressGestureRecognizer) {
      guard let transmitter else { return }
      let targetView = sender.view?.window?.rootViewController?.view
      let location = sender.location(in: targetView)
      switch sender.state {
      case .began:
        pendingSelectedControl = nil
        haptics.prepare()
        haptics.impactOccurred()
        if let view = targetView {
          let renderer = UIGraphicsImageRenderer(size: view.bounds.size)
          transmitter.screenshot = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
          }
        }
        transmitter.positionInfo = .init(location)
        transmitter.showing = true
      case .changed:
        transmitter.positionInfo?.location = location
      case .ended, .cancelled, .failed:
        if transmitter.showing { transmitter.showing = false }
      default:
        break
      }
    }

    private func meTabControl(in controls: [UIControl]) -> UIControl? {
      if let match = controls.first(where: { controlContainsText($0, meTabTitle) || controlContainsText($0, "Me") }) {
        return match
      }
      guard let meIndex = Nav.TabIdentifier.allCases.firstIndex(of: .me),
            controls.indices.contains(meIndex) else { return nil }
      return controls[meIndex]
    }

    private func controlContainsText(_ control: UIControl, _ text: String) -> Bool {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return false }
      return accessibilityText(in: control).contains { value in
        value.localizedCaseInsensitiveContains(trimmed)
      }
    }

    private func accessibilityText(in view: UIView) -> [String] {
      var values: [String] = []
      if let label = view.accessibilityLabel, !label.isEmpty {
        values.append(label)
      }
      if let identifier = view.accessibilityIdentifier, !identifier.isEmpty {
        values.append(identifier)
      }
      if let label = view as? UILabel, let text = label.text, !text.isEmpty {
        values.append(text)
      }
      for subview in view.subviews {
        values.append(contentsOf: accessibilityText(in: subview))
      }
      return values
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
