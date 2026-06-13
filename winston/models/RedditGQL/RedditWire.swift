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
  /// Continuation cursors for "load more comments" stubs, keyed by stub id
  /// (the GraphQL comment tree exposes a cursor, not child id lists).
  var moreCursorByStubID: [String: String] = [:]

  /// All connected accounts (mirrors `Defaults[.graphQLAccounts]`).
  @Published var accounts: [RedditAccount] = []
  /// The currently-selected account (mirrors `redditCredentialSelectedID`).
  @Published var account: RedditAccount?
  /// True when there's a usable session for the selected account.
  @Published var connected = false
  @Published var status = "idle" {
    didSet {
      if oldValue != status {
        AppDiagnostics.shared.record(.info, category: "reddit.status", message: status)
      }
    }
  }
  /// The signed-in user's profile entity (replaces the REST-era
  /// REST-era identity cache). Refreshed by `fetchMe(force:)`.
  @Published var me: User?

  private init() {
    let config = RedditPOCConfiguration(transport: .managedAndroid, tokenStore: store)
    client = RedditPOCClient(configuration: config)
    accounts = Defaults[.graphQLAccounts]
    AppDiagnostics.shared.record(.info, category: "reddit.init", message: "RedditWire initialized", metadata: ["accounts": "\(accounts.count)"])
    Task { await restore() }
  }

  // MARK: - Lifecycle

  /// Restore the selected account on launch: migrate any pre-multi-account
  /// single account, point the token store at the selected id, and warm the
  /// app's me + subscriptions caches.
  func restore() async {
    AppDiagnostics.shared.breadcrumb("RedditWire.restore started")
    await migrateLegacyAccountIfNeeded()
    accounts = Defaults[.graphQLAccounts]
    guard !accounts.isEmpty else {
      connected = false
      account = nil
      AppDiagnostics.shared.breadcrumb("RedditWire.restore no accounts")
      return
    }

    let selID = Defaults[.GeneralDefSettings].redditCredentialSelectedID
    let selected = accounts.first { $0.id == selID } ?? accounts[0]
    account = selected
    Defaults[.GeneralDefSettings].redditCredentialSelectedID = selected.id

    guard ((try? await store.loadCredentials(for: selected.id)) != nil) else {
      await store.setActive(nil)
      connected = false
      me = nil
      Self.currentUserName = nil
      status = "missing session for u/\(selected.username)"
      AppDiagnostics.shared.record(.warning, category: "reddit.session", message: "Selected account missing credentials", metadata: ["account": selected.username, "id": selected.id.uuidString])
      return
    }

    await store.setActive(selected.id)
    connected = true
    await refreshSelectedIdentity()
    AppDiagnostics.shared.breadcrumb("RedditWire.restore connected", metadata: ["account": selected.username])
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
    AppDiagnostics.shared.breadcrumb("RedditWire.addAccount started", metadata: ["cookieCount": "\(cookies.count)"])
    let newID = UUID()
    let previousActive = await store.currentActiveID
    do {
      let map = Dictionary(cookies.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
      let session = try WebSession(cookies: map)
      await store.setActive(newID)
      try await store.saveCredentials(StoredRedditCredentials(webSession: session), for: newID)
      _ = try await client.getAccount() // forces the session→bearer exchange under newID
      let profile = await accountProfile()
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
      AppDiagnostics.shared.record(.info, category: "reddit.session", message: "Account connected", metadata: ["account": username])
    } catch {
      try? await store.clearCredentials(for: newID)
      await store.setActive(previousActive)
      status = "connect failed: \(describe(error))"
      AppDiagnostics.shared.record(.error, category: "reddit.session", message: "Account connect failed", metadata: ["error": describe(error)])
    }
  }

  /// Back-compat alias (the debug view calls `connect`).
  func connect(cookies: [HTTPCookie]) async { await addAccount(cookies: cookies) }

  /// Switch the active account (from the account switcher). Points the token
  /// store at `id`, refreshes that account's identity, and reloads me + subs.
  func selectAccount(_ id: UUID) async {
    AppDiagnostics.shared.breadcrumb("RedditWire.selectAccount", metadata: ["id": id.uuidString])
    guard accounts.contains(where: { $0.id == id }) else { return }
    guard ((try? await store.loadCredentials(for: id)) != nil) else {
      Defaults[.GeneralDefSettings].redditCredentialSelectedID = id
      account = accounts.first { $0.id == id }
      await store.setActive(nil)
      connected = false
      me = nil
      Self.currentUserName = nil
      status = "missing session for u/\(account?.username ?? "?")"
      AppDiagnostics.shared.record(.warning, category: "reddit.session", message: "Selected account missing credentials", metadata: ["id": id.uuidString])
      return
    }

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
    AppDiagnostics.shared.breadcrumb("RedditWire.removeAccount", metadata: ["id": id.uuidString])
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
    AppDiagnostics.shared.breadcrumb("RedditWire.disconnect")
    if let id = account?.id { await removeAccount(id) }
    else { connected = false; account = nil }
  }

  func diagnosticsSnapshot() async -> [String: String] {
    let selectedID = Defaults[.GeneralDefSettings].redditCredentialSelectedID
    let hasSelectedCredentials: Bool
    if let selectedID {
      hasSelectedCredentials = ((try? await store.loadCredentials(for: selectedID)) != nil)
    } else {
      hasSelectedCredentials = false
    }

    return [
      "status": status,
      "connected": "\(connected)",
      "account": account?.username ?? "none",
      "accountID": account?.id.uuidString ?? "none",
      "accountsCount": "\(accounts.count)",
      "selectedDefaultID": selectedID?.uuidString ?? "none",
      "selectedHasCredentials": "\(hasSelectedCredentials)",
      "me": me?.data?.name ?? "none",
      "currentUserName": Self.currentUserName ?? "none",
      "moreCursorCount": "\(moreCursorByStubID.count)"
    ]
  }

  func debugResetGraphQLSessionState() async {
    AppDiagnostics.shared.record(.warning, category: "reddit.debugReset", message: "Resetting GraphQL account state", metadata: ["accounts": "\(accounts.count)"])
    for account in accounts {
      try? await store.clearCredentials(for: account.id)
    }
    accounts = []
    account = nil
    connected = false
    me = nil
    Self.currentUserName = nil
    await store.setActive(nil)
    Defaults[.graphQLAccounts] = []
    Defaults[.graphQLAccount] = nil
    Defaults[.GeneralDefSettings].redditCredentialSelectedID = nil
    status = "GraphQL account state reset"
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
    let profile = await accountProfile()
    applySelection(id, profile: profile)
    await syncAppCaches()
  }

  private func syncAppCaches() async {
    await fetchMe(force: true)
    await fetchSubs()
    await fetchMyMultis()
  }

  private func dismissOnboarding() {
    if Defaults[.GeneralDefSettings].onboardingState != .dismissed {
      Defaults[.GeneralDefSettings].onboardingState = .dismissed
    }
    Nav.shared.presentingSheetsQueue = Nav.shared.presentingSheetsQueue.filter { $0 != .onboarding }
  }

  /// Hydrate posts over GraphQL (PostsByIds) and adapt them into Winston's
  /// PostData. Accepts bare, malformed `_id`, or `t3_`-prefixed ids.
  func postData(forIDs ids: [String]) async -> [PostData] {
    guard !ids.isEmpty else { return [] }
    let requestIDs = ids.map(normalizedPostFullnameForRequest)
    if requestIDs != ids {
      AppDiagnostics.asyncRecord(
        .warning,
        category: "reddit.posts",
        message: "Normalized malformed post ids before PostsByIds",
        metadata: [
          "ids": ids.joined(separator: ","),
          "normalized": requestIDs.joined(separator: ",")
        ]
      )
    }
    do {
      let resp = try await client.postsByIDsResponse(requestIDs)
      let posts = resp.data?.postsInfoByIds ?? []
      status = "postsByIDs(\(requestIDs.count)) → \(posts.count) posts"
      return orderedPostData(posts, requestedIDs: requestIDs)
    } catch {
      let message = describe(error)
      if requestIDs.count > 1 {
        AppDiagnostics.asyncRecord(
          .warning,
          category: "reddit.posts",
          message: "PostsByIds batch failed; retrying individually",
          metadata: [
            "requested": "\(requestIDs.count)",
            "error": message
          ]
        )
        let recovered = await recoverPostDataIndividually(forIDs: requestIDs)
        status = "postsByIDs recovered \(recovered.count)/\(requestIDs.count) after batch failure"
        return recovered
      }
      status = "postsByIDs failed: \(message)"
      AppDiagnostics.asyncRecord(
        .error,
        category: "reddit.posts",
        message: "PostsByIds failed",
        metadata: [
          "ids": requestIDs.joined(separator: ","),
          "error": message
        ]
      )
      return []
    }
  }

  private func orderedPostData(_ posts: [SubredditPost], requestedIDs ids: [String]) -> [PostData] {
    // Preserve the requested (feed) order; PostsByIds may reorder.
    var byName: [String: SubredditPost] = [:]
    for post in posts {
      byName[post.id] = post
      if post.id.hasPrefix("t3_") {
        byName[String(post.id.dropFirst(3))] = post
      }
    }
    return ids.compactMap { id in
      byName[id] ?? byName[id.hasPrefix("t3_") ? String(id.dropFirst(3)) : "t3_\(id)"]
    }
    .map { PostData(graphQL: $0) }
  }

  private func recoverPostDataIndividually(forIDs ids: [String]) async -> [PostData] {
    var recovered: [PostData] = []
    var failed: [String] = []

    for id in ids {
      do {
        let resp = try await client.postsByIDsResponse([id])
        let posts = orderedPostData(resp.data?.postsInfoByIds ?? [], requestedIDs: [id])
        if posts.isEmpty {
          failed.append(id)
        } else {
          recovered.append(contentsOf: posts)
        }
      } catch {
        failed.append(id)
      }
    }

    AppDiagnostics.asyncRecord(
      failed.isEmpty ? .info : .warning,
      category: "reddit.posts",
      message: "PostsByIds individual recovery finished",
      metadata: [
        "requested": "\(ids.count)",
        "recovered": "\(recovered.count)",
        "failed": "\(failed.count)",
        "failedIDs": failed.prefix(12).joined(separator: ",")
      ]
    )
    return recovered
  }

  private func normalizedPostFullnameForRequest(_ rawID: String) -> String {
    var id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
    if id.hasPrefix("t3_") {
      return id
    }
    while id.hasPrefix("_") {
      id.removeFirst()
    }
    return "t3_\(id)"
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
      let duplicateIDCount = ids.count - Set(ids).count
      AppDiagnostics.asyncRecord(
        ids.count < 7 && nextAfter != nil ? .warning : .info,
        category: "reddit.feed",
        message: "Feed IDs extracted",
        metadata: [
          "feed": isHome ? "home" : name,
          "sort": gqlSort.sort.rawValue,
          "after": after ?? "nil",
          "ids": "\(ids.count)",
          "duplicateIDs": "\(duplicateIDCount)",
          "hasNextPage": pageInfo?.hasNextPage.map(String.init) ?? "nil",
          "nextAfter": nextAfter ?? "nil",
          "firstIDs": ids.prefix(8).joined(separator: ",")
        ]
      )
      guard !ids.isEmpty else { return ([], nil) }
      let posts = await postData(forIDs: ids)
      return (posts, posts.isEmpty ? nil : nextAfter)
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
      let savedPosts = try await client.savedPostsFeedSduiResponse(after: after)
      let rawData = savedPosts.data?.rawData
      let postConnection = rawData?.firstFeedElementConnection()
      let connectionPostIDs = postConnection?.postIDs ?? []
      let postIDs = connectionPostIDs.isEmpty ? rawData?.savedPostIDs() ?? [] : connectionPostIDs
      let posts = await postData(forIDs: postIDs)
      let nextAfter = posts.isEmpty ? nil : normalizedCursor((postConnection?.pageInfo?.hasNextPage == false) ? nil : postConnection?.pageInfo?.endCursor)
      status = "saved posts → \(posts.count) posts, next \(nextAfter == nil ? "none" : "yes")"
      return (posts, nextAfter)
    } catch {
      let message = describe(error)
      status = "saved posts failed: \(message)"
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
      let nextAfter = comments.isEmpty ? nil : normalizedCursor((pageInfo?.hasNextPage == false) ? nil : pageInfo?.endCursor)
      status = "saved comments → \(comments.count) comments, next \(nextAfter == nil ? "none" : "yes")"
      return (comments, nextAfter)
    } catch {
      let message = describe(error)
      status = "saved comments failed: \(message)"
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
        var children = adaptCommentTrees(trees, postFullname: postFullname)
        let targetFullname = commentID.hasPrefix("t1_") ? commentID : "t1_\(commentID)"
        if let targetIndex = children.firstIndex(where: { $0.data?.name == targetFullname }) {
          if isMissingCommentBody(children[targetIndex].data), let selected = await selectedCommentChild(commentID: commentID, postFullname: postFullname) {
            children[targetIndex] = selected
          }
        } else {
          if let selected = await selectedCommentChild(commentID: commentID, postFullname: postFullname) {
            children.removeAll { $0.data?.name == selected.data?.name }
            children.insert(selected, at: 0)
          }
        }
        promoteHighlightedComment(targetFullname, in: &children, postFullname: postFullname)
        logCommentFetchDiagnostics(postID: postFullname, commentID: commentID, children: children)
        status = "commentByIdWithChildren \(commentID) → \(children.count) comment nodes"
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
      let children = adaptCommentTrees(trees, postFullname: postFullname)
      logCommentFetchDiagnostics(postID: postFullname, commentID: nil, children: children)
      if trees.isEmpty {
        AppDiagnostics.asyncRecord(
          .info,
          category: "ui.commentTree",
          message: "PostComments returned no comment tree",
          metadata: [
            "postID": postFullname,
            "phase": "empty-tree"
          ]
        )
        return (nil, children)
      }
      return (PostData(graphQL: post), children)
    } catch {
      status = "postComments failed: \(describe(error))"
      return (nil, [])
    }
  }

  /// Adapt GraphQL comment trees into winston's flat ListingChild list. Trees
  /// with a node become "t1" children; trees without one (continuations)
  /// become "more" stubs whose cursor is remembered for `moreReplies`.
  func adaptCommentTrees(_ trees: [CommentTree], postFullname: String) -> [ListingChild<CommentData>] {
    var children = trees.compactMap { tree -> ListingChild<CommentData>? in
      if let node = tree.node {
        guard let nodeID = node.id, !nodeID.isEmpty else {
          AppDiagnostics.asyncRecord(
            .warning,
            category: "reddit.comment",
            message: "Skipped invalid comment tree node",
            metadata: [
              "postID": postFullname,
              "parentID": tree.parentId ?? "nil",
              "depth": "\(tree.depth ?? -1)",
              "hasChildren": "\(tree.childCount ?? 0)"
            ]
          )
          return nil
        }
        let cd = CommentData(graphQL: node, depth: tree.depth, parentID: tree.parentId, postFullname: postFullname)
        return ListingChild<CommentData>(kind: "t1", data: cd)
      }
      guard tree.more != nil || (tree.childCount ?? 0) > 0 else { return nil }
      let parentID = tree.parentId ?? postFullname
      let stubID = "more-\(parentID)"
      var cd = CommentData(id: stubID)
      cd.name = stubID
      cd.parent_id = parentID
      cd.depth = tree.depth
      cd.count = tree.more?.count ?? tree.childCount ?? 0
      cd.children = []
      if let cursor = tree.more?.cursor, !cursor.isEmpty {
        moreCursorByStubID[stubID] = cursor
      }
      return ListingChild<CommentData>(kind: "more", data: cd)
    }
    repairOrphanCommentRoots(in: &children, postFullname: postFullname)
    return children
  }

  private func repairOrphanCommentRoots(in children: inout [ListingChild<CommentData>], postFullname: String) {
    let knownCommentIDs = Set(children.compactMap { $0.kind == "t1" ? $0.data?.name : nil })
    var repairedIDs: [String] = []

    for index in children.indices {
      guard
        children[index].kind == "t1",
        var data = children[index].data,
        let name = data.name,
        data.parent_id != postFullname
      else { continue }

      let parentID = data.parent_id ?? ""
      guard parentID.isEmpty || !knownCommentIDs.contains(parentID) else { continue }

      data.parent_id = postFullname
      data.depth = 0
      children[index].data = data
      repairedIDs.append(name)
    }

    if !repairedIDs.isEmpty {
      AppDiagnostics.asyncRecord(
        .warning,
        category: "reddit.comment",
        message: "Repaired orphan comment roots",
        metadata: [
          "postID": postFullname,
          "count": "\(repairedIDs.count)",
          "commentIDs": repairedIDs.prefix(8).joined(separator: ",")
        ]
      )
    }
  }

  private func selectedCommentChild(commentID: String, postFullname: String) async -> ListingChild<CommentData>? {
    do {
      let targetFullname = commentID.hasPrefix("t1_") ? commentID : "t1_\(commentID)"
      let resp = try await client.getCommentByIdResponse(commentID)
      guard
        let raw = resp.data?.rawData,
        let comment = raw.savedComments().first(where: { $0.id == targetFullname })
      else {
        AppDiagnostics.asyncRecord(
          .warning,
          category: "reddit.comment",
          message: "selected comment fallback returned no target comment",
          metadata: [
            "commentID": commentID,
            "postID": postFullname
          ]
        )
        return nil
      }
      let data = CommentData(graphQL: comment, depth: 0, parentID: postFullname, postFullname: postFullname)
      if isMissingCommentBody(data) {
        AppDiagnostics.asyncRecord(
          .warning,
          category: "reddit.comment",
          message: "selected comment fallback has empty body",
          metadata: [
            "commentID": data.name ?? commentID,
            "postID": postFullname,
            "author": data.author ?? "nil"
          ]
        )
      }
      return ListingChild<CommentData>(kind: "t1", data: data)
    } catch {
      AppDiagnostics.asyncRecord(
        .warning,
        category: "reddit.comment",
        message: "selected comment fallback failed",
        metadata: [
          "commentID": commentID,
          "error": describe(error)
        ]
      )
      return nil
    }
  }

  private func promoteHighlightedComment(_ targetFullname: String, in children: inout [ListingChild<CommentData>], postFullname: String) {
    guard let targetIndex = children.firstIndex(where: { $0.data?.name == targetFullname }) else {
      AppDiagnostics.asyncRecord(
        .warning,
        category: "reddit.comment",
        message: "Highlighted comment missing after fallback",
        metadata: [
          "commentID": targetFullname,
          "postID": postFullname,
          "children": "\(children.count)"
        ]
      )
      return
    }

    var target = children.remove(at: targetIndex)
    if var data = target.data {
      data.parent_id = postFullname
      data.depth = 0
      target.data = data
    }
    children.insert(target, at: 0)

    AppDiagnostics.asyncRecord(
      .info,
      category: "reddit.comment",
      message: "Promoted highlighted comment to post root",
      metadata: [
        "commentID": targetFullname,
        "postID": postFullname,
        "children": "\(children.count)"
      ]
    )
  }

  private func logCommentFetchDiagnostics(postID: String, commentID: String?, children: [ListingChild<CommentData>]) {
    let commentChildren = children.filter { $0.kind == "t1" }
    let missingBodies = commentChildren.compactMap { child -> String? in
      guard isMissingCommentBody(child.data) else { return nil }
      return child.data?.name ?? child.data?.id
    }
    let targetFullname = commentID.map { $0.hasPrefix("t1_") ? $0 : "t1_\($0)" }
    let target = targetFullname.flatMap { targetFullname in commentChildren.first { $0.data?.name == targetFullname } }
    AppDiagnostics.asyncRecord(
      missingBodies.isEmpty ? .info : .warning,
      category: "ui.comments",
      message: missingBodies.isEmpty ? "Comment fetch ready" : "Comment fetch contains empty bodies",
      metadata: [
        "postID": postID,
        "commentID": commentID ?? "nil",
        "total": "\(children.count)",
        "commentNodes": "\(commentChildren.count)",
        "moreNodes": "\(children.filter { $0.kind == "more" }.count)",
        "missingBodyCount": "\(missingBodies.count)",
        "missingBodyIDs": missingBodies.prefix(8).joined(separator: ","),
        "targetFound": "\(target != nil)",
        "targetMissingBody": "\(target.map { isMissingCommentBody($0.data) } ?? false)"
      ]
    )
  }

  private func isMissingCommentBody(_ data: CommentData?) -> Bool {
    data?.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
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
  func accountProfile() async -> UserData? {
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
      let missingBodies = comments.compactMap { comment -> String? in
        guard isMissingCommentBody(comment) else { return nil }
        return comment.name ?? comment.id
      }
      AppDiagnostics.asyncRecord(
        missingBodies.isEmpty ? .info : .warning,
        category: "reddit.profile",
        message: "Submitted comments loaded",
        metadata: [
          "username": username,
          "requestedAfter": after ?? "nil",
          "comments": "\(comments.count)",
          "missingBodyCount": "\(missingBodies.count)",
          "missingBodyIDs": missingBodies.prefix(8).joined(separator: ","),
          "nextCursor": resp.data?.pageInfo?.endCursor ?? "nil"
        ]
      )
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
    let posts = await searchPosts(trimmed, contentWidth: contentWidth, pageLimit: 2)
    let subs = await searchSubreddits(trimmed, pageLimit: 2).map(Subreddit.init(data:))
    let users = await searchUsers(trimmed, pageLimit: 2).map(User.init(data:))
    status = "search all '\(trimmed)' → \(posts.count) posts, \(subs.count) subs, \(users.count) users"
    return RedditSearchResults(posts: posts, subreddits: subs, users: users)
  }

  func searchPosts(_ query: String, contentWidth: CGFloat = .screenW, pageLimit: Int = 4) async -> [Post] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    do {
      var after: String?
      var postDatas: [PostData] = []
      for _ in 0..<pageLimit {
        let resp = try await client.dynamicSearchResponse(trimmed, pane: .posts, after: after)
        postDatas.append(contentsOf: (resp.data?.posts ?? []).map { PostData(graphQL: $0) })
        guard
          resp.data?.pageInfo?.hasNextPage == true,
          let next = resp.data?.pageInfo?.endCursor,
          !next.isEmpty,
          next != after
        else { break }
        after = next
      }
      postDatas = postDatas.deduped { $0.id }
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
  func searchSubreddits(_ query: String, pageLimit: Int = 4) async -> [SubredditData] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    var subs: [SubredditData] = []
    if isLikelyRedditIdentifier(trimmed), let exact = await subredditData(name: trimmed) {
      subs.append(exact)
    }
    subs.append(contentsOf: await searchRawPages(trimmed, pane: .communities, pageLimit: pageLimit, disableSpellCorrection: isLikelyRedditIdentifier(trimmed)).flatMap {
      $0.searchSubredditObjects.compactMap(SubredditData.init(graphQLSearchObject:))
    })
    subs = subs.deduped { ($0.display_name ?? $0.id).lowercased() }
    status = "search subreddits '\(query)' → \(subs.count)"
    return subs
  }

  func searchUsers(_ query: String, pageLimit: Int = 4) async -> [UserData] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    var users: [UserData] = []
    if isLikelyRedditIdentifier(trimmed), let exact = await userProfile(trimmed) {
      users.append(exact)
    }
    users.append(contentsOf: await searchRawPages(trimmed, pane: .people, pageLimit: pageLimit, disableSpellCorrection: isLikelyRedditIdentifier(trimmed)).flatMap {
      $0.searchUserObjects.compactMap(UserData.init(graphQLSearchObject:))
    })
    users = users.deduped { $0.name.lowercased() }
    status = "search users '\(query)' → \(users.count)"
    return users
  }

  private func searchRawPages(_ query: String, pane: RedditSearchPane? = nil, pageLimit: Int, disableSpellCorrection: Bool = false) async -> [JSONValue] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    do {
      var after: String?
      var pages: [JSONValue] = []
      for _ in 0..<pageLimit {
        let resp = try await client.dynamicSearchResponse(trimmed, pane: pane, after: after, disableSpellCorrection: disableSpellCorrection)
        guard let data = resp.data else { break }
        pages.append(data.rawData)
        guard
          data.pageInfo?.hasNextPage == true,
          let next = data.pageInfo?.endCursor,
          !next.isEmpty,
          next != after
        else { break }
        after = next
      }
      return pages
    } catch {
      status = "search failed: \(describe(error))"
      return []
    }
  }

  private func isLikelyRedditIdentifier(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
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
      return nil
    }
  }

  // MARK: - Mutations

  /// Vote on a post (`t3_`) or comment (`t1_`). Maps winston's VoteAction to the
  /// library's VoteState and dispatches on the fullname prefix.
  func vote(fullname: String, action: VoteAction) async -> Bool {
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
