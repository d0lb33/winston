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
  @ObservedObject private var wire = RedditWire.shared
  
  @Default(.ThemesDefSettings) private var themesDefSettings
  @Default(.GeneralDefSettings) private var generalDefSettings
  @Default(.auroraThemeID) private var auroraThemeID

  var selectedTheme: WinstonTheme { themesDefSettings.themesPresets.first { $0.id == themesDefSettings.selectedThemeID } ?? defaultTheme }
  
  let biometrics = Biometrics()
  @State private var isAuthenticating = false
  @State private var tabBarHeight: Double = 62
  @State private var lockBlur: Int = 50 // Set initial startup blur

  func setTabBarHeight(_ val: Double) {
    tabBarHeight = val
  }
  
  var body: some View {
    AccountSwitcherProvider {
      GlobalDestinationsProvider {
        AuroraAppShell(accountID: wire.accountScopeID)
      }
    }
    .openFromWebListener()
    .clipboardRedditLinkListener()
    .globalLoaderProvider()
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
    .task(priority: .background) {
      migrateOldDefaults()
      cleanCredentialOrphanEntities()
      removeDefaultThemeFromThemes()
      checkForOnboardingStatus()
      if !Defaults[.graphQLAccounts].isEmpty {
        Task(priority: .background) { await updatePostsInBox() }
      }
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

private struct AuroraAppShell: View {
  let accountID: UUID?

  @ObservedObject private var nav = Nav.shared
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    GeometryReader { proxy in
      AuroraRoot(router: nav[.posts], accountID: accountID)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          AuroraBottomNav()
        }
        .environment(\.contentWidth, max(Double(proxy.size.width), 1))
        .onAppear {
          ScreenMetrics.refresh(size: proxy.size, scale: displayScale)
        }
        .onGeometryChange(for: CGSize.self) { geometry in
          geometry.size
        } action: { newSize in
          ScreenMetrics.refresh(size: newSize, scale: displayScale)
        }
    }
  }
}

private struct AuroraBottomNav: View {
  @ObservedObject private var nav = Nav.shared
  @ObservedObject private var wire = RedditWire.shared
  @Default(.AppearanceDefSettings) private var appearanceDefSettings
  @Environment(\.auroraTheme) private var theme
  @Environment(\.setTabBarHeight) private var setTabBarHeight

  private let barHeight: CGFloat = 62

  var body: some View {
    HStack(spacing: 0) {
      navButton(.posts, title: "Posts", systemImage: "doc.text.image")
      navButton(.inbox, title: "Inbox", systemImage: "bell.fill")
      AccountSwitcherTrigger(onTap: { select(.me) }) {
        bottomNavLabel(
          title: appearanceDefSettings.showUsernameInTabBar ? wire.me?.data?.name ?? "Me" : "Me",
          systemImage: "person.fill",
          isSelected: nav.activeTab == .me
        )
      }
      navButton(.search, title: "Search", systemImage: "magnifyingglass")
      navButton(.settings, title: "Settings", systemImage: "gearshape.fill")
    }
    .frame(height: barHeight)
    .frame(maxWidth: .infinity)
    .background(.ultraThinMaterial)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(theme.hairline)
        .frame(height: 0.7)
    }
    .onAppear {
      setTabBarHeight(Double(barHeight))
    }
  }

  private func navButton(_ tab: Nav.TabIdentifier, title: String, systemImage: String) -> some View {
    Button {
      select(tab)
    } label: {
      bottomNavLabel(title: title, systemImage: systemImage, isSelected: nav.activeTab == tab)
    }
    .buttonStyle(.plain)
  }

  private func bottomNavLabel(title: String, systemImage: String, isSelected: Bool) -> some View {
    VStack(spacing: 4) {
      Image(systemName: systemImage)
        .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
      Text(title)
        .font(.caption2.weight(isSelected ? .semibold : .regular))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
    .foregroundStyle(isSelected ? theme.accent : Color.secondary)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
  }

  private func select(_ tab: Nav.TabIdentifier) {
    if nav.activeTab == tab {
      nav[tab].resetNavPath()
    } else {
      nav.activeTab = tab
    }
  }
}
