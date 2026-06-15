//
//  Settings.swift
//  winston
//
//  Created by Igor Marcossi on 24/06/23.
//

import SwiftUI
import WhatsNewKit
//import SceneKit

struct Settings: View {
  @ObservedObject var router: Router
  @State private var navigation = SettingsSplitNavigationModel()
  @Environment(\.openURL) private var openURL
  @State private var presentingWhatsNew: Bool = false
  @State private var presentingAnnouncement: Bool = false
  @State private var presentingGQLDebug: Bool = false

  var body: some View {
    @Bindable var navigation = navigation

    NavigationSplitView(columnVisibility: $navigation.columnVisibility, preferredCompactColumn: $navigation.preferredColumn) {
      NavigationStack {
        SettingsSidebarList(
          selectedSetting: navigation.selectedSetting,
          showWhatsNew: { presentingWhatsNew.toggle() },
          showAnnouncements: { presentingAnnouncement.toggle() },
          showGraphQLDebug: { presentingGQLDebug.toggle() },
          donateMonthly: { openURL(URL(string: "https://patreon.com/user?u=93745105")!) },
          openTipJar: { openURL(URL(string: "https://ko-fi.com/locafe")!) }
        )
        .navigationTitle("Settings")
        .settingsNavigation(navigation, origin: .sidebar)
        .injectInTabDestinations(viewControllerHolder: router.navController)
      }
      .navigationSplitViewColumnWidth(min: 300, ideal: 360)
    } detail: {
      NavigationStack(path: $navigation.detailPath) {
        SettingsDetailColumnContent(setting: navigation.selectedSetting)
          .settingsNavigation(navigation, origin: .detail)
          .injectInTabDestinations(viewControllerHolder: router.navController)
      }
    }
    .navigationSplitViewStyle(.balanced)
    .sheet(isPresented: $presentingWhatsNew){
      if let isNew = getCurrentChangelog().first {
        WhatsNewView(whatsNew: isNew)
      }
    }
    .sheet(isPresented: $presentingGQLDebug) {
      RedditGQLDebugView()
    }
    .onAppear {
      navigation.attach(router: router)
      _ = navigation.absorbRootNavigationPathIfNeeded(router: router)
      AppDiagnostics.shared.breadcrumb("Opened Settings root")
    }
    .onChange(of: router.fullPath) { _, _ in
      _ = navigation.absorbRootNavigationPathIfNeeded(router: router)
    }
  }
}

private struct SettingsSidebarList: View {
  let selectedSetting: Router.NavDest.Setting?
  let showWhatsNew: () -> Void
  let showAnnouncements: () -> Void
  let showGraphQLDebug: () -> Void
  let donateMonthly: () -> Void
  let openTipJar: () -> Void

  var body: some View {
    List {
      SettingsMainSection(selectedSetting: selectedSetting)
      SettingsSupportSection(
        selectedSetting: selectedSetting,
        showWhatsNew: showWhatsNew,
        showAnnouncements: showAnnouncements,
        showGraphQLDebug: showGraphQLDebug,
        donateMonthly: donateMonthly,
        openTipJar: openTipJar
      )
    }
    .auroraSettingsSection()
    .auroraListChrome()
  }
}

private struct SettingsMainSection: View {
  let selectedSetting: Router.NavDest.Setting?

  var body: some View {
    Section {
      AuroraNavigationRow(.setting(.general), active: selectedSetting == .general, title: "General", systemImage: "gear")
      AuroraNavigationRow(.setting(.behavior), active: selectedSetting == .behavior, title: "Behavior", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
      AuroraNavigationRow(.setting(.appearance), active: selectedSetting == .appearance, title: "Appearance", systemImage: "theatermask.and.paintbrush.fill")
      AuroraNavigationRow(.setting(.accounts), active: selectedSetting == .accounts, title: "Accounts", systemImage: "person.crop.circle.fill")
      AuroraNavigationRow(.setting(.diagnostics), active: selectedSetting == .diagnostics, title: "Diagnostics", systemImage: "stethoscope")
    }
  }
}

private struct SettingsSupportSection: View {
  let selectedSetting: Router.NavDest.Setting?
  let showWhatsNew: () -> Void
  let showAnnouncements: () -> Void
  let showGraphQLDebug: () -> Void
  let donateMonthly: () -> Void
  let openTipJar: () -> Void

  var body: some View {
    Section {
      AuroraNavigationRow(.setting(.faq), active: selectedSetting == .faq, title: "FAQ", systemImage: "exclamationmark.questionmark")
      AuroraNavigationRow(.setting(.about), active: selectedSetting == .about, title: "About", systemImage: "cup.and.saucer.fill")
      AuroraActionRow(title: "Whats New", systemImage: "star") {
        showWhatsNew()
      }
      .disabled(getCurrentChangelog().isEmpty)

      AuroraActionRow(title: "Announcements", systemImage: "newspaper") {
        showAnnouncements()
      }

      AuroraActionRow(title: "GraphQL (experimental)", systemImage: "flask") {
        showGraphQLDebug()
      }

      AuroraNavigationRow(.setting(.designLab), active: selectedSetting == .designLab, title: "Design Lab", systemImage: "paintpalette.fill")

      AuroraActionRow(title: "Donate monthly", systemImage: "heart.fill") {
        donateMonthly()
      }

      AuroraRowButton {
        openTipJar()
      } label: {
        Label {
          Text("Tip jar")
        } icon: {
          Image(.jar)
            .resizable()
            .scaledToFit()
        }
      }
    }
  }
}

private struct SettingsDetailColumnContent: View {
  let setting: Router.NavDest.Setting?

  var body: some View {
    switch setting {
    case .some(.general):
      GeneralPanel()
        .diagnosticScreen("setting.general")
    case .some(.behavior):
      BehaviorPanel()
        .diagnosticScreen("setting.behavior")
    case .some(.appearance):
      AppearancePanel()
        .diagnosticScreen("setting.appearance")
    case .some(.accounts):
      AccountsPanel()
        .diagnosticScreen("setting.accounts")
    case .some(.diagnostics):
      DiagnosticsPanel()
        .diagnosticScreen("setting.diagnostics")
    case .some(.about):
      AboutPanel()
        .diagnosticScreen("setting.about")
    case .some(.commentSwipe):
      CommentSwipePanel()
        .diagnosticScreen("setting.commentSwipe")
    case .some(.postSwipe):
      PostSwipePanel()
        .diagnosticScreen("setting.postSwipe")
    case .some(.accessibility):
      AccessibilityPanel()
        .diagnosticScreen("setting.accessibility")
    case .some(.filteredSubreddits):
      FilteredSubredditsSettings()
        .diagnosticScreen("setting.filteredSubreddits")
    case .some(.faq):
      FAQPanel()
        .diagnosticScreen("setting.faq")
    case .some(.appIcon):
      AppIconSetting()
        .diagnosticScreen("setting.appIcon")
    case .some(.designLab):
      DesignLabGallery()
        .diagnosticScreen("setting.designLab")
    case .none:
      GeneralPanel()
        .diagnosticScreen("setting.general")
    }
  }
}

//struct Settings_Previews: PreviewProvider {
//  static var previews: some View {
//    Settings()
//  }
//}
