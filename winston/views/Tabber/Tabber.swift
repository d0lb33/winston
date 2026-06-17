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

  @State private var appNav = AppNav.shared
  @ObservedObject private var wire = RedditWire.shared

  @Environment(\.useTheme) private var currentTheme
  @Environment(TabBarMetrics.self) private var tabBarMetrics
  @Default(.AppearanceDefSettings) private var appearanceDefSettings
  @Default(.VideoDefSettings) private var videoDefSettings

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

  private var tabSelection: Binding<AppNav.Tab> {
    Binding(
      get: { appNav.selectedTab },
      set: { appNav.selectedTab = $0 }
    )
  }

  var body: some View {
    let accountScopeKey = wire.accountScopeID?.uuidString ?? "none"
    let meTabTitle = appearanceDefSettings.showUsernameInTabBar ? (wire.me?.data?.name ?? "Me") : "Me"

    TabView(selection: tabSelection) {
      Tab("Posts", systemImage: "doc.text.image", value: AppNav.Tab.posts) {
        WithAccountOnly { SubredditsStack(nav: appNav.posts) }
          .id("posts-\(accountScopeKey)")
          .measureTabBar(tabBarMetrics)
      }

      Tab("Inbox", systemImage: "bell.fill", value: AppNav.Tab.inbox) {
        WithAccountOnly { Inbox(nav: appNav.inbox) }
          .id("inbox-\(accountScopeKey)")
          .measureTabBar(tabBarMetrics)
      }

      Tab(meTabTitle, systemImage: "person.fill", value: AppNav.Tab.me) {
        WithAccountOnly { Me(nav: appNav.me) }
          .id("me-\(accountScopeKey)")
          .measureTabBar(tabBarMetrics)
      }

      Tab("Search", systemImage: "magnifyingglass", value: AppNav.Tab.search, role: .search) {
        WithAccountOnly { Search(nav: appNav.search) }
          .id("search-\(accountScopeKey)")
          .measureTabBar(tabBarMetrics)
      }

      Tab("Settings", systemImage: "gearshape.fill", value: AppNav.Tab.settings) {
        Settings(nav: appNav.settings)
          .measureTabBar(tabBarMetrics)
      }
    }
    .tabViewStyle(.sidebarAdaptable)
    .tabBarMinimizeBehavior(.onScrollDown)
    .environment(\.videoDefSettings, videoDefSettings)
    .openFromWebListener()
    .clipboardRedditLinkListener()
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
