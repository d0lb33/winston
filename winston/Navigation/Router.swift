//
//  Router.swift
//  winston
//
//  Created by Igor Marcossi on 05/08/23.
//

import Foundation
import SwiftUI
import Combine

/// Transitional per-tab deep-link inbox. No longer drives any rendering — the migrated
/// surfaces render from their own `PostsNav`/`ColumnNav`/`StackNav`/`SettingsNav` and only
/// consume this as a write-only inbox via `.routerDeepLinkInbox` (`Nav.to` / contextual /
/// shortcuts land here, get translated into the surface model, then cleared). Backs the
/// `Nav` static facade during the migration.
@MainActor
class Router: ObservableObject, Hashable, Equatable, Identifiable {
  let id: String
  
  var firstSelected: NavDest? {
    get { fullPath.isEmpty ? nil : fullPath[0] }
    set {
      replacePath(newValue.map { fullPath.isEmpty ? [$0] : [$0] + path } ?? [])
    }
  }
  @Published var fullPath: [NavDest] = []
  @Published var contextualDestination: NavDest? = nil
  @Published private(set) var rootResetToken = UUID()
  var path: [NavDest] {
    get { Array(self.fullPath.dropFirst()) }
    set {
      if fullPath.isEmpty { self.fullPath = newValue } else { self.fullPath = [fullPath[0]] + newValue }
    }
  }
  @Published private(set) var isAtRoot = false

  private var cancellables = Set<AnyCancellable>()

  init(id: String) {
    self.id = id
    $fullPath.map { $0.isEmpty }.assign(to: \.isAtRoot, on: self).store(in: &cancellables)
  }
  
  func goBack() {
    guard !fullPath.isEmpty else { return }
    AppDiagnostics.asyncBreadcrumb("Router.goBack", metadata: ["router": id])
    _ = withAnimation { self.fullPath.removeLast() }
  }
  func resetNavPath() {
    AppDiagnostics.asyncBreadcrumb("Router.resetNavPath", metadata: ["router": id])
    replacePath([])
  }
  func requestRootReset() {
    AppDiagnostics.asyncBreadcrumb("Router.requestRootReset", metadata: ["router": id])
    replacePath([])
    contextualDestination = nil
    rootResetToken = UUID()
  }
  func navigateTo(_ dest: NavDest, _ reset: Bool = false, animated: Bool = true) {
    AppDiagnostics.asyncBreadcrumb("Router.navigateTo", metadata: ["router": id, "destination": dest.diagnosticsName, "reset": "\(reset)"])
    if animated {
      withAnimation {
        self.path = reset ? [dest] : self.path + [dest]
      }
    } else {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        self.path = reset ? [dest] : self.path + [dest]
      }
    }
  }
  func navigateContextually(to dest: NavDest) {
    AppDiagnostics.asyncBreadcrumb("Router.navigateContextually", metadata: ["router": id, "destination": dest.diagnosticsName])
    contextualDestination = dest
  }

  func replacePath(_ newPath: [NavDest], animated: Bool = true) {
    if animated {
      withAnimation {
        fullPath = newPath
      }
    } else {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        fullPath = newPath
      }
    }
  }
  
  enum CodingKeys: String, CodingKey {
    case id, firstSelected, path
  }
  
  static func == (lhs: Router, rhs: Router) -> Bool {
    lhs.id == rhs.id
  }
  
  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(firstSelected)
    hasher.combine(path)
  }
}
