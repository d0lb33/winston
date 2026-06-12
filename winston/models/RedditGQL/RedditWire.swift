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
  private let savedPostsFeedVariables: JSONValue = [
    "feedContextInput": ["layout": "CARD"],
    "includeGoldInfo": true,
    "includePostContentPostHint": true,
    "includePostContentThumbnailEnabled": true,
    "includeSubredditInPosts": true,
    "includeAwards": true,
    "includePostStats": true,
    "includeCurrentUserAwards": false,
    "includeStillMediaAltText": false,
    "includeExtraStillResolutions": false,
    "includeExtendedVideoAsset": false,
    "includePlaybackMp4s": false,
    "includeMuxedMp4s": true,
    "includeDevvitData": false,
    "includeCommunityStatus": true,
  ]

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

  /// Load one page of saved posts. Reddit exposes saved posts and saved
  /// comments as separate GraphQL feeds, so the app keeps their pagination
  /// streams separate instead of synthesizing a mixed listing.
  func savedPosts(after: String? = nil) async -> ([PostData], String?) {
    do {
      let savedPosts = try await client.savedPostsFeedSduiResponse(
        capturedVariables: savedPostsFeedVariables,
        after: after
      )
      let rawData = savedPosts.data?.rawData
      let postConnection = rawData?.firstFeedElementConnection()
      let connectionPostIDs = postConnection?.postIDs ?? []
      let postIDs = connectionPostIDs.isEmpty ? rawData?.savedPostIDs() ?? [] : connectionPostIDs
      let nextAfter = normalizedCursor((postConnection?.pageInfo?.hasNextPage == false) ? nil : postConnection?.pageInfo?.endCursor)
      let posts = await postData(forIDs: postIDs)
      status = "saved posts → \(posts.count) posts, next \(nextAfter == nil ? "none" : "yes")"
      print("[RedditWire.savedPosts] after=\(after ?? "nil") ids=\(postIDs.count) hydrated=\(posts.count) next=\(nextAfter ?? "nil") keys=\(rawData?.topLevelKeysDescription ?? "nil")")
      return (posts, nextAfter)
    } catch {
      let message = describe(error)
      status = "saved posts failed: \(message)"
      print("[RedditWire.savedPosts] after=\(after ?? "nil") failed: \(message)")
      return ([], nil)
    }
  }

  /// Load one page of saved comments using Reddit's paginated saved-comments
  /// GraphQL surface.
  func savedComments(after: String? = nil) async -> ([CommentData], String?) {
    do {
      var extra: [String: JSONValue] = [:]
      if let after, !after.isEmpty {
        extra["after"] = .string(after)
      }
      let savedComments = try await client.legacySavedCommentsResponse(extra: extra)
      let rawData = savedComments.data?.rawData
      let comments = rawData?.savedComments().map { comment in
        CommentData(
          graphQL: comment,
          depth: nil,
          parentID: comment.postInfo?.id,
          postFullname: comment.postInfo?.id ?? "",
          authorName: nil
        )
      } ?? []
      let pageInfo = rawData?.firstPageInfo()
      let nextAfter = normalizedCursor((pageInfo?.hasNextPage == false) ? nil : pageInfo?.endCursor)
      status = "saved comments → \(comments.count) comments, next \(nextAfter == nil ? "none" : "yes")"
      print("[RedditWire.savedComments] after=\(after ?? "nil") comments=\(comments.count) next=\(nextAfter ?? "nil") keys=\(rawData?.topLevelKeysDescription ?? "nil")")
      return (comments, nextAfter)
    } catch {
      let message = describe(error)
      status = "saved comments failed: \(message)"
      print("[RedditWire.savedComments] after=\(after ?? "nil") failed: \(message)")
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

  private func normalizedCursor(_ cursor: String?) -> String? {
    guard let cursor, !cursor.isEmpty else { return nil }
    return cursor
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
  func postWithComments(postID: String, commentID: String? = nil, sort: CommentSortOption = .confidence) async -> (PostData?, [ListingChild<CommentData>]) {
    do {
      if let commentID, !commentID.isEmpty {
        let resp = try await client.commentByIdWithChildrenResponse(commentID: commentID, sort: redditCommentSort(from: sort))
        guard let commentById = resp.data?.commentById else {
          status = "commentByIdWithChildren: no comment in response"
          return (nil, [])
        }
        let postFullname = commentById.postInfo?.id ?? (postID.hasPrefix("t3_") ? postID : "t3_\(postID)")
        let trees = commentById.children?.trees ?? []
        status = "commentByIdWithChildren \(commentID) → \(trees.count) comment nodes"
        let children: [ListingChild<CommentData>] = trees.compactMap { tree in
          guard let node = tree.node else { return nil }
          let cd = CommentData(graphQL: node, depth: tree.depth, parentID: tree.parentId, postFullname: postFullname)
          return ListingChild<CommentData>(kind: "t1", data: cd)
        }
        return (commentById.postInfo.map(PostData.init(graphQL:)), children)
      }

      let resp = try await client.postCommentsResponse(postID: postID, sort: redditCommentSort(from: sort))
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

  private func redditCommentSort(from sort: CommentSortOption) -> RedditCommentSortType {
    switch sort {
    case .new:
      return .newest
    case .qa:
      return .questionAnswer
    default:
      return .confidence
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

  /// Load the Android About-page operation cluster and distill the raw GraphQL
  /// payloads into a UI-safe summary. The response shapes are still being
  /// mapped in RedditPOC, so this intentionally extracts only stable labels,
  /// counts, and flags.
  func subredditAbout(name: String, subredditID: String?) async -> SubredditAboutSummary? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    do {
      let responses = try await client.subredditAbout(name: trimmed, subredditID: subredditID)
      let summary = SubredditAboutSummary(responses: responses)
      status = "about \(trimmed) -> \(summary.loadedOperationCount) operations"
      return summary
    } catch {
      let message = describe(error)
      status = "about failed: \(message)"
      print("[RedditWire.subredditAbout] name=\(trimmed) id=\(subredditID ?? "nil") failed: \(message)")
      return nil
    }
  }

  /// Rules are present in the Android About-page structured-style payload under
  /// `subredditInfoByName.rules`.
  func subredditRules(name: String) async -> [SubredditRuleSummary]? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    do {
      let response = try await client.subredditStructuredStyle(trimmed)
      let rules = response.json?.subredditRules() ?? []
      status = "rules \(trimmed) -> \(rules.count)"
      return rules
    } catch {
      let message = describe(error)
      status = "rules failed: \(message)"
      print("[RedditWire.subredditRules] name=\(trimmed) failed: \(message)")
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
    if case .cloudflareChallenge(let operation, _) = error as? RedditPOCError {
      return "Reddit is asking for a browser challenge before \(operation). Open Reddit login again and complete the challenge."
    }
    return (error as? RedditPOCError).map { "\($0)" } ?? error.localizedDescription
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

struct SubredditAboutSummary: Equatable {
  struct Tile: Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let systemImage: String
  }

  struct TextSection: Equatable, Identifiable {
    let id: String
    let title: String
    let body: String
    let systemImage: String
  }

  var title: String?
  var publicDescription: String?
  var subscribers: Int?
  var activeUsers: Int?
  var createdAt: Date?
  var channelsEnabled: Bool?
  var muted: Bool?
  var postingAllowed: Bool?
  var flairRequired: Bool?
  var wikiExcerpt: String?
  var highlights: [TextSection]
  var widgets: [TextSection]
  var loadedOperationCount: Int

  init(responses: SubredditAboutResponses) {
    let info = responses.info.json
    let composer = responses.postComposerCommunity.json
    let structuredStyle = responses.structuredStyle.json
    let wiki = responses.wiki.json
    let highlightsJSON = responses.communityHighlights?.json
    let postRequirements = responses.postRequirements?.json
    let allJSON = responses.allJSON

    title = info?.firstString(keys: ["title", "displayText", "name", "prefixedName"])
    publicDescription = allJSON.firstNonEmptyString(keys: [
      "publicDescriptionText",
      "publicDescription",
      "descriptionText",
      "description",
      "markdown"
    ])
    subscribers = info?.firstInt(keys: ["subscribersCount", "subscribers", "membersCount"])
      ?? allJSON.firstInt(keys: ["subscribersCount", "subscribers", "membersCount"])
    activeUsers = info?.firstInt(keys: ["activeUserCount", "accountsActive", "accounts_active", "onlineCount"])
      ?? allJSON.firstInt(keys: ["activeUserCount", "accountsActive", "accounts_active", "onlineCount"])
    createdAt = info?.firstDate(keys: ["createdAt", "created", "createdUtc", "createdUTC"])
      ?? allJSON.firstDate(keys: ["createdAt", "created", "createdUtc", "createdUTC"])
    channelsEnabled = responses.channelsEnabled.json?.firstBool(keys: [
      "isSubredditChannelsEnabled",
      "subredditChannelsEnabled",
      "channelsEnabled",
      "isChannelsEnabled"
    ])
    muted = responses.muted?.json?.firstBool(keys: ["isMuted", "muted"])
    postingAllowed = composer?.firstBool(keys: [
      "canSubmit",
      "canCreatePost",
      "isPostingAllowed",
      "isUserAllowedToPost",
      "isContributorAllowed"
    ])
    flairRequired = postRequirements?.firstBool(keys: [
      "isFlairRequired",
      "linkFlairRequired",
      "flairRequired"
    ])
    wikiExcerpt = wiki?.firstNonEmptyString(keys: ["markdown", "content", "text", "body"])?.trimmedAboutBody
    highlights = highlightsJSON?.aboutTextSections(limit: 4, idPrefix: "highlight", fallbackTitle: "Highlight", systemImage: "pin.fill") ?? []
    widgets = structuredStyle?.aboutTextSections(limit: 6, idPrefix: "widget", fallbackTitle: "Community", systemImage: "rectangle.grid.1x2.fill") ?? []

    loadedOperationCount = responses.allJSON.count
  }

  var statusTiles: [Tile] {
    var tiles: [Tile] = []
    if let channelsEnabled {
      tiles.append(Tile(
        id: "channels",
        title: "Channels",
        value: channelsEnabled ? "Enabled" : "Disabled",
        systemImage: "bubble.left.and.bubble.right.fill"
      ))
    }
    if let muted {
      tiles.append(Tile(
        id: "muted",
        title: "Muted",
        value: muted ? "Yes" : "No",
        systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
      ))
    }
    if let postingAllowed {
      tiles.append(Tile(
        id: "posting",
        title: "Posting",
        value: postingAllowed ? "Open" : "Limited",
        systemImage: "square.and.pencil"
      ))
    }
    if let flairRequired {
      tiles.append(Tile(
        id: "flair",
        title: "Post flair",
        value: flairRequired ? "Required" : "Optional",
        systemImage: "tag.fill"
      ))
    }
    return tiles
  }

  var hasExtraContent: Bool {
    !statusTiles.isEmpty || wikiExcerpt != nil || !highlights.isEmpty || !widgets.isEmpty
  }
}

struct SubredditRuleSummary: Equatable, Identifiable {
  let id: String
  let name: String
  let markdown: String
  let priority: Int
}

private extension SubredditAboutResponses {
  var allJSON: [JSONValue] {
    [
      info.json,
      structuredStyle.json,
      postComposerCommunity.json,
      wiki.json,
      translatedStrings?.json,
      channelsEnabled.json,
      devvit?.json,
      settings?.json,
      communityHighlights?.json,
      postRequirements?.json,
      muted?.json,
      pendingInvitations?.json,
      userEligibleToApply?.json,
      eligibleUxExperiences?.json
    ].compactMap { $0 }
  }
}

private extension Array where Element == JSONValue {
  func firstNonEmptyString(keys: [String]) -> String? {
    for value in self {
      if let string = value.firstNonEmptyString(keys: keys) {
        return string
      }
    }
    return nil
  }

  func firstInt(keys: [String]) -> Int? {
    for value in self {
      if let int = value.firstInt(keys: keys) {
        return int
      }
    }
    return nil
  }

  func firstDate(keys: [String]) -> Date? {
    for value in self {
      if let date = value.firstDate(keys: keys) {
        return date
      }
    }
    return nil
  }
}

private extension JSONValue {
  func firstString(keys: [String]) -> String? {
    if let object = objectValue, let value = object.string(for: keys) {
      return value
    }

    for object in objects(containingAny: keys) {
      if let value = object.string(for: keys) {
        return value
      }
    }
    return nil
  }

  func firstNonEmptyString(keys: [String]) -> String? {
    firstString(keys: keys)?.trimmedAboutBody
  }

  func firstInt(keys: [String]) -> Int? {
    if let object = objectValue, let value = object.int(for: keys) {
      return value
    }

    for object in objects(containingAny: keys) {
      if let value = object.int(for: keys) {
        return value
      }
    }
    return nil
  }

  func firstBool(keys: [String]) -> Bool? {
    if let object = objectValue, let value = object.bool(for: keys) {
      return value
    }

    for object in objects(containingAny: keys) {
      if let value = object.bool(for: keys) {
        return value
      }
    }
    return nil
  }

  func firstDate(keys: [String]) -> Date? {
    if let object = objectValue, let value = object.date(for: keys) {
      return value
    }

    for object in objects(containingAny: keys) {
      if let value = object.date(for: keys) {
        return value
      }
    }
    return nil
  }

  func aboutTextSections(
    limit: Int,
    idPrefix: String,
    fallbackTitle: String,
    systemImage: String
  ) -> [SubredditAboutSummary.TextSection] {
    var seen = Set<String>()
    var sections: [SubredditAboutSummary.TextSection] = []
    let candidates = objects(containingAny: ["title", "shortName", "displayText", "text", "markdown", "content", "description", "postTitle"])

    for object in candidates {
      let typeName = object["__typename"]?.stringValue?.lowercased() ?? ""
      let title = object.string(for: ["title", "shortName", "displayText", "label", "postTitle"])?.trimmedAboutBody
      let body = object.string(for: ["markdown", "text", "content", "description", "body"])?.trimmedAboutBody
      let hasWidgetShape = typeName.contains("widget") || object["widgetId"] != nil || object["styles"] != nil
      let hasHighlightShape = typeName.contains("post") || object["post"] != nil || object["postInfo"] != nil || object["postTitle"] != nil

      guard idPrefix != "widget" || hasWidgetShape else { continue }
      guard idPrefix != "highlight" || hasHighlightShape else { continue }
      guard let titleOrBody = title ?? body, !titleOrBody.isEmpty else { continue }

      let resolvedTitle = title ?? fallbackTitle
      let resolvedBody = body ?? titleOrBody
      guard resolvedTitle != resolvedBody || title == nil else { continue }

      let key = "\(resolvedTitle)|\(resolvedBody)"
      guard seen.insert(key).inserted else { continue }

      sections.append(SubredditAboutSummary.TextSection(
        id: "\(idPrefix)-\(sections.count)",
        title: resolvedTitle,
        body: resolvedBody,
        systemImage: systemImage
      ))

      if sections.count >= limit { break }
    }

    return sections
  }

  func subredditRules() -> [SubredditRuleSummary] {
    let ruleObjects = objects(containing: "rules")
      .flatMap { object -> [[String: JSONValue]] in
        guard let rules = object["rules"]?.arrayValue else { return [] }
        return rules.compactMap(\.objectValue)
      }
      .filter { object in
        object["__typename"]?.stringValue == "SubredditRule" || object["content"] != nil || object["priority"] != nil
      }

    var seen = Set<String>()
    return ruleObjects.compactMap { object in
      let name = object.string(for: ["name", "shortName", "short_name", "title"])?.trimmedAboutBody
      let markdown = object["content"]?.objectValue?.string(for: ["markdown", "description", "text", "body"])?.trimmedAboutBody
        ?? object.string(for: ["markdown", "description", "text", "body"])?.trimmedAboutBody
        ?? ""
      let priority = object.int(for: ["priority"]) ?? Int.max
      let id = object.string(for: ["id"]) ?? "\(priority)-\(name ?? "")"

      guard let name, !name.isEmpty, seen.insert(id).inserted else { return nil }
      return SubredditRuleSummary(id: id, name: name, markdown: markdown, priority: priority)
    }
    .sorted { lhs, rhs in
      if lhs.priority == rhs.priority { return lhs.name < rhs.name }
      return lhs.priority < rhs.priority
    }
  }

  func decodeObject<T: Decodable>(_ type: T.Type) -> T? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  func firstFeedElementConnection() -> FeedElementConnection? {
    let connections = objects(containing: "edges")
      .compactMap { JSONValue.object($0).decodeObject(FeedElementConnection.self) }
    return connections.first { !$0.postIDs.isEmpty } ?? connections.first { $0.pageInfo != nil }
  }

  func groupIDs(prefix: String) -> [String] {
    var seen = Set<String>()
    return objects(containing: "groupId").compactMap { object in
      guard let groupID = object["groupId"]?.stringValue, groupID.hasPrefix(prefix), seen.insert(groupID).inserted else {
        return nil
      }
      return groupID
    }
  }

  func savedPostIDs() -> [String] {
    var seen = Set<String>()
    var ids: [String] = []

    func append(_ id: String?) {
      guard let id, id.hasPrefix("t3_"), seen.insert(id).inserted else { return }
      ids.append(id)
    }

    groupIDs(prefix: "t3_").forEach { append($0) }
    objects(containing: "post").forEach { object in
      append(object["post"]?.objectValue?["id"]?.stringValue)
    }
    objects(containing: "postId").forEach { object in
      append(object["postId"]?.stringValue)
    }
    objects(containing: "id").forEach { object in
      let typeName = object["__typename"]?.stringValue ?? ""
      if typeName == "SubredditPost" || typeName == "ProfilePost" || typeName == "Post" {
        append(object["id"]?.stringValue)
      }
    }

    return ids
  }

  func savedComments() -> [RedditPOC.Comment] {
    var seen = Set<String>()
    let candidates = objects(containing: "node") + objects(containing: "comment") + objects(containing: "id")
    return candidates.compactMap { object in
      let comment = object["node"]?.decodeObject(RedditPOC.Comment.self)
        ?? object["comment"]?.decodeObject(RedditPOC.Comment.self)
        ?? JSONValue.object(object).decodeObject(RedditPOC.Comment.self)
      guard let comment, let id = comment.id, id.hasPrefix("t1_"), seen.insert(id).inserted else {
        return nil
      }
      return comment
    }
  }

  func firstPageInfo() -> PageInfo? {
    let pageInfoObjects = objects(containing: "pageInfo")
      .compactMap { $0["pageInfo"]?.decodeObject(PageInfo.self) }
    if let pageInfo = pageInfoObjects.first(where: { $0.endCursor != nil || $0.hasNextPage != nil }) {
      return pageInfo
    }

    return objects(containing: "endCursor")
      .compactMap { JSONValue.object($0).decodeObject(PageInfo.self) }
      .first
  }

  var topLevelKeysDescription: String {
    guard let object = objectValue else { return "not-object" }
    return object.keys.sorted().joined(separator: ",")
  }

  func objects(containing key: String) -> [[String: JSONValue]] {
    var matches: [[String: JSONValue]] = []
    collectObjects(containing: key, into: &matches)
    return matches
  }

  func objects(containingAny keys: [String]) -> [[String: JSONValue]] {
    var matches: [[String: JSONValue]] = []
    collectObjects(containingAny: Set(keys), into: &matches)
    return matches
  }

  private func collectObjects(containing key: String, into matches: inout [[String: JSONValue]]) {
    switch self {
    case .object(let object):
      if object[key] != nil {
        matches.append(object)
      }
      object.values.forEach { $0.collectObjects(containing: key, into: &matches) }
    case .array(let array):
      array.forEach { $0.collectObjects(containing: key, into: &matches) }
    case .null, .bool, .number, .string:
      break
    }
  }

  private func collectObjects(containingAny keys: Set<String>, into matches: inout [[String: JSONValue]]) {
    switch self {
    case .object(let object):
      if object.keys.contains(where: keys.contains) {
        matches.append(object)
      }
      object.values.forEach { $0.collectObjects(containingAny: keys, into: &matches) }
    case .array(let array):
      array.forEach { $0.collectObjects(containingAny: keys, into: &matches) }
    case .null, .bool, .number, .string:
      break
    }
  }
}

private extension Dictionary where Key == String, Value == JSONValue {
  func string(for keys: [String]) -> String? {
    for key in keys {
      if let value = self[key]?.stringValue, !value.isEmpty { return value }
      if let object = self[key]?.objectValue, let value = object.string(for: keys) { return value }
      if let array = self[key]?.arrayValue {
        for item in array {
          if let object = item.objectValue, let value = object.string(for: keys) {
            return value
          }
        }
      }
    }
    return nil
  }

  func int(for keys: [String]) -> Int? {
    for key in keys {
      if let value = self[key]?.intValue { return value }
      if let string = self[key]?.stringValue, let value = Int(string) { return value }
      if let object = self[key]?.objectValue, let value = object.int(for: keys) { return value }
    }
    return nil
  }

  func bool(for keys: [String]) -> Bool? {
    for key in keys {
      if let value = self[key]?.boolValue { return value }
      if let string = self[key]?.stringValue {
        switch string.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: break
        }
      }
      if let object = self[key]?.objectValue, let value = object.bool(for: keys) { return value }
    }
    return nil
  }

  func date(for keys: [String]) -> Date? {
    for key in keys {
      if let seconds = self[key]?.doubleValue {
        return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
      }
      if let string = self[key]?.stringValue {
        if let seconds = Double(string) {
          return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        if let date = ISO8601DateFormatter().date(from: string) {
          return date
        }
      }
      if let object = self[key]?.objectValue, let value = object.date(for: keys) { return value }
    }
    return nil
  }
}

private extension String {
  var trimmedAboutBody: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
    guard !trimmed.isEmpty else { return nil }
    return trimmed
  }
}
