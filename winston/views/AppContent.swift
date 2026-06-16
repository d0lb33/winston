//
//  AppContent.swift
//  winston
//
//  Created by Igor Marcossi on 31/12/23.
//

import SwiftUI
import Defaults

struct AppContent: View {
  @Environment(\.scenePhase) var scenePhase
  @ObservedObject private var nav = Nav.shared
  
  @Default(.ThemesDefSettings) private var themesDefSettings
  @Default(.GeneralDefSettings) private var generalDefSettings
  @Default(.auroraThemeID) private var auroraThemeID

  var selectedTheme: WinstonTheme { themesDefSettings.themesPresets.first { $0.id == themesDefSettings.selectedThemeID } ?? defaultTheme }
  
  let biometrics = Biometrics()
  @State private var isAuthenticating = false
  @State private var hasUnlockedCurrentActiveSession = false
  @State private var tabBarHeight: Double = 0
  @State private var lockBlur: CGFloat = 0

  func setTabBarHeight(_ val: Double) {
    tabBarHeight = val
  }

  private var runningOnMac: Bool {
    #if os(macOS)
      true
    #else
      false
    #endif
  }

  private func updateLockState(for phase: ScenePhase) {
    let useAuth = generalDefSettings.useAuth

    guard useAuth && !runningOnMac else {
      lockBlur = 0
      isAuthenticating = false
      hasUnlockedCurrentActiveSession = true
      return
    }

    switch phase {
    case .active:
      if hasUnlockedCurrentActiveSession {
        lockBlur = 0
        return
      }

      guard !isAuthenticating else { return }

      lockBlur = 50
      isAuthenticating = true
      biometrics.authenticateUser { success in
        Task { @MainActor in
          if success {
            lockBlur = 0
            hasUnlockedCurrentActiveSession = true
          } else {
            lockBlur = 50
            hasUnlockedCurrentActiveSession = false
          }
          isAuthenticating = false
        }
      }

    case .inactive, .background:
      hasUnlockedCurrentActiveSession = false
      lockBlur = 50

    @unknown default:
      break
    }
  }
  
  var body: some View {
    AccountSwitcherProvider {
      GlobalDestinationsProvider {
        Tabber(theme: selectedTheme).equatable()
      }
    }
    .whatsNewSheet()
    .environment(\.tabBarHeight, tabBarHeight)
    .environment(\.setTabBarHeight, setTabBarHeight)
    .environment(\.useTheme, selectedTheme)
    .environment(\.auroraTheme, auroraThemeID.theme)
    .preferredColorScheme(auroraThemeID.theme.colorScheme)
    .onAppear {
      themesDefSettings.themesPresets = themesDefSettings.themesPresets.filter { $0.id != "default" }
      updateLockState(for: scenePhase)
    }
    .onChange(of: generalDefSettings.useAuth) {
      hasUnlockedCurrentActiveSession = false
      updateLockState(for: scenePhase)
    }
    .onChange(of: scenePhase) { _, newPhase in
      AppDiagnostics.shared.breadcrumb("Scene phase changed", metadata: ["phase": "\(newPhase)"])
      updateLockState(for: newPhase)
      
      switch newPhase {
      case .active :
        AppDiagnostics.shared.markSessionDirty("active")
        guard let name = shortcutItemToProcess?.userInfo?["name"] as? String else {
          return
        }
        switch name {
        case "saved":
          nav.activeTab = .posts
          nav[.posts].navigateContextually(to: .reddit(.subFeed(Subreddit(id: "saved"))))
        case "search":
          nav.activeTab = .search
        default:
          print("default " + name)
        }
        shortcutItemToProcess = nil
      case .inactive:
        // inactive
        AppDiagnostics.shared.markSessionClean("inactive")
        break
      case .background:
        AppDiagnostics.shared.markSessionClean("background")
        AppQuickActions.install()
      @unknown default:
        print("default")
      }
    }
    .blur(radius: lockBlur)
    .overlay {
      DiagnosticsHUD()
    }
  }
}
