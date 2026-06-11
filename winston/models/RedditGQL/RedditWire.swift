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
import Defaults

@MainActor
final class RedditWire: ObservableObject {
  static let shared = RedditWire()

  private let store = KeychainTokenStore()
  let client: RedditPOCClient

  @Published var connected = false
  @Published var account: RedditAccount?
  @Published var status = "idle"

  private init() {
    let config = RedditPOCConfiguration(transport: .managedAndroid, tokenStore: store)
    client = RedditPOCClient(configuration: config)
    Task { await refreshConnected() }
  }

  /// Restore connection + account on launch. If a session exists but no account
  /// is recorded yet (e.g. connected before this code shipped), establish it.
  func refreshConnected() async {
    connected = ((try? await client.currentStoredCredentials()) != nil)
    guard connected else { return }
    if let acct = Defaults[.graphQLAccount] {
      account = acct
      Defaults[.GeneralDefSettings].redditCredentialSelectedID = acct.id
    } else {
      await establishAccount()
    }
  }

  /// Persist a freshly-captured web session, mint a bearer, and set up the
  /// account so the app's tabs/caches come alive.
  func connect(cookies: [HTTPCookie]) async {
    do {
      let map = Dictionary(cookies.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
      let session = try WebSession(cookies: map)
      try await client.saveWebSession(session)
      _ = try await client.getAccount() // forces the session→bearer exchange
      connected = true
      await establishAccount()
      status = "connected ✅ u/\(account?.username ?? "?")"
    } catch {
      connected = false
      status = "connect failed: \(describe(error))"
    }
  }

  /// Build/refresh the RedditAccount identity, reuse its id as the app's
  /// selected-credential id (for CoreData cache tagging), dismiss onboarding,
  /// and populate me + subscriptions.
  private func establishAccount() async {
    let profile = await me()
    let acct = RedditAccount(
      id: Defaults[.graphQLAccount]?.id ?? UUID(),
      username: profile?.name ?? "reddit",
      avatarURL: profile?.snoovatar_img ?? profile?.icon_img
    )
    Defaults[.graphQLAccount] = acct
    account = acct
    Defaults[.GeneralDefSettings].redditCredentialSelectedID = acct.id

    if Defaults[.GeneralDefSettings].onboardingState != .dismissed {
      Defaults[.GeneralDefSettings].onboardingState = .dismissed
      Nav.shared.presentingSheetsQueue = Nav.shared.presentingSheetsQueue.filter { $0 != .onboarding }
    }

    _ = await RedditAPI.shared.fetchMe(force: true)
    _ = await RedditAPI.shared.fetchSubs()
  }

  func disconnect() async {
    try? await store.clearCredentials()
    connected = false
    account = nil
    Defaults[.graphQLAccount] = nil
    status = "disconnected"
  }

  /// Hydrate posts over GraphQL (PostsByIds) and adapt them into Winston's
  /// PostData. Accepts bare or `t3_`-prefixed ids (the library normalizes).
  func postData(forIDs ids: [String]) async -> [PostData] {
    guard !ids.isEmpty else { return [] }
    do {
      let resp = try await client.postsByIDsResponse(ids)
      let posts = resp.data?.postsInfoByIds ?? []
      status = "postsByIDs(\(ids.count)) → \(posts.count) posts"
      // Preserve the requested (feed) order; PostsByIds may reorder.
      var byName: [String: SubredditPost] = [:]
      for p in posts { byName[p.id] = p }
      return ids.compactMap { byName[$0] }.map { PostData(graphQL: $0) }
    } catch {
      status = "postsByIDs failed: \(describe(error))"
      return []
    }
  }

  /// Fetch a single post over GraphQL and adapt it into Winston's PostData.
  func postData(forID id: String) async -> PostData? {
    await postData(forIDs: [id]).first
  }

  /// Load one page of a subreddit (or home) feed: SDUI feed → ordered post
  /// fullnames → PostsByIds hydration → PostData. MVP: single page (the
  /// endCursor is available but its input variable isn't wired yet).
  func feedPosts(subreddit name: String, isHome: Bool) async -> ([PostData], String?) {
    do {
      let ids: [String]
      if isHome {
        let resp = try await client.homeFeedSduiResponse(variables: ["sort": "BEST"])
        ids = (resp.data?.homeV3?.elements?.edges ?? [])
          .compactMap { $0.node?.groupId }.filter { $0.hasPrefix("t3_") }
      } else {
        let resp = try await client.subredditFeedSduiResponse(name)
        ids = (resp.data?.subredditV3?.elements?.edges ?? [])
          .compactMap { $0.node?.groupId }.filter { $0.hasPrefix("t3_") }
      }
      status = "feed \(isHome ? "home" : name) → \(ids.count) ids"
      guard !ids.isEmpty else { return ([], nil) }
      return (await postData(forIDs: ids), nil)
    } catch {
      status = "feed failed: \(describe(error))"
      return ([], nil)
    }
  }

  /// Fetch a post + its comment forest over GraphQL. Returns the adapted
  /// PostData and a FLAT list of comment children (each tagged with parent_id)
  /// ready for `nestComments(_, parentID:)`. MVP: initial tree only (no
  /// load-more; "more" nodes are dropped).
  func postWithComments(postID: String) async -> (PostData?, [ListingChild<CommentData>]) {
    do {
      let resp = try await client.postCommentsResponse(postID: postID)
      guard let post = resp.data?.postInfoById else {
        status = "postComments: no post in response"
        return (nil, [])
      }
      let postFullname = post.id // "t3_…"
      let trees = post.commentForest?.trees ?? []
      status = "postComments \(postFullname) → \(trees.count) comment nodes"
      let children: [ListingChild<CommentData>] = trees.compactMap { tree in
        guard let node = tree.node else { return nil } // skip "more" nodes (MVP)
        let cd = CommentData(graphQL: node, depth: tree.depth, parentID: tree.parentId, postFullname: postFullname)
        return ListingChild<CommentData>(kind: "t1", data: cd)
      }
      return (PostData(graphQL: post), children)
    } catch {
      status = "postComments failed: \(describe(error))"
      return (nil, [])
    }
  }

  // MARK: - User / identity

  /// The signed-in user's profile (GetAccount → UserData).
  func me() async -> UserData? {
    do {
      let resp = try await client.getAccountResponse()
      guard let acct = resp.data, let ud = UserData(graphQL: acct) else {
        status = "me: could not adapt account"
        return nil
      }
      status = "me → u/\(ud.name)"
      return ud
    } catch {
      status = "me failed: \(describe(error))"
      return nil
    }
  }

  /// The signed-in user's subreddits (UserSubreddits → [SubredditData]).
  func subscriptions() async -> [SubredditData] {
    do {
      let resp = try await client.userSubredditsResponse()
      let subs = resp.data?.subreddits ?? []
      status = "subscriptions → \(subs.count) subs"
      return subs.map { SubredditData(graphQL: $0) }
    } catch {
      status = "subscriptions failed: \(describe(error))"
      return []
    }
  }

  // MARK: - Mutations

  /// Vote on a post (`t3_`) or comment (`t1_`). Maps winston's VoteAction to the
  /// library's VoteState and dispatches on the fullname prefix.
  func vote(fullname: String, action: RedditAPI.VoteAction) async -> Bool {
    let state: VoteState = action == .up ? .up : (action == .down ? .down : .none)
    do {
      if fullname.hasPrefix("t1_") {
        _ = try await client.voteComment(fullname, state: state, allowSideEffects: true)
      } else {
        _ = try await client.votePost(fullname, state: state, allowSideEffects: true)
      }
      status = "vote \(fullname) \(state.rawValue) ✅"
      return true
    } catch {
      status = "vote failed: \(describe(error))"
      return false
    }
  }

  /// Save/unsave a post (`t3_`) or comment (`t1_`).
  func save(fullname: String, saved: Bool) async -> Bool {
    let state: SaveState = saved ? .saved : .unsaved
    do {
      if fullname.hasPrefix("t1_") {
        _ = try await client.saveComment(fullname, state: state, allowSideEffects: true)
      } else {
        _ = try await client.savePost(fullname, state: state, allowSideEffects: true)
      }
      status = "save \(fullname) \(saved) ✅"
      return true
    } catch {
      status = "save failed: \(describe(error))"
      return false
    }
  }

  private func describe(_ error: Error) -> String {
    (error as? RedditPOCError).map { "\($0)" } ?? error.localizedDescription
  }

  // MARK: - Capture (Phase 1: learn uncaptured response shapes)
  // Dumps the full response body to the console (filter: GQLBODY) so we can
  // reverse-engineer the SDUI feed envelope and the comment tree shape.

  private func capture(_ op: RedditOperation, variables: JSONValue) async -> String {
    do {
      let resp = try await client.call(op, variables: variables)
      print("[GQLBODY \(op.rawValue)] \(resp.bodyText)")
      status = "\(op.rawValue) → HTTP \(resp.statusCode), \(resp.bodyData.count) bytes"
      return resp.bodyText
    } catch {
      let msg = describe(error)
      print("[GQLBODY \(op.rawValue) ERROR] \(msg)")
      status = "\(op.rawValue) error: \(msg)"
      return msg
    }
  }

  func captureSubredditFeed(_ name: String) async -> String {
    await capture(.subredditFeedSdui, variables: ["subredditName": .string(name)])
  }

  func captureHomeFeed() async -> String {
    await capture(.homeFeedSdui, variables: ["sort": "BEST"])
  }

  func capturePostComments(_ postID: String) async -> String {
    guard let vars = try? RedditBuilders.postCommentsVariables(postID: postID) else {
      return "invalid post id"
    }
    return await capture(.postComments, variables: vars)
  }

  func captureGetAccount() async -> String {
    await capture(.getAccount, variables: RedditBuilders.getAccountVariables())
  }

  func captureUserSubreddits() async -> String {
    await capture(.userSubreddits, variables: RedditBuilders.userSubredditsVariables())
  }
}
