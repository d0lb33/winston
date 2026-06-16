//
//  Nav.swift
//  winston
//
//  Created by Igor Marcossi on 08/12/23.
//

import Foundation
import Combine
import UIKit
import SwiftUI

class Nav: ObservableObject, Identifiable, Equatable {
  static let shared = Nav()
  static let router = Nav.shared.activeRouter
  
  /* <Util static functions for ease of use> */
  static func back() { Nav.shared.activeRouter.goBack() }
  static func to(_ dest: Router.NavDest, _ reset: Bool = false) {
    AppDiagnostics.asyncBreadcrumb("Nav.to", metadata: ["destination": dest.diagnosticsName, "reset": "\(reset)"])
    Nav.shared.activeRouter.navigateTo(dest, reset)
  }
  static func fullTo(_ tab: TabIdentifier, _ dest: Router.NavDest, _ reset: Bool = false) {
    AppDiagnostics.asyncBreadcrumb("Nav.fullTo", metadata: ["tab": tab.rawValue, "destination": dest.diagnosticsName, "reset": "\(reset)"])
    Nav.shared.navigateTo(tab, dest, reset)
  }
  static func present(_ content: PresentingSheet?) {
    AppDiagnostics.asyncBreadcrumb("Nav.present", metadata: ["sheet": content?.diagnosticsName ?? "nil"])
    Nav.shared.presentingSheet = content
  }
  static func resetStack() {
    AppDiagnostics.asyncBreadcrumb("Nav.resetStack", metadata: ["tab": Nav.shared.activeTab.rawValue])
    Nav.shared.activeRouter.requestRootReset()
  }
  /* </Util static functions for ease of use> */
  
  static let swipeAnywhereGestureName = "swipe-anywhere-winston"
  
  static private func newRouterForTab(_ tab: TabIdentifier, _ id: UUID) -> Router { Router(id: "\(tab.rawValue)TabRouter-\(id.uuidString)") }
    
  enum TabIdentifier: String, Codable, Hashable, CaseIterable {
    case posts, inbox, me, search, settings
  }
  
  enum PresentingSheet: Codable, Hashable, Identifiable, Equatable {
    case tipJar
    case onboarding
    case announcement(Announcement)
    
    var id: String {
      var newID: String = ""
      switch self {
      case .announcement(let ann): newID = ann.id
      case .tipJar: newID = "tipJar"
      case .onboarding: newID = "onboarding"
      }
      return "\(newID)-presenting-sheet-Nav"
    }
  }
  
  var id: UUID
  @Published var activeTab: TabIdentifier {
    willSet {
      guard activeTab != newValue else { return }
      AppDiagnostics.asyncBreadcrumb("Tab changed", metadata: ["from": activeTab.rawValue, "to": newValue.rawValue])
    }
  }
  private var routers: [TabIdentifier:Router]
  @Published var presentingSheetsQueue: [PresentingSheet] = []
  var presentingSheet: PresentingSheet? {
    get { presentingSheetsQueue.isEmpty ? nil : presentingSheetsQueue[0] }
    set {
      if let newValue {
        if !presentingSheetsQueue.isEmpty && presentingSheetsQueue.first == newValue {
          presentingSheetsQueue[0] = newValue
        } else {
          presentingSheetsQueue.insert(newValue, at: 0)
        }
      } else if !presentingSheetsQueue.isEmpty { presentingSheetsQueue.removeFirst() }
    }
  }
  var activeRouter: Router { Nav.shared[activeTab] }
  private var cancellables = Set<AnyCancellable>()

  
  private init(activeTab: TabIdentifier = .posts) {
    let newSwipeAnywhereGesture: UIPanGestureRecognizer = {
      let gesture = UIPanGestureRecognizer()
      gesture.name = Self.swipeAnywhereGestureName
      gesture.isEnabled = true
      return gesture
    }()
    
    let id = UUID()
    self.id = id
    self.activeTab = activeTab
    self.routers = Dictionary(uniqueKeysWithValues: TabIdentifier.allCases.map { ($0, Self.newRouterForTab($0, id)) })
    
    self.routers.values.forEach { router in
      router.$isAtRoot.sink { _ in
          self.objectWillChange.send()
        }
        .store(in: &cancellables)
    }
  }
  
