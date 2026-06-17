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
  let issuedAt = Date()
  let kind: TabInteractionRequestKind
}

struct TabBarRevealRequest: Equatable {
  let id = UUID()
  let tab: Nav.TabIdentifier
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

extension TabInteractionOwnerID {
  static let postsFeed = TabInteractionOwnerID("aurora-feed-top")
  static let searchRoot = TabInteractionOwnerID("search-top")
  static let meRoot = TabInteractionOwnerID("user-view-top")
  static let inboxRoot = TabInteractionOwnerID("inbox-top")
  static let settingsRoot = TabInteractionOwnerID("settings.settings-top")

  static func sourceRoot(for tab: Nav.TabIdentifier) -> TabInteractionOwnerID? {
    switch tab {
    case .search: return .searchRoot
    case .me: return .meRoot
    case .inbox: return .inboxRoot
    case .posts: return .postsFeed
    case .settings: return .settingsRoot
    }
  }
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
  @Published private(set) var tabBarRevealRequest: TabBarRevealRequest?

  private struct ScrollOwnerState {
    var ownerID: TabInteractionOwnerID
    var isAtTop: Bool
  }

  private var scrollOwnerStateByTab: [Nav.TabIdentifier: ScrollOwnerState] = [:]
  private var lastScrollOffsetByOwner: [TabInteractionOwnerID: CGFloat] = [:]
  private var lastTopStateByOwner: [TabInteractionOwnerID: Bool] = [:]
  private var ownerActivationDateByOwner: [TabInteractionOwnerID: Date] = [:]
  private var lastIgnoredScrollLogDateByOwner: [TabInteractionOwnerID: Date] = [:]
  private var lastTabBarRevealDateByTab: [Nav.TabIdentifier: Date] = [:]
  private var lastTap: (tab: Nav.TabIdentifier, date: Date)?
  private var lastReselectEvent: (tab: Nav.TabIdentifier, date: Date)?
  private let doubleTapInterval: TimeInterval = 0.3
  private let duplicateEventInterval: TimeInterval = 0.05
  private let scrollUpRevealThreshold: CGFloat = 1.5
  private let tabBarRevealThrottleInterval: TimeInterval = 0.18
  private let ignoredScrollLogThrottleInterval: TimeInterval = 1.0

  func selectedTabChanged(to tab: Nav.TabIdentifier) {
    let previousOwner = scrollOwnerStateByTab[tab]?.ownerID.rawValue ?? "none"
    let previousIsAtTop = scrollOwnerStateByTab[tab].map { "\($0.isAtTop)" } ?? "nil"
    lastTap = nil
    if scrollOwnerStateByTab[tab] == nil {
      scrollOwnerStateByTab[tab] = ScrollOwnerState(ownerID: legacyOwnerID(for: tab), isAtTop: false)
    }
    AppDiagnostics.asyncBreadcrumb(
      "tabInteraction.selectedTabChanged",
      metadata: [
        "tab": tab.rawValue,
        "previousOwner": previousOwner,
        "previousIsAtTop": previousIsAtTop,
        "currentOwner": scrollOwnerStateByTab[tab]?.ownerID.rawValue ?? "none",
        "currentIsAtTop": scrollOwnerStateByTab[tab].map { "\($0.isAtTop)" } ?? "nil"
      ]
    )
  }

