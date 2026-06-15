//
//  SettingsSplitNavigation.swift
//  winston
//
//  Settings navigation environment seam. Sidebar selections replace the detail root,
//  while links opened from a detail panel push deeper in the detail stack. The state
//  itself lives in `SettingsNav` (see AppNav.swift); this file only carries the
//  environment plumbing so settings rows route through the same call sites unchanged.
//

import SwiftUI

enum SettingsNavigationOrigin: Equatable {
  case sidebar
  case detail
}

private struct SettingsNavigationModelKey: EnvironmentKey {
  static let defaultValue: SettingsNav? = nil
}

private struct SettingsNavigationOriginKey: EnvironmentKey {
  static let defaultValue: SettingsNavigationOrigin = .detail
}

extension EnvironmentValues {
  var settingsNavigationModel: SettingsNav? {
    get { self[SettingsNavigationModelKey.self] }
    set { self[SettingsNavigationModelKey.self] = newValue }
  }

  var settingsNavigationOrigin: SettingsNavigationOrigin {
    get { self[SettingsNavigationOriginKey.self] }
    set { self[SettingsNavigationOriginKey.self] = newValue }
  }
}

extension View {
  func settingsNavigation(_ model: SettingsNav, origin: SettingsNavigationOrigin) -> some View {
    self
      .environment(\.settingsNavigationModel, model)
      .environment(\.settingsNavigationOrigin, origin)
  }
}

@MainActor
func navigateSettingsDestination(
  _ destination: Router.NavDest,
  model: SettingsNav?,
  origin: SettingsNavigationOrigin
) -> Bool {
  guard let model, case .setting(let setting) = destination else { return false }
  switch origin {
  case .sidebar:
    model.select(setting)
  case .detail:
    model.pushDetail(destination)
  }
  return true
}

extension Router.NavDest.Setting {
  /// The sidebar root a (possibly nested) settings panel belongs to.
  var splitRoot: Router.NavDest.Setting {
    switch self {
    case .postSwipe, .commentSwipe, .filteredSubreddits:
      return .behavior
    case .appIcon, .accessibility:
      return .appearance
    case .general, .behavior, .appearance, .accounts, .diagnostics, .about, .faq, .designLab:
      return self
    }
  }
}
