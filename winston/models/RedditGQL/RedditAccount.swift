//
//  RedditAccount.swift
//  winston
//
//  The GraphQL-era notion of a logged-in account. Its `id` is reused as the
//  app's `redditCredentialSelectedID`, so all the existing per-account CoreData
//  cache tagging (CachedSub/CachedMulti `winstonCredentialID`) keeps working
//  without a RedditCredential.
//

import Foundation
import Defaults

struct RedditAccount: Codable, Identifiable, Hashable, Defaults.Serializable {
  var id: UUID
  var username: String
  var avatarURL: String?
}

extension Defaults.Keys {
  /// The currently connected GraphQL account (single-account for now;
  /// multi-account will key the token store by this id).
  static let graphQLAccount = Key<RedditAccount?>("graphQLAccount", default: nil)
}
