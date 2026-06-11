//
//  KeychainTokenStore.swift
//  winston
//
//  Production token store for RedditPOC: the library only ships an in-memory
//  store, so the app provides the durable one. We persist the whole
//  StoredRedditCredentials blob (web session + last Android bearer) so the
//  managed-android transport can re-mint the bearer from the stored
//  reddit_session cookie across launches.
//

import Foundation
import RedditPOC
import KeychainAccess

actor KeychainTokenStore: TokenStore {
  private let keychain: Keychain
  private let key = "credentials"

  init(service: String = "lo.cafe.winston.reddit-poc") {
    keychain = Keychain(service: service)
  }

  func loadCredentials() async throws -> StoredRedditCredentials? {
    guard let encoded = keychain[key], let data = Data(base64Encoded: encoded) else { return nil }
    return try JSONDecoder().decode(StoredRedditCredentials.self, from: data)
  }

  func saveCredentials(_ credentials: StoredRedditCredentials) async throws {
    let data = try JSONEncoder().encode(credentials)
    keychain[key] = data.base64EncodedString()
  }

  func clearCredentials() async throws {
    keychain[key] = nil
  }
}
