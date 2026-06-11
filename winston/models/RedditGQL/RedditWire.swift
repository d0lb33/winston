//
//  RedditWire.swift
//  winston
//
//  App-side façade over the RedditPOC library. Owns a single managed-android
//  RedditPOCClient backed by the Keychain token store, and bridges the
//  library's GraphQL responses into Winston's REST-shaped models via the
//  app-side adapters (PostData(graphQL:)).
//
//  This is the seam the migration grows from: the client lives here; the UI
//  and models stay unchanged.
//

import Foundation
import RedditPOC

@MainActor
final class RedditWire: ObservableObject {
  static let shared = RedditWire()

  private let store = KeychainTokenStore()
  let client: RedditPOCClient

  @Published var connected = false
  @Published var status = "idle"

  private init() {
    let config = RedditPOCConfiguration(transport: .managedAndroid, tokenStore: store)
    client = RedditPOCClient(configuration: config)
    Task { await refreshConnected() }
  }

  func refreshConnected() async {
    connected = (try? await client.currentStoredCredentials()) != nil
  }

  /// Persist a freshly-captured web session and validate it by minting a bearer.
  func connect(cookies: [HTTPCookie]) async {
    do {
      let map = Dictionary(cookies.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
      let session = try WebSession(cookies: map)
      try await client.saveWebSession(session)
      _ = try await client.getAccount() // forces the session→bearer exchange
      connected = true
      status = "connected ✅ (bearer minted via RedditPOC)"
    } catch {
      connected = false
      status = "connect failed: \(describe(error))"
    }
  }

  func disconnect() async {
    try? await store.clearCredentials()
    connected = false
    status = "disconnected"
  }

  /// Fetch a post over GraphQL and adapt it into Winston's PostData.
  func postData(forID id: String) async -> PostData? {
    do {
      let resp = try await client.postsByIDs([id])
      status = "postsByIDs → HTTP \(resp.statusCode), \(resp.bodyData.count) bytes"
      guard
        let root = try JSONSerialization.jsonObject(with: resp.bodyData) as? [String: Any],
        let data = root["data"] as? [String: Any],
        let arr = data["postsInfoByIds"] as? [[String: Any]],
        let first = arr.first,
        let pd = PostData(graphQL: first)
      else {
        status = "could not adapt response into PostData"
        return nil
      }
      return pd
    } catch {
      status = "postsByIDs failed: \(describe(error))"
      return nil
    }
  }

  private func describe(_ error: Error) -> String {
    (error as? RedditPOCError).map { "\($0)" } ?? error.localizedDescription
  }
}
