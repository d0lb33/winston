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

@MainActor
class Nav: ObservableObject, Identifiable, Equatable {
  static let shared = Nav()
  static let router = Nav.shared.activeRouter
  
  /* <Util static functions for ease of use> */
  static func back() { Nav.shared.activeRouter.goBack() }
  static func to(_ dest: NavDest, _ reset: Bool = false) {
    AppDiagnostics.asyncBreadcrumb("Nav.to", metadata: ["destination": dest.diagnosticsName, "reset": "\(reset)"])
    Nav.shared.activeRouter.navigateTo(dest, reset)
  }
  static func fullTo(_ tab: TabIdentifier, _ dest: NavDest, _ reset: Bool = false) {
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
  
  func navigateTo(_ tab: TabIdentifier, _ dest: NavDest, _ reset: Bool = true) {
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

struct TabInteractionOwnerID: Hashable, Equatable, CustomStringConvertible, ExpressibleByStringLiteral {
  let rawValue: String

  init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  init(stringLiteral value: StringLiteralType) {
    self.rawValue = value
  }

  var description: String { rawValue }
}

private struct TabInteractionTabKey: EnvironmentKey {
  static let defaultValue: Nav.TabIdentifier? = nil
}

private struct TabInteractionCenterKey: EnvironmentKey {
  static let defaultValue: TabInteractionCenter? = nil
}

private struct TabInteractionRequestKey: EnvironmentKey {
  static let defaultValue: TabInteractionRequest? = nil
}

extension EnvironmentValues {
  var tabInteractionTab: Nav.TabIdentifier? {
    get { self[TabInteractionTabKey.self] }
    set { self[TabInteractionTabKey.self] = newValue }
  }

  var tabInteractionCenter: TabInteractionCenter? {
    get { self[TabInteractionCenterKey.self] }
    set { self[TabInteractionCenterKey.self] = newValue }
  }

  var tabInteractionRequest: TabInteractionRequest? {
    get { self[TabInteractionRequestKey.self] }
    set { self[TabInteractionRequestKey.self] = newValue }
  }
}

@MainActor
final class TabInteractionCenter: ObservableObject {
  @Published private(set) var requests: [Nav.TabIdentifier: TabInteractionRequest] = [:]

  private struct ScrollOwnerState {
    var ownerID: TabInteractionOwnerID
    var isAtTop: Bool
  }

  private var scrollOwnerStateByTab: [Nav.TabIdentifier: ScrollOwnerState] = [:]
  private var lastTap: (tab: Nav.TabIdentifier, date: Date)?
  private var lastReselectEvent: (tab: Nav.TabIdentifier, date: Date)?
  private let doubleTapInterval: TimeInterval = 0.3
  private let duplicateEventInterval: TimeInterval = 0.05

  func selectedTabChanged(to tab: Nav.TabIdentifier) {
    lastTap = nil
    if scrollOwnerStateByTab[tab] == nil {
      scrollOwnerStateByTab[tab] = ScrollOwnerState(ownerID: legacyOwnerID(for: tab), isAtTop: true)
    }
  }

  func activateScrollOwner(_ ownerID: TabInteractionOwnerID, for tab: Nav.TabIdentifier, initialIsAtTop: Bool = false) {
    guard scrollOwnerStateByTab[tab]?.ownerID != ownerID else { return }
    scrollOwnerStateByTab[tab] = ScrollOwnerState(ownerID: ownerID, isAtTop: initialIsAtTop)
    AppDiagnostics.asyncBreadcrumb(
      "Tab interaction owner activated",
      metadata: ["tab": tab.rawValue, "owner": ownerID.rawValue, "isAtTop": "\(initialIsAtTop)"]
    )
  }

  func deactivateScrollOwner(_ ownerID: TabInteractionOwnerID, for tab: Nav.TabIdentifier) {
    guard scrollOwnerStateByTab[tab]?.ownerID == ownerID else { return }
    scrollOwnerStateByTab.removeValue(forKey: tab)
    AppDiagnostics.asyncBreadcrumb(
      "Tab interaction owner deactivated",
      metadata: ["tab": tab.rawValue, "owner": ownerID.rawValue]
    )
  }

  func setIsAtTop(_ tab: Nav.TabIdentifier, _ isAtTop: Bool) {
    let ownerID = scrollOwnerStateByTab[tab]?.ownerID ?? legacyOwnerID(for: tab)
    scrollOwnerStateByTab[tab] = ScrollOwnerState(ownerID: ownerID, isAtTop: isAtTop)
  }

  func setIsAtTop(_ tab: Nav.TabIdentifier, _ isAtTop: Bool, ownerID: TabInteractionOwnerID) {
    guard scrollOwnerStateByTab[tab]?.ownerID == ownerID else { return }
    scrollOwnerStateByTab[tab]?.isAtTop = isAtTop
  }

  func isActiveOwner(_ ownerID: TabInteractionOwnerID, for tab: Nav.TabIdentifier) -> Bool {
    scrollOwnerStateByTab[tab]?.ownerID == ownerID
  }

  func selectedTabTappedAgain(_ tab: Nav.TabIdentifier) {
    let now = Date()
    if let lastReselectEvent,
       lastReselectEvent.tab == tab,
       now.timeIntervalSince(lastReselectEvent.date) <= duplicateEventInterval {
      return
    }

    lastReselectEvent = (tab, now)

    if let lastTap,
       lastTap.tab == tab,
       now.timeIntervalSince(lastTap.date) <= doubleTapInterval {
      self.lastTap = nil
      publish(.resetToRoot, for: tab)
      return
    }

    lastTap = (tab, now)
    publish((scrollOwnerStateByTab[tab]?.isAtTop == false) ? .scrollToTop : .goBack, for: tab)
  }

  private func legacyOwnerID(for tab: Nav.TabIdentifier) -> TabInteractionOwnerID {
    TabInteractionOwnerID("legacy.\(tab.rawValue)")
  }

  private func publish(_ kind: TabInteractionRequestKind, for tab: Nav.TabIdentifier) {
    requests[tab] = TabInteractionRequest(kind: kind)
    AppDiagnostics.asyncBreadcrumb(
      "Tab interaction request",
      metadata: ["tab": tab.rawValue, "kind": "\(kind)"]
    )
  }
}

struct TabScrollRoot<Selection: Hashable, Content: View>: View {
  private let topID: String
  private let ownerID: TabInteractionOwnerID
  private let tab: Nav.TabIdentifier?
  private let tabInteractions: TabInteractionCenter?
  private let request: TabInteractionRequest?
  private let selection: Binding<Selection?>?
  private let scrollPosition: Binding<Selection?>?
  private let onResetToRoot: (() -> Void)?
  private let onOffsetChange: (CGFloat) -> Void
  private let content: () -> Content

  init(
    topID: String,
    ownerID: TabInteractionOwnerID? = nil,
    tab: Nav.TabIdentifier?,
    tabInteractions: TabInteractionCenter?,
    request: TabInteractionRequest?,
    selection: Binding<Selection?>,
    scrollPosition: Binding<Selection?>? = nil,
    onResetToRoot: (() -> Void)? = nil,
    onOffsetChange: @escaping (CGFloat) -> Void = { _ in },
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.topID = topID
    self.ownerID = ownerID ?? TabInteractionOwnerID(topID)
    self.tab = tab
    self.tabInteractions = tabInteractions
    self.request = request
    self.selection = selection
    self.scrollPosition = scrollPosition
    self.onResetToRoot = onResetToRoot
    self.onOffsetChange = onOffsetChange
    self.content = content
  }

  var body: some View {
    ScrollViewReader { proxy in
      TabScrollList(selection: selection, scrollPosition: scrollPosition) {
        Color.clear
          .frame(height: 0)
          .id(topID)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())

        content()
      }
      // Without this, SwiftUI's ~44pt default minimum row height inflates the
      // zero-height top anchor row into a large gap under the nav bar.
      .environment(\.defaultMinListRowHeight, 1)
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        geometry.contentOffset.y
      } action: { _, newOffsetY in
        if let tab, let tabInteractions {
          tabInteractions.setIsAtTop(tab, newOffsetY <= 4, ownerID: ownerID)
        }
        onOffsetChange(newOffsetY)
      }
      .onAppear {
        activateOwner()
      }
      .onDisappear {
        deactivateOwner()
      }
      .onChange(of: tab) { oldTab, newTab in
        if let oldTab, let tabInteractions {
          tabInteractions.deactivateScrollOwner(ownerID, for: oldTab)
        }
        if newTab != nil {
          activateOwner()
        }
      }
      .onChange(of: ownerID) { oldOwnerID, _ in
        if let tab, let tabInteractions {
          tabInteractions.deactivateScrollOwner(oldOwnerID, for: tab)
        }
        activateOwner()
      }
      .onChange(of: request) { _, request in
        guard let request else { return }
        if request.kind == .resetToRoot {
          onResetToRoot?()
        }
        guard request.kind == .scrollToTop || request.kind == .resetToRoot else { return }
        guard tab.map({ tabInteractions?.isActiveOwner(ownerID, for: $0) == true }) ?? false else { return }
        withAnimation(.snappy) {
          proxy.scrollTo(topID, anchor: .top)
        }
        if let tab, let tabInteractions {
          tabInteractions.setIsAtTop(tab, true, ownerID: ownerID)
        }
      }
    }
  }

  private func activateOwner() {
    guard let tab, let tabInteractions else { return }
    tabInteractions.activateScrollOwner(ownerID, for: tab, initialIsAtTop: false)
  }

  private func deactivateOwner() {
    guard let tab, let tabInteractions else { return }
    tabInteractions.deactivateScrollOwner(ownerID, for: tab)
  }
}

extension TabScrollRoot where Selection == Never {
  init(
    topID: String,
    ownerID: TabInteractionOwnerID? = nil,
    tab: Nav.TabIdentifier?,
    tabInteractions: TabInteractionCenter?,
    request: TabInteractionRequest?,
    onResetToRoot: (() -> Void)? = nil,
    onOffsetChange: @escaping (CGFloat) -> Void = { _ in },
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.topID = topID
    self.ownerID = ownerID ?? TabInteractionOwnerID(topID)
    self.tab = tab
    self.tabInteractions = tabInteractions
    self.request = request
    self.selection = nil
    self.scrollPosition = nil
    self.onResetToRoot = onResetToRoot
    self.onOffsetChange = onOffsetChange
    self.content = content
  }
}

private struct TabScrollList<Selection: Hashable, Rows: View>: View {
  let selection: Binding<Selection?>?
  let scrollPosition: Binding<Selection?>?
  let rows: () -> Rows

  init(
    selection: Binding<Selection?>?,
    scrollPosition: Binding<Selection?>?,
    @ViewBuilder rows: @escaping () -> Rows
  ) {
    self.selection = selection
    self.scrollPosition = scrollPosition
    self.rows = rows
  }

  @ViewBuilder
  var body: some View {
    if let selection {
      scrollPositionedList(selection: selection)
    } else {
      scrollPositionedList(selection: nil)
    }
  }

  @ViewBuilder
  private func scrollPositionedList(selection: Binding<Selection?>?) -> some View {
    let list = List(selection: selection) {
      rows()
    }
    if let scrollPosition {
      list.scrollPosition(id: scrollPosition)
    } else {
      list
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