  func activateScrollOwner(_ ownerID: TabInteractionOwnerID, for tab: Nav.TabIdentifier, initialIsAtTop: Bool = false) {
    let previousOwner = scrollOwnerStateByTab[tab]?.ownerID.rawValue ?? "none"
    let previousIsAtTop = scrollOwnerStateByTab[tab].map { "\($0.isAtTop)" } ?? "nil"
    guard scrollOwnerStateByTab[tab]?.ownerID != ownerID else {
      AppDiagnostics.asyncBreadcrumb(
        "tabInteraction.ownerActivateSkipped",
        metadata: [
          "tab": tab.rawValue,
          "owner": ownerID.rawValue,
          "reason": "alreadyActive",
          "isAtTop": scrollOwnerStateByTab[tab].map { "\($0.isAtTop)" } ?? "nil"
        ]
      )
      return
    }
    scrollOwnerStateByTab[tab] = ScrollOwnerState(ownerID: ownerID, isAtTop: initialIsAtTop)
    ownerActivationDateByOwner[ownerID] = Date()
    lastScrollOffsetByOwner.removeValue(forKey: ownerID)
    lastTopStateByOwner[ownerID] = initialIsAtTop
    AppDiagnostics.asyncBreadcrumb(
      "tabInteraction.ownerActivated",
      metadata: [
        "tab": tab.rawValue,
        "owner": ownerID.rawValue,
        "isAtTop": "\(initialIsAtTop)",
        "previousOwner": previousOwner,
        "previousIsAtTop": previousIsAtTop
      ]
    )
  }

  func deactivateScrollOwner(_ ownerID: TabInteractionOwnerID, for tab: Nav.TabIdentifier) {
    guard scrollOwnerStateByTab[tab]?.ownerID == ownerID else {
      AppDiagnostics.asyncBreadcrumb(
        "tabInteraction.ownerDeactivateSkipped",
        metadata: [
          "tab": tab.rawValue,
          "owner": ownerID.rawValue,
          "activeOwner": scrollOwnerStateByTab[tab]?.ownerID.rawValue ?? "none",
          "reason": "notActive"
        ]
      )
      return
    }
    let previousIsAtTop = scrollOwnerStateByTab[tab].map { "\($0.isAtTop)" } ?? "nil"
    scrollOwnerStateByTab.removeValue(forKey: tab)
    lastScrollOffsetByOwner.removeValue(forKey: ownerID)
    lastTopStateByOwner.removeValue(forKey: ownerID)
    ownerActivationDateByOwner.removeValue(forKey: ownerID)
    AppDiagnostics.asyncBreadcrumb(
      "tabInteraction.ownerDeactivated",
      metadata: ["tab": tab.rawValue, "owner": ownerID.rawValue, "previousIsAtTop": previousIsAtTop]
    )
  }

  func setIsAtTop(_ tab: Nav.TabIdentifier, _ isAtTop: Bool) {
    let ownerID = scrollOwnerStateByTab[tab]?.ownerID ?? legacyOwnerID(for: tab)
    scrollOwnerStateByTab[tab] = ScrollOwnerState(ownerID: ownerID, isAtTop: isAtTop)
    lastTopStateByOwner[ownerID] = isAtTop
    AppDiagnostics.asyncBreadcrumb(
      "tabInteraction.topStateSetLegacy",
      metadata: ["tab": tab.rawValue, "owner": ownerID.rawValue, "isAtTop": "\(isAtTop)"]
    )
  }

  func setIsAtTop(_ tab: Nav.TabIdentifier, _ isAtTop: Bool, ownerID: TabInteractionOwnerID) {
    guard scrollOwnerStateByTab[tab]?.ownerID == ownerID else {
      AppDiagnostics.asyncBreadcrumb(
        "tabInteraction.topStateIgnored",
        metadata: [
          "tab": tab.rawValue,
          "owner": ownerID.rawValue,
          "isAtTop": "\(isAtTop)",
          "activeOwner": scrollOwnerStateByTab[tab]?.ownerID.rawValue ?? "none"
        ]
      )
      return
    }
    scrollOwnerStateByTab[tab]?.isAtTop = isAtTop
    if lastTopStateByOwner[ownerID] != isAtTop {
      lastTopStateByOwner[ownerID] = isAtTop
      AppDiagnostics.asyncBreadcrumb(
        "tabInteraction.topStateChanged",
        metadata: ["tab": tab.rawValue, "owner": ownerID.rawValue, "isAtTop": "\(isAtTop)", "source": "explicit"]
      )
    }
  }