  func navigateTo(_ tab: TabIdentifier, _ dest: Router.NavDest, _ reset: Bool = true) {
    AppDiagnostics.asyncBreadcrumb("Nav.navigateTo tab", metadata: ["tab": tab.rawValue, "destination": dest.diagnosticsName, "reset": "\(reset)"])
    routers[tab]?.navigateTo(dest, reset)
    if tab != activeTab {	activeTab = tab }
  }
  
  func resetStack() {
    AppDiagnostics.asyncBreadcrumb("Nav.resetStack instance", metadata: ["tab": activeTab.rawValue])
    activeRouter.requestRootReset()
  }

  @MainActor
  func resetAccountScopedStacks() {
    AppDiagnostics.asyncBreadcrumb("Nav.resetAccountScopedStacks")
    [TabIdentifier.posts, .inbox, .me, .search].forEach { tab in
      routers[tab]?.resetNavPath()
    }
    if activeTab != .settings {
      activeTab = .posts
    }
  }
  
  subscript(tab: TabIdentifier) -> Router {
    let router = self.routers[tab] ?? Self.newRouterForTab(tab, id)
    if self.routers[tab] == nil { self.routers[tab] = router }
    return router
  }
  
  enum CodingKeys: String, CodingKey {
    case id, activeTab, routers
  }
  
  static func == (lhs: Nav, rhs: Nav) -> Bool {
    lhs.id == rhs.id
  }
  
  static func openURL(_ url: URL) {
    UIApplication.shared.open(url)
  }


  static func openURL(_ urlStr: String) {
    if let url = URL(string: urlStr)  {
      openURL(url)
    }
  }
}

enum TabInteractionRequestKind: Equatable {
  case scrollToTop
  case goBack
  case resetToRoot
}

struct TabInteractionRequest: Equatable {
  let id = UUID()
  let kind: TabInteractionRequestKind
}

@MainActor
final class TabInteractionCenter: ObservableObject {
  @Published private(set) var requests: [Nav.TabIdentifier: TabInteractionRequest] = [:]

  private var isAtTopByTab: [Nav.TabIdentifier: Bool] = [:]
  private var lastTap: (tab: Nav.TabIdentifier, date: Date)?
  private let doubleTapInterval: TimeInterval = 0.3

  func selectedTabChanged(to tab: Nav.TabIdentifier) {
    lastTap = nil
    isAtTopByTab[tab] = isAtTopByTab[tab] ?? true
  }

  func setIsAtTop(_ tab: Nav.TabIdentifier, _ isAtTop: Bool) {
    isAtTopByTab[tab] = isAtTop
  }

  func selectedTabTappedAgain(_ tab: Nav.TabIdentifier) {
    let now = Date()
    if let lastTap,
       lastTap.tab == tab,
       now.timeIntervalSince(lastTap.date) <= doubleTapInterval {
      self.lastTap = nil
      publish(.resetToRoot, for: tab)
      return
    }

    lastTap = (tab, now)
    publish((isAtTopByTab[tab] == false) ? .scrollToTop : .goBack, for: tab)
  }

  private func publish(_ kind: TabInteractionRequestKind, for tab: Nav.TabIdentifier) {
    requests[tab] = TabInteractionRequest(kind: kind)
    AppDiagnostics.asyncBreadcrumb(
      "Tab interaction request",
      metadata: ["tab": tab.rawValue, "kind": "\(kind)"]
    )
  }
}

struct TabScrollRoot<Content: View>: View {
  private let topID: String
  private let tab: Nav.TabIdentifier?
  private let tabInteractions: TabInteractionCenter?
  private let request: TabInteractionRequest?
  private let onResetToRoot: (() -> Void)?
  private let onOffsetChange: (CGFloat) -> Void
  private let content: () -> Content

