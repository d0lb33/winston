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
  @Environment(\.useTheme) private var theme

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
    List {
      Group {
        Section {
          ForEach(accounts) { account in
            AccountItem(account: account, inUse: account.id == selectedID)
          }
        } footer: {
          Text("Tap an account to switch to it, or hold the \"me\" (or your username) tab pressed in the bottom bar.")
        }
      }
      .themedListSection()
    }
    .navigationBarTitleDisplayMode(.large)
  }
}

struct AccountItem: View {
  var account: RedditAccount
  var inUse: Bool
  @State private var logoutAlertOpened = false

  var body: some View {
    WListButton(showArrow: false) {
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
          Text("IN USE")
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
            .fontSize(12, .semibold)
            .padding(.vertical, 1)
            .padding(.horizontal, 4)
            .background(RR(4, Color.accentColor))
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
  }
}
