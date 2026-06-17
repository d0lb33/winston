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
  static func back() { AppNav.shared.goBackOneStep() }
  static func to(_ dest: NavDest, _ reset: Bool = false) {
    AppDiagnostics.asyncBreadcrumb("Nav.to", metadata: ["destination": dest.diagnosticsName, "reset": "\(reset)"])
    AppNav.shared.navigate(dest, reset: reset)
  }
  static func fullTo(_ tab: TabIdentifier, _ dest: NavDest, _ reset: Bool = false) {
    AppDiagnostics.asyncBreadcrumb("Nav.fullTo", metadata: ["tab": tab.rawValue, "destination": dest.diagnosticsName, "reset": "\(reset)"])
    AppNav.shared.navigate(to: AppNav.Tab(tab), dest, reset: reset)
  }
  static func present(_ content: PresentingSheet?) {
    AppDiagnostics.asyncBreadcrumb("Nav.present", metadata: ["sheet": content?.diagnosticsName ?? "nil"])
    Nav.shared.presentingSheet = content
  }
  static func resetStack() {
    AppDiagnostics.asyncBreadcrumb("Nav.resetStack", metadata: ["tab": Nav.shared.activeTab.rawValue])
    AppNav.shared.resetSelectedSurface()
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
    didSet {
      let appTab = AppNav.Tab(activeTab)
      if AppNav.shared.selectedTab != appTab {
        AppNav.shared.selectedTab = appTab
      }
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
    AppNav.shared.navigate(to: AppNav.Tab(tab), dest, reset: reset)
  }
  
  func resetStack() {
    AppDiagnostics.asyncBreadcrumb("Nav.resetStack instance", metadata: ["tab": activeTab.rawValue])
    AppNav.shared.resetSelectedSurface()
  }

  @MainActor
  func resetAccountScopedStacks() {
    AppDiagnostics.asyncBreadcrumb("Nav.resetAccountScopedStacks")
    AppNav.shared.resetAccountScopedSurfaces()
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

extension Nav.PresentingSheet {
  var diagnosticsName: String {
    switch self {
    case .tipJar: return "sheet.tipJar"
    case .onboarding: return "sheet.onboarding"
    case .announcement(let announcement): return "sheet.announcement.\(announcement.id)"
    }
  }
}