  func recordScrollOffset(_ offsetY: CGFloat, for tab: Nav.TabIdentifier, ownerID: TabInteractionOwnerID) {
    guard scrollOwnerStateByTab[tab]?.ownerID == ownerID else {
      logIgnoredScrollOffsetIfNeeded(offsetY, for: tab, ownerID: ownerID)
      return
    }
    let previousOffset = lastScrollOffsetByOwner[ownerID]
    if let previousOffset,
       offsetY < previousOffset - scrollUpRevealThreshold {
      revealTabBar(for: tab)
    }
    lastScrollOffsetByOwner[ownerID] = offsetY
    let isAtTop = offsetY <= 4
    scrollOwnerStateByTab[tab]?.isAtTop = isAtTop
    if lastTopStateByOwner[ownerID] != isAtTop {
      lastTopStateByOwner[ownerID] = isAtTop
      AppDiagnostics.asyncBreadcrumb(
        "tabInteraction.scrollTopStateChanged",
        metadata: [
          "tab": tab.rawValue,
          "owner": ownerID.rawValue,
          "isAtTop": "\(isAtTop)",
          "offsetY": formatOffset(offsetY),
          "previousOffsetY": previousOffset.map(formatOffset) ?? "nil"
        ]
      )
    }
  }

  func isActiveOwner(_ ownerID: TabInteractionOwnerID, for tab: Nav.TabIdentifier) -> Bool {
    scrollOwnerStateByTab[tab]?.ownerID == ownerID
  }

  func canOwnerHandleRequest(_ request: TabInteractionRequest, ownerID: TabInteractionOwnerID, for tab: Nav.TabIdentifier) -> Bool {
    guard isActiveOwner(ownerID, for: tab) else { return false }
    guard let activationDate = ownerActivationDateByOwner[ownerID] else { return true }
    return request.issuedAt >= activationDate
  }

  func diagnosticsMetadata(for tab: Nav.TabIdentifier, prefix: String = "") -> [String: String] {
    let state = scrollOwnerStateByTab[tab]
    let lastOffset = state.flatMap { lastScrollOffsetByOwner[$0.ownerID] }
    let ownerActivationAge = state.flatMap { ownerActivationDateByOwner[$0.ownerID] }.map { Date().timeIntervalSince($0) }
    return [
      "\(prefix)tab": tab.rawValue,
      "\(prefix)activeOwner": state?.ownerID.rawValue ?? "none",
      "\(prefix)activeIsAtTop": state.map { "\($0.isAtTop)" } ?? "nil",
      "\(prefix)lastOffsetY": lastOffset.map(formatOffset) ?? "nil",
      "\(prefix)activeOwnerAge": ownerActivationAge.map(formatInterval) ?? "nil",
      "\(prefix)lastTapTab": lastTap?.tab.rawValue ?? "none",
      "\(prefix)lastReselectTab": lastReselectEvent?.tab.rawValue ?? "none"
    ]
  }

