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
import SwiftUI

struct RedditSearchResults {
  var posts: [Post]
  var subreddits: [Subreddit]
  var users: [User]

  static var empty: RedditSearchResults {
    RedditSearchResults(posts: [], subreddits: [], users: [])
  }
}

@MainActor
final class RedditWire: ObservableObject {
  static let shared = RedditWire()

  private let store = KeychainTokenStore()
  let client: RedditPOCClient
  private var profileCursorByAfterKey: [String: String] = [:]

  /// All connected accounts (mirrors `Defaults[.graphQLAccounts]`).
  @Published var accounts: [RedditAccount] = []
  /// The currently-selected account (mirrors `redditCredentialSelectedID`).
  @Published var account: RedditAccount?
  /// True when there's a usable session for the selected account.
  @Published var connected = false
  @Published var status = "idle"

  private init() {
    let config = RedditPOCConfiguration(transport: .managedAndroid, tokenStore: store)
    client = RedditPOCClient(configuration: config)
    accounts = Defaults[.graphQLAccounts]
    Task { await restore() }
  }

  // MARK: - Lifecycle

  /// Restore the selected account on launch: migrate any pre-multi-account
  /// single account, point the token store at the selected id, and warm the
  /// app's me + subscriptions caches.
  func restore() async {
    await migrateLegacyAccountIfNeeded()
    accounts = Defaults[.graphQLAccounts]
    guard !accounts.isEmpty else { connected = false; account = nil; return }

    let selID = Defaults[.GeneralDefSettings].redditCredentialSelectedID
    let selected = accounts.first { $0.id == selID } ?? accounts[0]
    await store.setActive(selected.id)
    account = selected
    Defaults[.GeneralDefSettings].redditCredentialSelectedID = selected.id

    connected = ((try? await store.loadCredentials(for: selected.id)) != nil)
    if connected { await refreshSelectedIdentity() }
  }

  /// Move a pre-multi-account single account (Defaults[.graphQLAccount] + the
  /// legacy unkeyed keychain blob) into the new keyed multi-account world.
  private func migrateLegacyAccountIfNeeded() async {
    guard Defaults[.graphQLAccounts].isEmpty, let legacy = Defaults[.graphQLAccount] else { return }
    try? await store.migrateLegacy(to: legacy.id)
    Defaults[.graphQLAccounts] = [legacy]
  }

  // MARK: - Add / select / remove

