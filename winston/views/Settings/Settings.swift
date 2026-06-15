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

  var body: some View {
    @Bindable var nav = nav

    NavigationSplitView(preferredCompactColumn: $nav.preferredColumn) {
      NavigationStack {
        SettingsSidebarList(
          selectedSetting: nav.selection,
          showWhatsNew: { presentingWhatsNew.toggle() },
          showAnnouncements: { presentingAnnouncement.toggle() },
          showGraphQLDebug: { presentingGQLDebug.toggle() },
          donateMonthly: { openURL(URL(string: "https://patreon.com/user?u=93745105")!) },
          openTipJar: { openURL(URL(string: "https://ko-fi.com/locafe")!) }
        )
        .navigationTitle("Settings")
        .settingsNavigation(nav, origin: .sidebar)
        .redditNavigation(nav, origin: .content)
        .toolbar { forwardToolbarItem }
      }
      .navigationSplitViewColumnWidth(min: 300, ideal: 360)
    } detail: {
      NavigationStack(path: $nav.detailPath) {
        SettingsDetailColumnContent(setting: nav.selection)
          .settingsNavigation(nav, origin: .detail)
          .redditNavigation(nav, origin: .detail)
          .navigationDestination(for: Router.NavDest.self) { destination in
            RouterDestinationView(destination: destination)
          }
          .toolbar { forwardToolbarItem }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .forwardEdgeSwipe(isActive: hSize != .regular, navigation: nav)
    .sheet(isPresented: $presentingWhatsNew){
      if let isNew = getCurrentChangelog().first {
        WhatsNewView(whatsNew: isNew)
      }
    }
    .sheet(isPresented: $presentingGQLDebug) {
      RedditGQLDebugView()
    }
    .onAppear {
      consumeContextualDestinationIfNeeded()
      consumeRouterPathIfNeeded(router.fullPath)
      AppDiagnostics.shared.breadcrumb("Opened Settings root")
    }
    .onChange(of: router.contextualDestination) { _, _ in
      consumeContextualDestinationIfNeeded()
    }
    .onChange(of: router.fullPath) { _, path in
      consumeRouterPathIfNeeded(path)
    }
    .onChange(of: router.rootResetToken) { _, _ in
      nav.reset()
    }
    .onChange(of: nav.forwardSnapshot) { old, new in
      nav.recordForwardTransition(from: old, to: new)
    }
  }

  @ToolbarContentBuilder private var forwardToolbarItem: some ToolbarContent {
    if nav.canGoForward {
      ToolbarItem(placement: .topBarTrailing) {
        Button { nav.goForward() } label: {
          Image(systemName: "chevron.forward")
        }
        .accessibilityLabel("Go forward")
      }
    }
  }

  /// Deep links / shortcuts arrive on the legacy Router as a contextual destination.
  private func consumeContextualDestinationIfNeeded() {
    guard let destination = router.contextualDestination else { return }
    router.contextualDestination = nil
    openExternalDestination(destination)
  }

  /// `Nav.to(...)` appends to the active tab's `Router.fullPath`. Translate anything that
  /// lands there into `nav` and clear the Router (it no longer drives this surface).
  private func consumeRouterPathIfNeeded(_ path: [Router.NavDest]) {
    guard !path.isEmpty else { return }
    for destination in path { openExternalDestination(destination) }
    router.resetNavPath()
  }

  private func openExternalDestination(_ destination: Router.NavDest) {
    if case .setting(let setting) = destination {
      nav.select(setting)
    } else {
      nav.pushDetail(destination)
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
    .nativeSettingsList()
  }
}

private struct SettingsMainSection: View {
  let selectedSetting: Router.NavDest.Setting?

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
  let selectedSetting: Router.NavDest.Setting?
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
  let selectedSetting: Router.NavDest.Setting?
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