  func selectedTabTappedAgain(_ tab: Nav.TabIdentifier) {
    let now = Date()
    if let lastReselectEvent,
       lastReselectEvent.tab == tab,
       now.timeIntervalSince(lastReselectEvent.date) <= duplicateEventInterval {
      AppDiagnostics.asyncBreadcrumb(
        "tabInteraction.reselectSuppressed",
        metadata: [
          "tab": tab.rawValue,
          "reason": "duplicateEvent",
          "interval": formatInterval(now.timeIntervalSince(lastReselectEvent.date)),
          "activeOwner": scrollOwnerStateByTab[tab]?.ownerID.rawValue ?? "none",
          "activeIsAtTop": scrollOwnerStateByTab[tab].map { "\($0.isAtTop)" } ?? "nil"
        ]
      )
      return
    }

    lastReselectEvent = (tab, now)

    if let lastTap,
       lastTap.tab == tab,
       now.timeIntervalSince(lastTap.date) <= doubleTapInterval {
      self.lastTap = nil
      AppDiagnostics.asyncBreadcrumb(
        "tabInteraction.reselectDecision",
        metadata: [
          "tab": tab.rawValue,
          "decision": "resetToRoot",
          "tapInterval": formatInterval(now.timeIntervalSince(lastTap.date)),
          "activeOwner": scrollOwnerStateByTab[tab]?.ownerID.rawValue ?? "none",
          "activeIsAtTop": scrollOwnerStateByTab[tab].map { "\($0.isAtTop)" } ?? "nil"
        ]
      )
      publish(.resetToRoot, for: tab)
      return
    }

    lastTap = (tab, now)
    // During split-view transitions SwiftUI can briefly unmount the current scroll
    // owner before the returning owner appears. Treat that gap as scrollable so a
    // tab reselect never accidentally navigates back.
    let activeState = scrollOwnerStateByTab[tab]
    let decision: TabInteractionRequestKind = (activeState?.isAtTop ?? false) ? .goBack : .scrollToTop
    AppDiagnostics.asyncBreadcrumb(
      "tabInteraction.reselectDecision",
      metadata: [
        "tab": tab.rawValue,
        "decision": "\(decision)",
        "activeOwner": activeState?.ownerID.rawValue ?? "none",
        "activeIsAtTop": activeState.map { "\($0.isAtTop)" } ?? "nil",
        "hasLastOffset": activeState.flatMap { lastScrollOffsetByOwner[$0.ownerID] }.map { "true:\(formatOffset($0))" } ?? "false"
      ]
    )
    publish(decision, for: tab)
  }

  private func legacyOwnerID(for tab: Nav.TabIdentifier) -> TabInteractionOwnerID {
    TabInteractionOwnerID("legacy.\(tab.rawValue)")
  }

  private func publish(_ kind: TabInteractionRequestKind, for tab: Nav.TabIdentifier) {
    requests[tab] = TabInteractionRequest(kind: kind)
    AppDiagnostics.asyncBreadcrumb(
      "Tab interaction request",
        metadata: [
          "tab": tab.rawValue,
          "kind": "\(kind)",
          "requestID": requests[tab]?.id.uuidString ?? "none",
          "activeOwner": scrollOwnerStateByTab[tab]?.ownerID.rawValue ?? "none",
          "activeIsAtTop": scrollOwnerStateByTab[tab].map { "\($0.isAtTop)" } ?? "nil"
        ]
    )
  }

  private func revealTabBar(for tab: Nav.TabIdentifier) {
    let now = Date()
    if let lastDate = lastTabBarRevealDateByTab[tab],
       now.timeIntervalSince(lastDate) < tabBarRevealThrottleInterval {
      return
    }
    lastTabBarRevealDateByTab[tab] = now
    tabBarRevealRequest = TabBarRevealRequest(tab: tab)
    AppDiagnostics.asyncBreadcrumb(
      "Tab bar reveal requested",
      metadata: [
        "tab": tab.rawValue,
        "activeOwner": scrollOwnerStateByTab[tab]?.ownerID.rawValue ?? "none"
      ]
    )
  }

  private func logIgnoredScrollOffsetIfNeeded(_ offsetY: CGFloat, for tab: Nav.TabIdentifier, ownerID: TabInteractionOwnerID) {
    let now = Date()
    if let lastDate = lastIgnoredScrollLogDateByOwner[ownerID],
       now.timeIntervalSince(lastDate) < ignoredScrollLogThrottleInterval {
      return
    }
    lastIgnoredScrollLogDateByOwner[ownerID] = now
    AppDiagnostics.asyncBreadcrumb(
      "tabInteraction.scrollOffsetIgnored",
      metadata: [
        "tab": tab.rawValue,
        "owner": ownerID.rawValue,
        "activeOwner": scrollOwnerStateByTab[tab]?.ownerID.rawValue ?? "none",
        "offsetY": formatOffset(offsetY)
      ]
    )
  }

