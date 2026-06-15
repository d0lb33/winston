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
  @State private var tabBarHeight: Double = 0
  @State private var lockBlur: Int = 50 // Set initial startup blur

  func setTabBarHeight(_ val: Double) {
    tabBarHeight = val
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
    .onAppear { themesDefSettings.themesPresets = themesDefSettings.themesPresets.filter { $0.id != "default" } }
    .onChange(of: scenePhase) { _, newPhase in
      AppDiagnostics.shared.breadcrumb("Scene phase changed", metadata: ["phase": "\(newPhase)"])
      // No auth on MacOS
      var runningOnMac = false
      #if os(macOS)
        runningOnMac = true
      #endif

      let useAuth = generalDefSettings.useAuth // Get fresh value
      
      if (useAuth && !runningOnMac) {
        if (!isAuthenticating && newPhase == .active && lockBlur != 0){
          // Not authing, active and blur visible = Need to auth
          isAuthenticating = true
          biometrics.authenticateUser { success in
            if success {
              lockBlur = 0
            }
          }
        }
        else if (newPhase != .active) {
          // Auth enabled but not active = blur
          lockBlur = 50
        }
        isAuthenticating = false
      } else {
          // Auth not enabled = No blur
          lockBlur = 0
      }
      
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
        addQuickActions()
      @unknown default:
        print("default")
      }
    }
    .blur(radius: CGFloat(lockBlur)) // Set lockscreen blur
    .overlay {
      DiagnosticsHUD()
    }
  }
  
  func addQuickActions() {
    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "name", ascending: true)], animation: .default) var subreddits: FetchedResults<CachedSub>
    
    var searchUserInfo: [String: NSSecureCoding] {
      return ["name" : "search" as NSSecureCoding]
    }
    var savedInfo: [String: NSSecureCoding] {
      return ["name" : "saved" as NSSecureCoding]
    }
    var statususerInfo: [String: NSSecureCoding] {
      return ["name" : "status" as NSSecureCoding]
    }
    var contactuserInfo: [String: NSSecureCoding] {
      return ["name" : "contact" as NSSecureCoding]
    }
    
    UIApplication.shared.shortcutItems = [
      UIApplicationShortcutItem(type: "Search", localizedTitle: "Search", localizedSubtitle: "Search a Subreddit", icon: UIApplicationShortcutIcon(type: .search), userInfo: searchUserInfo),
      UIApplicationShortcutItem(type: "Saved", localizedTitle: "Saved", localizedSubtitle: "", icon: UIApplicationShortcutIcon(type: .bookmark), userInfo: savedInfo),
    ]
    
  }
}