  init(
    topID: String,
    tab: Nav.TabIdentifier?,
    tabInteractions: TabInteractionCenter?,
    request: TabInteractionRequest?,
    onResetToRoot: (() -> Void)? = nil,
    onOffsetChange: @escaping (CGFloat) -> Void = { _ in },
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.topID = topID
    self.tab = tab
    self.tabInteractions = tabInteractions
    self.request = request
    self.onResetToRoot = onResetToRoot
    self.onOffsetChange = onOffsetChange
    self.content = content
  }

  var body: some View {
    ScrollViewReader { proxy in
      List {
        Color.clear
          .frame(height: 0)
          .id(topID)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())

        content()
      }
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        geometry.contentOffset.y
      } action: { _, newOffsetY in
        if let tab, let tabInteractions {
          tabInteractions.setIsAtTop(tab, newOffsetY <= 4)
        }
        onOffsetChange(newOffsetY)
      }
      .onAppear {
        if let tab, let tabInteractions {
          tabInteractions.setIsAtTop(tab, true)
        }
      }
      .onChange(of: request) { _, request in
        guard let request else { return }
        if request.kind == .resetToRoot {
          onResetToRoot?()
        }
        guard request.kind == .scrollToTop || request.kind == .resetToRoot else { return }
        withAnimation(.snappy) {
          proxy.scrollTo(topID, anchor: .top)
        }
        if let tab, let tabInteractions {
          tabInteractions.setIsAtTop(tab, true)
        }
      }
    }
  }
}

struct TabSelectableScrollRoot<Selection: Hashable, Content: View>: View {
  private let topID: String
  private let tab: Nav.TabIdentifier?
  private let tabInteractions: TabInteractionCenter?
  private let request: TabInteractionRequest?
  private let onResetToRoot: (() -> Void)?
  private let onOffsetChange: (CGFloat) -> Void
  @Binding private var selection: Selection?
  private let content: () -> Content

  init(
    topID: String,
    tab: Nav.TabIdentifier?,
    tabInteractions: TabInteractionCenter?,
    request: TabInteractionRequest?,
    selection: Binding<Selection?>,
    onResetToRoot: (() -> Void)? = nil,
    onOffsetChange: @escaping (CGFloat) -> Void = { _ in },
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.topID = topID
    self.tab = tab
    self.tabInteractions = tabInteractions
    self.request = request
    self._selection = selection
    self.onResetToRoot = onResetToRoot
    self.onOffsetChange = onOffsetChange
    self.content = content
  }

  var body: some View {
    ScrollViewReader { proxy in
      List(selection: $selection) {
        Color.clear
          .frame(height: 0)
          .id(topID)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())

        content()
      }
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        geometry.contentOffset.y
      } action: { _, newOffsetY in
        if let tab, let tabInteractions {
          tabInteractions.setIsAtTop(tab, newOffsetY <= 4)
        }
        onOffsetChange(newOffsetY)
      }
      .onAppear {
        if let tab, let tabInteractions {
          tabInteractions.setIsAtTop(tab, true)
        }
      }
      .onChange(of: request) { _, request in
        guard let request else { return }
        if request.kind == .resetToRoot {
          onResetToRoot?()
        }
        guard request.kind == .scrollToTop || request.kind == .resetToRoot else { return }
        withAnimation(.snappy) {
          proxy.scrollTo(topID, anchor: .top)
        }
        if let tab, let tabInteractions {
          tabInteractions.setIsAtTop(tab, true)
        }
      }
    }
  }
}

extension Nav.PresentingSheet {
  var diagnosticsName: String {
    switch self {
    case .tipJar: return "sheet.tipJar"
    case .onboarding: return "sheet.onboarding"
    case .announcement(let announcement): return "sheet.announcement.\(announcement.id)"
    }
  }
}