  private func formatOffset(_ value: CGFloat) -> String {
    String(format: "%.1f", Double(value))
  }

  private func formatInterval(_ value: TimeInterval) -> String {
    String(format: "%.3f", value)
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
          tabInteractions.recordScrollOffset(newOffsetY, for: tab, ownerID: ownerID)
        }
        onOffsetChange(newOffsetY)
      }
      .onAppear {
        AppDiagnostics.asyncBreadcrumb(
          "tabInteraction.scrollRootAppear",
          metadata: ["tab": tab?.rawValue ?? "none", "owner": ownerID.rawValue, "topID": topID]
        )
        activateOwner()
      }
      .onDisappear {
        AppDiagnostics.asyncBreadcrumb(
          "tabInteraction.scrollRootDisappear",
          metadata: ["tab": tab?.rawValue ?? "none", "owner": ownerID.rawValue, "topID": topID]
        )
        deactivateOwner()
      }
      .onChange(of: tab) { oldTab, newTab in
        AppDiagnostics.asyncBreadcrumb(
          "tabInteraction.scrollRootTabChanged",
          metadata: [
            "owner": ownerID.rawValue,
            "oldTab": oldTab?.rawValue ?? "none",
            "newTab": newTab?.rawValue ?? "none"
          ]
        )
        if let oldTab, let tabInteractions {
          tabInteractions.deactivateScrollOwner(ownerID, for: oldTab)
        }
        if newTab != nil {
          activateOwner()
        }
      }
      .onChange(of: ownerID) { oldOwnerID, _ in
        AppDiagnostics.asyncBreadcrumb(
          "tabInteraction.scrollRootOwnerChanged",
          metadata: ["tab": tab?.rawValue ?? "none", "oldOwner": oldOwnerID.rawValue, "newOwner": ownerID.rawValue]
        )
        if let tab, let tabInteractions {
          tabInteractions.deactivateScrollOwner(oldOwnerID, for: tab)
        }
        activateOwner()
      }
      .onChange(of: request) { _, request in
        guard let request else { return }
        let active = tab.map { tabInteractions?.isActiveOwner(ownerID, for: $0) == true } ?? false
        let canHandle = tab.map { tabInteractions?.canOwnerHandleRequest(request, ownerID: ownerID, for: $0) == true } ?? false
        AppDiagnostics.asyncBreadcrumb(
          "tabInteraction.scrollRootRequest",
          metadata: [
            "tab": tab?.rawValue ?? "none",
            "owner": ownerID.rawValue,
            "kind": "\(request.kind)",
            "requestID": request.id.uuidString,
            "isActiveOwner": "\(active)",
            "canHandle": "\(canHandle)",
            "topID": topID
          ]
        )
        guard request.kind == .scrollToTop || request.kind == .resetToRoot else { return }
        guard canHandle else {
          AppDiagnostics.asyncBreadcrumb(
            "tabInteraction.scrollRootRequestIgnored",
            metadata: [
              "tab": tab?.rawValue ?? "none",
              "owner": ownerID.rawValue,
              "kind": "\(request.kind)",
              "requestID": request.id.uuidString,
              "reason": active ? "staleBeforeOwnerActivation" : "inactiveOwner",
              "topID": topID
            ]
          )
          return
        }
        if request.kind == .resetToRoot {
          onResetToRoot?()
        }
        withAnimation(.snappy) {
          proxy.scrollTo(topID, anchor: .top)
        }
        AppDiagnostics.asyncBreadcrumb(
          "tabInteraction.scrollRootScrollToTop",
          metadata: ["tab": tab?.rawValue ?? "none", "owner": ownerID.rawValue, "kind": "\(request.kind)", "requestID": request.id.uuidString, "topID": topID]
        )
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
