//
//  Tabber.swift
//  winston
//
//  Created by Igor Marcossi on 24/06/23.
//

import SwiftUI
import Defaults
import SpriteKit

struct Tabber: View, Equatable {
  static func == (lhs: Tabber, rhs: Tabber) -> Bool { true }
  
  @ObservedObject private var nav = Nav.shared
  
  @State var tabBarHeight: Double? = nil
  
  @Environment(\.useTheme) private var currentTheme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.setTabBarHeight) private var setTabBarHeight
  @Default(.AppearanceDefSettings) private var appearanceDefSettings
  
  @State var sharedTheme: ThemeData? = nil
  
  func meTabTap() {
    if nav.activeTab == .me {
      nav[.me].resetNavPath()
    } else {
      nav.activeTab = .me
    }
  }
  
  init(theme: WinstonTheme) {
    Tabber.updateTabAndNavBar(tabTheme: theme.general.tabBarBG, navTheme: theme.general.navPanelBG)
  }
  
  static func updateTabAndNavBar(tabTheme: ThemeForegroundBG, navTheme: ThemeForegroundBG) {
    let toolbarAppearence = UINavigationBarAppearance()
    if !navTheme.blurry {
      toolbarAppearence.configureWithOpaqueBackground()
    }
    toolbarAppearence.backgroundColor = UIColor(navTheme.color())
    UINavigationBar.appearance().standardAppearance = toolbarAppearence
    let transparentAppearence = UITabBarAppearance()
    if !tabTheme.blurry {
      transparentAppearence.configureWithOpaqueBackground()
    }
    transparentAppearence.backgroundColor = UIColor(tabTheme.color())
    UITabBar.appearance().standardAppearance = transparentAppearence
  }
  
  var body: some View {
    TabView(selection: $nav.activeTab.onUpdate { newTab in if nav.activeTab == newTab { nav.resetStack() } }) {
      
      WithAccountOnly {
        SubredditsStack(router: nav[.posts])
      }
      .measureTabBar(setTabBarHeight)
      .tag(Nav.TabIdentifier.posts)
      .tabItem { Label("Posts", systemImage: "doc.text.image") }
      
      WithAccountOnly {
        Inbox(router: nav[.inbox])
      }
      .measureTabBar(setTabBarHeight)
      .tag(Nav.TabIdentifier.inbox)
      .tabItem { Label("Inbox", systemImage: "bell.fill") }
      
      WithAccountOnly {
        Me(router: nav[.me])
      }
      .measureTabBar(setTabBarHeight)
      .tag(Nav.TabIdentifier.me)
      .tabItem { Label(appearanceDefSettings.showUsernameInTabBar ? RedditWire.shared.me?.data?.name ?? "Me" : "Me", systemImage: "person.fill") }
//      
      WithAccountOnly {
        Search(router: nav[.search])
      }
      .measureTabBar(setTabBarHeight)
      .tag(Nav.TabIdentifier.search)
      .tabItem { Label("Search", systemImage: "magnifyingglass") }
      
      Settings(router: nav[.settings])
        .measureTabBar(setTabBarHeight)
        .tag(Nav.TabIdentifier.settings)
        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
      
    }
    .overlay(TabBarOverlay(meTabTap: meTabTap), alignment: .bottom)
    .openFromWebListener()
    .themeFetchingListener() // From WinstonAPI
    .themeImportingListener() // From local file
    .globalLoaderProvider()
    .task(priority: .background) {
      migrateOldDefaults()
      cleanCredentialOrphanEntities()
      removeDefaultThemeFromThemes()
      checkForOnboardingStatus()
      if !Defaults[.graphQLAccounts].isEmpty {
        Task(priority: .background) { await updatePostsInBox() }
      }
    }
    .accentColor(currentTheme.general.accentColor())
  }
}

