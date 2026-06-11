//
//  KeychainTokenStore.swift
//  winston
//
//  Durable, account-keyed token store for RedditPOC. The library only ships an
//  in-memory store, so the app provides the durable one.
//
//  Multi-account is purely a store-side concern: `RedditPOCClient` loads
//  credentials from its `TokenStore` on *every* call (no in-memory bearer
//  cache), so we persist one `StoredRedditCredentials` blob per account id and
//  the `TokenStore` conformance proxies to whichever account is currently
//  *active*. Switching accounts = `setActive(_:)`; no client rebuild needed.
//

import Foundation
import RedditPOC
import KeychainAccess

actor KeychainTokenStore: TokenStore {
  private let keychain: Keychain
  private var activeID: UUID?

  /// Pre-multi-account single-account key. Migrated into a keyed slot on first
  /// launch (`migrateLegacy(to:)`).
  private static let legacyKey = "credentials"

  init(service: String = "lo.cafe.winston.reddit-poc") {
    keychain = Keychain(service: service)
  }

  private func key(for id: UUID) -> String { "credentials-\(id.uuidString)" }

  /// Point the `TokenStore` conformance (used by the shared client) at a
  /// specific account. Pass `nil` when fully logged out.
  func setActive(_ id: UUID?) { activeID = id }
  var currentActiveID: UUID? { activeID }

  // MARK: - Keyed API (used by add-account before the account is app-selected)

  func loadCredentials(for id: UUID) throws -> StoredRedditCredentials? {
    try decode(keychain[key(for: id)])
  }

  func saveCredentials(_ credentials: StoredRedditCredentials, for id: UUID) throws {
    keychain[key(for: id)] = try encode(credentials)
  }

  func clearCredentials(for id: UUID) throws {
    try keychain.remove(key(for: id))
  }

  /// One-time move of the legacy single-account blob into a keyed slot. Returns
  /// true if a legacy blob existed and was migrated.
  @discardableResult
  func migrateLegacy(to id: UUID) throws -> Bool {
    guard let legacy = keychain[Self.legacyKey] else { return false }
    if keychain[key(for: id)] == nil { keychain[key(for: id)] = legacy }
    try? keychain.remove(Self.legacyKey)
    return true
  }

  // MARK: - TokenStore conformance (proxies to the active account)

  func loadCredentials() async throws -> StoredRedditCredentials? {
    guard let activeID else { return nil }
    return try loadCredentials(for: activeID)
  }

  func saveCredentials(_ credentials: StoredRedditCredentials) async throws {
    guard let activeID else { return }
    try saveCredentials(credentials, for: activeID)
  }

  func clearCredentials() async throws {
    guard let activeID else { return }
    try clearCredentials(for: activeID)
  }

  // MARK: - Helpers

  private func decode(_ encoded: String?) throws -> StoredRedditCredentials? {
    guard let encoded, let data = Data(base64Encoded: encoded) else { return nil }
    return try JSONDecoder().decode(StoredRedditCredentials.self, from: data)
  }

  private func encode(_ credentials: StoredRedditCredentials) throws -> String {
    try JSONEncoder().encode(credentials).base64EncodedString()
  }
}