  /// Add (or re-login) an account from freshly-captured web cookies: persist the
  /// session under a fresh id, mint a bearer, read the profile, dedup by
  /// username, register + select it, and warm the app caches. Rolls back on
  /// failure. Used by onboarding and the switcher's "add account".
  func addAccount(cookies: [HTTPCookie]) async {
    let newID = UUID()
    let previousActive = await store.currentActiveID
    do {
      let map = Dictionary(cookies.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
      let session = try WebSession(cookies: map)
      await store.setActive(newID)
      try await store.saveCredentials(StoredRedditCredentials(webSession: session), for: newID)
      _ = try await client.getAccount() // forces the session→bearer exchange under newID
      let profile = await me()
      let username = profile?.name ?? "reddit"

      // Re-login of an existing account (same username) reuses its id so we
      // don't pile up duplicates — move the fresh creds onto the existing slot.
      if let existing = accounts.first(where: { $0.username.lowercased() == username.lowercased() }) {
        if let creds = try? await store.loadCredentials(for: newID) {
          try? await store.saveCredentials(creds, for: existing.id)
        }
        try? await store.clearCredentials(for: newID)
        await store.setActive(existing.id)
        applySelection(existing.id, profile: profile)
      } else {
        let acct = RedditAccount(
          id: newID,
          username: username,
          avatarURL: profile?.snoovatar_img ?? profile?.icon_img
        )
        accounts.append(acct)
        Defaults[.graphQLAccounts] = accounts
        applySelection(newID, profile: profile)
      }
      connected = true
      dismissOnboarding()
      await syncAppCaches()
      status = "connected ✅ u/\(username)"
    } catch {
      try? await store.clearCredentials(for: newID)
      await store.setActive(previousActive)
      status = "connect failed: \(describe(error))"
    }
  }

  /// Back-compat alias (the debug view calls `connect`).
  func connect(cookies: [HTTPCookie]) async { await addAccount(cookies: cookies) }

  /// Switch the active account (from the account switcher). Points the token
  /// store at `id`, refreshes that account's identity, and reloads me + subs.
  func selectAccount(_ id: UUID) async {
    guard accounts.contains(where: { $0.id == id }) else { return }
    await store.setActive(id)
    Defaults[.GeneralDefSettings].redditCredentialSelectedID = id
    account = accounts.first { $0.id == id }
    connected = true
    await refreshSelectedIdentity()
    status = "switched → u/\(account?.username ?? "?")"
  }

  /// Remove an account: drop its stored session and registry entry. If it was
  /// selected, fall back to another account, or to fully-logged-out.
  func removeAccount(_ id: UUID) async {
    try? await store.clearCredentials(for: id)
    accounts.removeAll { $0.id == id }
    Defaults[.graphQLAccounts] = accounts
    guard account?.id == id else { return }
    if let next = accounts.first {
      await selectAccount(next.id)
    } else {
      account = nil
      connected = false
      await store.setActive(nil)
      Defaults[.GeneralDefSettings].redditCredentialSelectedID = nil
      status = "logged out"
    }
  }

  /// Log out the currently-selected account (falls back to another if present).
  func disconnect() async {
    if let id = account?.id { await removeAccount(id) }
    else { connected = false; account = nil }
  }

  // MARK: - Identity plumbing

  /// Update the selected pointer and the published account record (username /
  /// avatar from a fresh profile when available). Keeps Defaults in sync.
  private func applySelection(_ id: UUID, profile: UserData?) {
    if let idx = accounts.firstIndex(where: { $0.id == id }) {
      if let profile {
        accounts[idx].username = profile.name
        accounts[idx].avatarURL = profile.snoovatar_img ?? profile.icon_img ?? accounts[idx].avatarURL
      }
      account = accounts[idx]
      Defaults[.graphQLAccounts] = accounts
    }
    Defaults[.GeneralDefSettings].redditCredentialSelectedID = id
  }

  /// Re-read the active account's profile and refresh app caches.
  private func refreshSelectedIdentity() async {
    guard let id = account?.id else { return }
    let profile = await me()
    applySelection(id, profile: profile)
    await syncAppCaches()
  }

  private func syncAppCaches() async {
    _ = await RedditAPI.shared.fetchMe(force: true)
    _ = await RedditAPI.shared.fetchSubs()
  }

  private func dismissOnboarding() {
    if Defaults[.GeneralDefSettings].onboardingState != .dismissed {
      Defaults[.GeneralDefSettings].onboardingState = .dismissed
    }
    Nav.shared.presentingSheetsQueue = Nav.shared.presentingSheetsQueue.filter { $0 != .onboarding }
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
  /// fullnames → PostsByIds hydration → PostData.
  func feedPosts(subreddit name: String, isHome: Bool, sort: SubListingSortOption = .best, after: String? = nil) async -> ([PostData], String?) {
    do {
      let ids: [String]
      let pageInfo: PageInfo?
      let gqlSort = redditFeedSortAndTime(from: sort)
      if isHome {
        var extra: [String: JSONValue] = [:]
        if let time = gqlSort.time {
          extra["time"] = .string(time.rawValue)
        }
        let resp = try await client.homeFeedSduiResponse(
          capturedVariables: ["sort": .string(gqlSort.sort.rawValue)],
          after: after,
          extra: extra
        )
        ids = resp.data?.postIDs ?? []
        pageInfo = resp.data?.pageInfo
      } else {
        let resp = try await client.subredditFeedSduiResponse(
          name,
          sort: gqlSort.sort,
          time: gqlSort.time,
          after: after
        )
        ids = resp.data?.postIDs ?? []
        pageInfo = resp.data?.pageInfo
      }
      let nextAfter = (pageInfo?.hasNextPage == false) ? nil : pageInfo?.endCursor
      status = "feed \(isHome ? "home" : name) → \(ids.count) ids, next \(nextAfter == nil ? "none" : "yes")"
      guard !ids.isEmpty else { return ([], nextAfter) }
      return (await postData(forIDs: ids), nextAfter)
    } catch {
      status = "feed failed: \(describe(error))"
      return ([], nil)
    }
  }

  private func redditFeedSortAndTime(from sort: SubListingSortOption) -> (sort: RedditFeedSort, time: RedditFeedTime?) {
    switch sort {
    case .best:
      return (.best, nil)
    case .hot:
      return (.hot, nil)
    case .new:
      return (.newest, nil)
    case .controversial:
      return (.controversial, nil)
    case .top(let topSortOption):
      return (.top, redditFeedTime(from: topSortOption))
    }
  }

  private func redditFeedTime(from topSortOption: SubListingSortOption.TopListingSortOption) -> RedditFeedTime {
    switch topSortOption {
    case .hour:
      return .hour
    case .day:
      return .day
    case .week:
      return .week
    case .month:
      return .month
    case .year:
      return .year
    case .all:
      return .all
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

  func userProfile(_ username: String) async -> UserData? {
    let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    do {
      let resp = try await client.userProfileDetailsResponse(trimmed)
      guard let profile = resp.data?.redditorInfoByName, let user = UserData(graphQL: profile) else {
        status = "profile \(trimmed): could not adapt"
        return nil
      }
      status = "profile → u/\(user.name)"
      return user
    } catch {
      status = "profile failed: \(describe(error))"
      return nil
    }
  }

  func userOverviewData(_ username: String, filter: String? = nil, after: String? = nil) async -> [Either<PostData, CommentData>]? {
    let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let normalizedFilter = filter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    switch normalizedFilter {
    case "posts":
      return await userSubmittedPosts(username: trimmed, after: after).map { posts in
        posts.map { Either<PostData, CommentData>.first($0) }
      }
    case "comments":
      return await userSubmittedComments(username: trimmed, after: after).map { comments in
        comments.map { Either<PostData, CommentData>.second($0) }
      }
    default:
      guard after == nil else { return [] }
      let posts = await userSubmittedPosts(username: trimmed, after: nil) ?? []
      let comments = await userSubmittedComments(username: trimmed, after: nil) ?? []
      let mixed = posts.map { Either<PostData, CommentData>.first($0) } + comments.map { Either<PostData, CommentData>.second($0) }
      return mixed.sorted { lhs, rhs in
        createdEpoch(lhs) > createdEpoch(rhs)
      }
    }
  }

  private func userSubmittedPosts(username: String, after: String?) async -> [PostData]? {
    do {
      let cursor = after.flatMap { profileCursorByAfterKey[profileCursorKey(username: username, filter: "posts", after: $0)] }
      if after != nil, cursor == nil { return [] }
      let resp = try await client.submittedPostsFeedSduiResponse(username, after: cursor)
      let ids = resp.data?.postIDs ?? []
      let posts = await postData(forIDs: ids)
      rememberProfileCursor(resp.data?.pageInfo?.endCursor, username: username, filter: "posts", items: posts.map { "t3_\($0.id)" })
      status = "submitted posts \(username) → \(posts.count)"
      return posts
    } catch {
      status = "submitted posts failed: \(describe(error))"
      return nil
    }
  }

  private func userSubmittedComments(username: String, after: String?) async -> [CommentData]? {
    do {
      let cursor = after.flatMap { profileCursorByAfterKey[profileCursorKey(username: username, filter: "comments", after: $0)] }
      if after != nil, cursor == nil { return [] }
      let resp = try await client.submittedCommentsResponse(username, after: cursor)
      let comments = (resp.data?.comments ?? []).map { node in
        CommentData(
          graphQL: node,
          depth: nil,
          parentID: node.postInfo?.id,
          postFullname: node.postInfo?.id ?? "",
          authorName: username
        )
      }
      rememberProfileCursor(resp.data?.pageInfo?.endCursor, username: username, filter: "comments", items: comments.map { "t1_\($0.id)" })
      status = "submitted comments \(username) → \(comments.count)"
      return comments
    } catch {
      status = "submitted comments failed: \(describe(error))"
      return nil
    }
  }

  private func rememberProfileCursor(_ cursor: String?, username: String, filter: String, items: [String]) {
    guard let cursor, !cursor.isEmpty, let last = items.last else { return }
    profileCursorByAfterKey[profileCursorKey(username: username, filter: filter, after: last)] = cursor
  }

  private func profileCursorKey(username: String, filter: String, after: String) -> String {
    "\(username.lowercased())|\(filter)|\(after)"
  }

  private func createdEpoch(_ item: Either<PostData, CommentData>) -> Double {
    switch item {
    case .first(let post): return post.created_utc ?? post.created
    case .second(let comment): return comment.created_utc ?? comment.created ?? 0
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

  /// Search all over GraphQL. DynamicSearch currently defaults to Reddit's
  /// global posts pane; use its full post payloads plus nested community/profile
  /// objects to provide grouped app results from one endpoint.
  func searchAll(_ query: String, contentWidth: CGFloat = .screenW) async -> RedditSearchResults {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .empty }
    do {
      let resp = try await client.dynamicSearchResponse(trimmed)
      guard let raw = resp.data?.rawData else { return .empty }
      let postDatas = (resp.data?.posts ?? []).map { PostData(graphQL: $0) }.deduped { $0.id }
      let posts = Post.initMultiple(datas: postDatas, contentWidth: contentWidth)
      let subs = raw.searchSubredditObjects
        .compactMap(SubredditData.init(graphQLSearchObject:))
        .deduped { ($0.display_name ?? $0.id).lowercased() }
        .map(Subreddit.init(data:))
      let users = raw.searchUserObjects
        .compactMap(UserData.init(graphQLSearchObject:))
        .deduped { $0.name.lowercased() }
        .map(User.init(data:))
      status = "search all '\(trimmed)' → \(posts.count) posts, \(subs.count) subs, \(users.count) users"
      return RedditSearchResults(posts: posts, subreddits: subs, users: users)
    } catch {
      status = "search all failed: \(describe(error))"
      return .empty
    }
  }

  func searchPosts(_ query: String, contentWidth: CGFloat = .screenW) async -> [Post] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    do {
      let resp = try await client.dynamicSearchResponse(trimmed, pane: .posts)
      let postDatas = (resp.data?.posts ?? []).map { PostData(graphQL: $0) }.deduped { $0.id }
      let posts = Post.initMultiple(datas: postDatas, contentWidth: contentWidth)
      status = "search posts '\(trimmed)' → \(posts.count)"
      return posts
    } catch {
      status = "search posts failed: \(describe(error))"
      return []
    }
  }

  /// Search typeahead over GraphQL. Kept for API compatibility; all-search is
  /// preferred because the live typeahead response can be layout-only.
  func searchSubreddits(_ query: String) async -> [SubredditData] {
    let raw = await dynamicSearchRaw(query, pane: .communities)
    let subs = raw?.searchSubredditObjects
      .compactMap(SubredditData.init(graphQLSearchObject:))
      .deduped { ($0.display_name ?? $0.id).lowercased() } ?? []
    status = "search subreddits '\(query)' → \(subs.count)"
    return subs
  }

  func searchUsers(_ query: String) async -> [UserData] {
    let raw = await dynamicSearchRaw(query, pane: .people)
    let users = raw?.searchUserObjects
      .compactMap(UserData.init(graphQLSearchObject:))
      .deduped { $0.name.lowercased() } ?? []
    status = "search users '\(query)' → \(users.count)"
    return users
  }

  private func dynamicSearchRaw(_ query: String, pane: RedditSearchPane? = nil) async -> JSONValue? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    do {
      let resp = try await client.dynamicSearchResponse(trimmed, pane: pane)
      return resp.data?.rawData
    } catch {
      status = "search failed: \(describe(error))"
      return nil
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

  /// Subscribe/unsubscribe one or more subreddits by fullname (`t5_`).
  func subscribe(subredditIDs: [String], subscribe: Bool) async -> Bool {
    do {
      _ = try await client.updateSubredditSubscriptions(subredditIDs: subredditIDs, subscribe: subscribe, allowSideEffects: true)
      status = "subscribe \(subredditIDs.count) subs \(subscribe) ✅"
      return true
    } catch {
      let message = describe(error)
      status = "subscribe failed: \(message)"
      print("[RedditWire.subscribe] ids=\(subredditIDs) subscribe=\(subscribe) failed: \(message)")
      return false
    }
  }

  /// Favorite/unfavorite a subreddit by fullname (`t5_`).
  func favoriteSubreddit(subredditID: String, favorited: Bool) async -> Bool {
    do {
      _ = try await client.updateSubredditFavoriteState(
        subredditID: subredditID,
        state: favorited ? .favorited : .none,
        allowSideEffects: true
      )
      status = "favorite \(subredditID) \(favorited) ✅"
      return true
    } catch {
      let message = describe(error)
      status = "favorite failed: \(message)"
      print("[RedditWire.favoriteSubreddit] id=\(subredditID) favorited=\(favorited) failed: \(message)")
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
