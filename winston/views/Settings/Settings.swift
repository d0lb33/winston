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
  @State private var nav = SettingsNav()
  @Environment(\.openURL) private var openURL
  @Environment(\.horizontalSizeClass) private var hSize
  @State private var presentingWhatsNew: Bool = false
  @State private var presentingAnnouncement: Bool = false
  @State private var presentingGQLDebug: Bool = false
  @EnvironmentObject private var tabInteractions: TabInteractionCenter

  private var isSidebarVisibleForTabInteraction: Bool {
    hSize == .regular || nav.preferredColumn == .sidebar
  }

  private var isDetailVisibleForTabInteraction: Bool {
    hSize != .regular && nav.preferredColumn == .detail
  }

  private var isDetailScrollOwnerForTabInteraction: Bool {
    guard isDetailVisibleForTabInteraction else { return false }
    guard let destination = nav.detailPath.last else {
      return nav.selection?.usesSettingsPanelScrollRoot ?? true
    }
    switch destination {
    case .setting(let setting):
      return setting.usesSettingsPanelScrollRoot
    case .reddit:
      return PostsNav.postDetail(from: destination) != nil
    }
  }

  var body: some View {
    @Bindable var nav = nav

    NavigationSplitView(preferredCompactColumn: $nav.preferredColumn) {
      NavigationStack {
        SettingsSidebarList(
          selectedSetting: nav.selection,
          isTabInteractionOwner: isSidebarVisibleForTabInteraction,
          showWhatsNew: { presentingWhatsNew.toggle() },
          showAnnouncements: { presentingAnnouncement.toggle() },
          showGraphQLDebug: { presentingGQLDebug.toggle() },
          donateMonthly: { openURL(URL(string: "https://patreon.com/user?u=93745105")!) },
          openTipJar: { openURL(URL(string: "https://ko-fi.com/locafe")!) }
        )
        .navigationTitle("Settings")
        .settingsNavigation(nav, origin: .sidebar)
        .redditNavigation(nav, origin: .content)
      }
      .navigationSplitViewColumnWidth(min: 300, ideal: 360)
    } detail: {
      NavigationStack(path: $nav.detailPath) {
        SettingsDetailColumnContent(setting: nav.selection)
          .settingsNavigation(nav, origin: .detail)
          .redditNavigation(nav, origin: .detail)
          .settingsDestinations(nav)
      }
      .environment(\.settingsPanelIsTabInteractionOwner, isDetailScrollOwnerForTabInteraction)
      .environment(\.tabInteractionTab, isDetailScrollOwnerForTabInteraction ? Nav.TabIdentifier.settings : nil)
      .environment(\.tabInteractionCenter, isDetailScrollOwnerForTabInteraction ? tabInteractions : nil)
      .environment(\.tabInteractionRequest, isDetailScrollOwnerForTabInteraction ? tabInteractions.requests[.settings] : nil)
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
      tabInteractions.setIsAtTop(.settings, true)
      AppDiagnostics.shared.breadcrumb("Opened Settings root")
    }
    .routerDeepLinkInbox(
      router: router,
      consume: { nav.consumeDeepLink(path: $0) },
      onRootReset: { nav.reset() }
    )
    .onChange(of: tabInteractions.requests[.settings]) { _, request in
      handleTabInteractionRequest(request)
    }
  }

  private func handleTabInteractionRequest(_ request: TabInteractionRequest?) {
    guard let request else { return }
    switch request.kind {
    case .scrollToTop:
      guard isSidebarVisibleForTabInteraction || isDetailScrollOwnerForTabInteraction else {
        _ = nav.goBackOneStep()
        return
      }
    case .goBack:
      _ = nav.goBackOneStep()
    case .resetToRoot:
      nav.reset()
    }
  }

}

private struct SettingsSidebarList: View {
  private static let topID = "settings-top"

  let selectedSetting: NavDest.Setting?
  let isTabInteractionOwner: Bool
  let showWhatsNew: () -> Void
  let showAnnouncements: () -> Void
  let showGraphQLDebug: () -> Void
  let donateMonthly: () -> Void
  let openTipJar: () -> Void

