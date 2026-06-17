//
//  AccountsPanel.swift
//  winston
//
//  Settings panel for the connected Reddit accounts (logged in via the
//  reddit.com webview; sessions managed by RedditWire).
//

import SwiftUI
import Defaults
import Nuke

struct AccountsPanel: View {
  @ObservedObject private var wire = RedditWire.shared

  var body: some View {
    Group {
      if wire.accounts.isEmpty {
        AccountsEmptyView()
      } else {
        AccountsList(accounts: wire.accounts, selectedID: wire.account?.id)
      }
    }
    .navigationTitle("Accounts")
    .toolbar {
      ToolbarItem {
        Button {
          // Adding an account = logging in via the reddit.com webview.
          Nav.present(.onboarding)
        } label: {
          Image(systemName: "plus")
        }
      }
    }
    .navigationBarTitleDisplayMode(.large)
  }
}

struct AccountsList: View {
  var accounts: [RedditAccount]
  var selectedID: UUID?

  var body: some View {
    SettingsPanelScrollRoot(topID: "settings-accounts-top") {
      Section {
        ForEach(accounts) { account in
          AccountItem(account: account, inUse: account.id == selectedID)
        }
      } footer: {
        Text("Tap an account to switch to it, or hold the \"me\" (or your username) tab pressed in the bottom bar.")
      }
    }
    .navigationBarTitleDisplayMode(.large)
  }
}

struct AccountItem: View {
  var account: RedditAccount
  var inUse: Bool
  @State private var logoutAlertOpened = false

  var body: some View {
    NativeSettingsActionRow {
      guard !inUse else { return }
      Task { await RedditWire.shared.selectAccount(account.id) }
    } label: {
      HStack {
        Label {
          Text("u/\(account.username)")
            .lineLimit(1)
            .fontSize(17, .regular)
        } icon: {
          if let pic = account.avatarURL, let url = URL(string: pic) {
            URLImage(url: url, processors: [.resize(size: .init(width: 32, height: 32))])
              .scaledToFill()
              .clipShape(Circle())
          } else {
            Image(systemName: "person.crop.circle.fill")
              .foregroundStyle(Color.accentColor)
          }
        }

        Spacer()

        if inUse {
          Image(systemName: "checkmark")
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.accentColor)
        }
      }
    }
    .contextMenu {
      Button("Log out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
        logoutAlertOpened = true
      }
    }
    .alert("Log out of u/\(account.username)?", isPresented: $logoutAlertOpened) {
      Button("Yes, log out", role: .destructive) {
        Task { await RedditWire.shared.removeAccount(account.id) }
      }
      Button("Cancel", role: .cancel) { logoutAlertOpened = false }
    }
  }
}

struct AccountsEmptyView: View {
  @Environment(\.settingsPanelIsTabInteractionOwner) private var isTabInteractionOwner
  @EnvironmentObject private var tabInteractions: TabInteractionCenter
  private let ownerID = TabInteractionOwnerID("settings.accounts-empty")

  var body: some View {
    VStack(spacing: 20) {
      VStack(spacing: 16) {
        Image(.emptyCredential)
          .resizable()
          .frame(136)
          .clipShape(Circle())
        VStack(spacing: 4) {
          Text("No accounts yet")
            .fontSize(24, .bold)
          Text("Log in with your Reddit account to get started.")
            .fontSize(16, .medium).opacity(0.75)
        }
      }

      Button("Log in to Reddit", systemImage: "person.fill.badge.plus") {
        Nav.present(.onboarding)
      }
      .buttonStyle(.action)
    }
    .compositingGroup()
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
    .onAppear {
      AppDiagnostics.asyncBreadcrumb(
        "tabInteraction.accountsEmptyAppear",
        metadata: accountsEmptyTabInteractionMetadata(branch: "appear")
      )
      activateOwnerIfNeeded()
    }
    .onDisappear {
      AppDiagnostics.asyncBreadcrumb(
        "tabInteraction.accountsEmptyDisappear",
        metadata: accountsEmptyTabInteractionMetadata(branch: "disappear")
      )
      tabInteractions.deactivateScrollOwner(ownerID, for: .settings)
    }
    .onChange(of: isTabInteractionOwner) { _, isOwner in
      AppDiagnostics.asyncBreadcrumb(
        "tabInteraction.accountsEmptyOwnerFlagChanged",
        metadata: accountsEmptyTabInteractionMetadata(branch: "ownerFlagChanged")
          .merging(["isOwner": "\(isOwner)"]) { current, _ in current }
      )
      if isOwner {
        activateOwnerIfNeeded()
      } else {
        tabInteractions.deactivateScrollOwner(ownerID, for: .settings)
      }
    }
  }

  private func activateOwnerIfNeeded() {
    guard isTabInteractionOwner else { return }
    AppDiagnostics.asyncBreadcrumb(
      "tabInteraction.accountsEmptyActivateOwner",
      metadata: accountsEmptyTabInteractionMetadata(branch: "activateOwner")
    )
    tabInteractions.activateScrollOwner(ownerID, for: .settings, initialIsAtTop: true)
  }

  private func accountsEmptyTabInteractionMetadata(branch: String) -> [String: String] {
    tabInteractions.diagnosticsMetadata(for: .settings).merging([
      "branch": branch,
      "owner": ownerID.rawValue,
      "isTabInteractionOwner": "\(isTabInteractionOwner)"
    ]) { current, _ in current }
  }
}
