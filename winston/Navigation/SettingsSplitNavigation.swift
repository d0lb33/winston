//
//  SettingsSplitNavigation.swift
//  winston
//
//  Shared routing state for the settings split view. Sidebar selections replace
//  the detail root, while links opened from a detail panel push deeper in the
//  detail stack.
//

import SwiftUI

enum SettingsNavigationOrigin: Equatable {
  case sidebar
  case detail
}

@Observable
@MainActor
final class SettingsSplitNavigationModel {
  var columnVisibility: NavigationSplitViewVisibility = .all
  var preferredColumn: NavigationSplitViewColumn = .sidebar
  var selectedSetting: Router.NavDest.Setting? = .general
  var detailPath: [Router.NavDest] = []

  @ObservationIgnored private weak var router: Router?

  func attach(router: Router) {
    self.router = router
  }

  func navigate(_ destination: Router.NavDest, from origin: SettingsNavigationOrigin) {
    guard case .setting(let setting) = destination else {
      router?.navigateTo(destination)
      return
    }

    switch origin {
    case .sidebar:
      select(setting)
    case .detail:
      detailPath.append(destination)
      focusDetail()
    }
  }

  @discardableResult
  func absorbRootNavigationPathIfNeeded(router: Router) -> Bool {
    guard let destination = router.fullPath.first,
          case .setting(let setting) = destination
    else { return false }

    selectedSetting = setting.splitRoot
    if setting == setting.splitRoot {
      detailPath = Array(router.fullPath.dropFirst())
    } else {
      detailPath = [destination] + Array(router.fullPath.dropFirst())
    }
    router.resetNavPath()
    focusDetail()
    return true
  }

  private func select(_ setting: Router.NavDest.Setting) {
    selectedSetting = setting.splitRoot
    detailPath = setting == setting.splitRoot ? [] : [.setting(setting)]
    if router?.fullPath.isEmpty == false {
      router?.resetNavPath()
    }
    focusDetail()
  }

  private func focusDetail() {
    preferredColumn = .detail
  }
}

private struct SettingsNavigationModelKey: EnvironmentKey {
  static let defaultValue: SettingsSplitNavigationModel? = nil
}

private struct SettingsNavigationOriginKey: EnvironmentKey {
  static let defaultValue: SettingsNavigationOrigin = .detail
}

extension EnvironmentValues {
  var settingsNavigationModel: SettingsSplitNavigationModel? {
    get { self[SettingsNavigationModelKey.self] }
    set { self[SettingsNavigationModelKey.self] = newValue }
  }

  var settingsNavigationOrigin: SettingsNavigationOrigin {
    get { self[SettingsNavigationOriginKey.self] }
    set { self[SettingsNavigationOriginKey.self] = newValue }
  }
}

extension View {
  func settingsNavigation(_ model: SettingsSplitNavigationModel, origin: SettingsNavigationOrigin) -> some View {
    self
      .environment(\.settingsNavigationModel, model)
      .environment(\.settingsNavigationOrigin, origin)
  }
}

@MainActor
func navigateSettingsDestination(
  _ destination: Router.NavDest,
  model: SettingsSplitNavigationModel?,
  origin: SettingsNavigationOrigin
) -> Bool {
  guard let model, case .setting = destination else { return false }
  model.navigate(destination, from: origin)
  return true
}

private extension Router.NavDest.Setting {
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