  var body: some View {
    SettingsPanelScrollRoot(
      topID: Self.topID,
      isTabInteractionOwner: isTabInteractionOwner
    ) {
      SettingsMainSection(selectedSetting: selectedSetting)
      SettingsInfoSection(
        selectedSetting: selectedSetting,
        showWhatsNew: showWhatsNew,
        showAnnouncements: showAnnouncements
      )
      SettingsDeveloperSection(
        selectedSetting: selectedSetting,
        showGraphQLDebug: showGraphQLDebug
      )
      SettingsSupportSection(
        donateMonthly: donateMonthly,
        openTipJar: openTipJar
      )
    }
  }
}

private struct SettingsMainSection: View {
  let selectedSetting: NavDest.Setting?

  var body: some View {
    Section("App") {
      NativeSettingsNavigationRow(.setting(.general), active: selectedSetting == .general, title: "General", systemImage: "gearshape.fill", iconColor: .gray)
      NativeSettingsNavigationRow(.setting(.behavior), active: selectedSetting == .behavior, title: "Behavior", systemImage: "hand.tap.fill", iconColor: .blue)
      NativeSettingsNavigationRow(.setting(.appearance), active: selectedSetting == .appearance, title: "Appearance", systemImage: "paintpalette.fill", iconColor: .purple)
      NativeSettingsNavigationRow(.setting(.accounts), active: selectedSetting == .accounts, title: "Accounts", systemImage: "person.crop.circle.fill", iconColor: .green)
      NativeSettingsNavigationRow(.setting(.diagnostics), active: selectedSetting == .diagnostics, title: "Diagnostics", systemImage: "stethoscope", iconColor: .orange)
    }
  }
}

private struct SettingsInfoSection: View {
  let selectedSetting: NavDest.Setting?
  let showWhatsNew: () -> Void
  let showAnnouncements: () -> Void

  var body: some View {
    Section("Info") {
      NativeSettingsNavigationRow(.setting(.faq), active: selectedSetting == .faq, title: "FAQ", systemImage: "questionmark.circle.fill", iconColor: .teal)
      NativeSettingsNavigationRow(.setting(.about), active: selectedSetting == .about, title: "About", systemImage: "info.circle.fill", iconColor: .indigo)

      NativeSettingsActionRow(title: "Whats New", systemImage: "sparkles", iconColor: .yellow) {
        showWhatsNew()
      }
      .disabled(getCurrentChangelog().isEmpty)

      NativeSettingsActionRow(title: "Announcements", systemImage: "newspaper.fill", iconColor: .cyan) {
        showAnnouncements()
      }
    }
  }
}

private struct SettingsDeveloperSection: View {
  let selectedSetting: NavDest.Setting?
  let showGraphQLDebug: () -> Void

  var body: some View {
    Section("Developer") {
      NativeSettingsActionRow(title: "GraphQL (experimental)", systemImage: "flask.fill", iconColor: .mint) {
        showGraphQLDebug()
      }

      NativeSettingsNavigationRow(.setting(.designLab), active: selectedSetting == .designLab, title: "Design Lab", systemImage: "slider.horizontal.3", iconColor: .pink)
    }
  }
}

private struct SettingsSupportSection: View {
  let donateMonthly: () -> Void
  let openTipJar: () -> Void

  var body: some View {
    Section("Support") {
      NativeSettingsActionRow(title: "Donate monthly", systemImage: "heart.fill", iconColor: .red) {
        donateMonthly()
      }

      NativeSettingsActionRow {
        openTipJar()
      } label: {
        Label {
          Text("Tip jar")
        } icon: {
          SettingsIcon(systemImage: "cup.and.saucer.fill", color: .brown)
        }
      }
    }
  }
}

private struct SettingsDetailColumnContent: View {
  let setting: NavDest.Setting?

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

private extension NavDest.Setting {
  var usesSettingsPanelScrollRoot: Bool {
    switch self {
    case .general, .behavior, .appearance, .accounts, .diagnostics, .about, .commentSwipe, .postSwipe, .accessibility, .filteredSubreddits, .faq, .appIcon:
      return true
    case .designLab:
      return false
    }
  }
}
