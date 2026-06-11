//
//  RedditAccount.swift
//  winston
//
//  The GraphQL-era notion of a logged-in account. Its `id` is reused as the
//  app's `redditCredentialSelectedID`, so all the existing per-account CoreData
//  cache tagging (CachedSub/CachedMulti `winstonCredentialID`) keeps working
//  without a RedditCredential. Multi-account: the token store keys each web
//  session by this id, and `RedditWire` tracks the selected one.
//

import Foundation
import Defaults

struct RedditAccount: Codable, Identifiable, Hashable, Defaults.Serializable {
  var id: UUID
  var username: String
  var avatarURL: String?
}

extension RedditAccount {
  /// A display-only `RedditCredential` mirror so the legacy account-switcher UI
  /// (which is written against `RedditCredential`) can render GraphQL accounts.
  /// `refreshToken` is set non-nil purely so `validationStatus == .authorized`;
  /// the shell is never persisted to the credential keychain and never used for
  /// a REST call (empty appID/secret make `getUpToDateToken` early-return nil).
  var asCredentialShell: RedditCredential {
    var shell = RedditCredential(refreshToken: "graphql", userName: username, profilePicture: avatarURL)
    shell.id = id
    return shell
  }
}

extension Defaults.Keys {
  /// All connected GraphQL accounts. The selected one is tracked by
  /// `GeneralDefSettings.redditCredentialSelectedID` (reused id).
  static let graphQLAccounts = Key<[RedditAccount]>("graphQLAccounts", default: [])

  /// Legacy single-account key (pre multi-account). Migrated into
  /// `graphQLAccounts` on first launch; kept only so an older build can still
  /// read its account if rolled back. Do not read this directly anymore.
  static let graphQLAccount = Key<RedditAccount?>("graphQLAccount", default: nil)
}
