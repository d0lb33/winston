//
//  AuroraFeedModel.swift
//  winston
//
//  Drives an Aurora feed column from the production GraphQL feed pipeline
//  (Subreddit.fetchPosts → RedditWire.feedPosts → Post entities). Owns the post
//  array, the pagination cursor and the in-flight guard. The cursor/dedup logic
//  mirrors the legacy SubredditPosts.asyncFetch, trimmed to the essentials (no
//  hide-read, no saved branch, no flair filtering, no per-style recompute).
//

import SwiftUI
import Defaults

enum AuroraFeedLoadPhase: Equatable {
  case idle
  case loading
  case loaded
  case empty
  case failed
}

enum AuroraFeedPageResult {
  case success(posts: [Post], after: String?)
  case cancelled
  case failed
}

@Observable
@MainActor
final class AuroraFeedModel {
  typealias PageLoader = @MainActor (_ subreddit: Subreddit, _ savedFeed: Bool, _ cursor: String?, _ sort: SubListingSortOption, _ contentWidth: CGFloat) async -> AuroraFeedPageResult

  private(set) var posts: [Post] = []
  private(set) var visiblePosts: [Post] = []
  private(set) var phase: AuroraFeedLoadPhase = .idle
  private(set) var reachedEnd = false
  private(set) var feedIdentity: String

  /// The community / special feed currently driving the column.
  private(set) var subreddit: Subreddit

  @ObservationIgnored private var loadedIDs: Set<String> = []
  @ObservationIgnored private var after: String?
  @ObservationIgnored private var inFlight = false
  @ObservationIgnored private var hidingReadPostsUntilUnread = false
  @ObservationIgnored private var retriedEmptyInitialPage = false
  @ObservationIgnored private var loadGeneration = 0
  @ObservationIgnored private var hiddenPostIDs: Set<String> = []
  @ObservationIgnored private let pageLoader: PageLoader

  init(subreddit: Subreddit, pageLoader: @escaping PageLoader = AuroraFeedModel.defaultPageLoader) {
    self.subreddit = subreddit
    self.feedIdentity = Self.stableFeedIdentity(for: subreddit)
    self.pageLoader = pageLoader
  }

  var loading: Bool { phase == .loading }
  var failed: Bool { phase == .failed }

  /// Point the column at a different feed and clear state so the next appearance
  /// reloads from the top. Synchronous so the view sees the reset immediately.
  func prepare(for sub: Subreddit) {
    let nextIdentity = Self.stableFeedIdentity(for: sub)
    guard nextIdentity != feedIdentity else { return }
    resetHiddenPosts()
    subreddit = sub
    feedIdentity = nextIdentity
    loadGeneration += 1
    resetFeedState()
  }

  func prepareForAccountSwitch(defaultSubreddit: Subreddit) {
    resetHiddenPosts()
    subreddit = defaultSubreddit
    feedIdentity = Self.stableFeedIdentity(for: defaultSubreddit)
    loadGeneration += 1
    resetFeedState()
  }

  private func resetFeedState() {
    posts = []
    hiddenPostIDs.removeAll(keepingCapacity: true)
    refreshVisiblePosts()
    loadedIDs.removeAll(keepingCapacity: true)
    after = nil
    inFlight = false
    phase = .idle
    reachedEnd = false
    hidingReadPostsUntilUnread = false
    retriedEmptyInitialPage = false
  }

  func loadInitialIfNeeded(sort: SubListingSortOption, contentWidth: CGFloat) async {
    guard posts.isEmpty, !inFlight, phase != .empty else { return }
    await load(more: false, sort: sort, contentWidth: contentWidth)
  }

  func reload(sort: SubListingSortOption, contentWidth: CGFloat) async {
    resetHiddenPosts()
    retriedEmptyInitialPage = false
    await load(more: false, sort: sort, contentWidth: contentWidth)
  }

  func loadMore(sort: SubListingSortOption, contentWidth: CGFloat) async {
    guard !reachedEnd, !inFlight, !posts.isEmpty else { return }
    await load(more: true, sort: sort, contentWidth: contentWidth)
  }

  func post(id: String) -> Post? { posts.first { $0.id == id } }

  func hideReadPosts(sort: SubListingSortOption, contentWidth: CGFloat) async {
    hidingReadPostsUntilUnread = true
    await continueHidingReadPostsUntilUnread(sort: sort, contentWidth: contentWidth)
  }

  private func resetHiddenPosts() {
    guard !hiddenPostIDs.isEmpty else { return }
    hiddenPostIDs.removeAll(keepingCapacity: true)
    refreshVisiblePosts()
  }

  @discardableResult
  private func hideVisibleReadPosts() -> Int {
    let readPosts = visiblePosts.filter { $0.data?.winstonSeen == true }
    guard !readPosts.isEmpty else { return 0 }

    withAnimation {
      readPosts.forEach { post in
        hiddenPostIDs.insert(post.id)
      }
      refreshVisiblePosts()
    }

    return readPosts.count
  }

  private func continueHidingReadPostsUntilUnread(sort: SubListingSortOption, contentWidth: CGFloat) async {
    guard hidingReadPostsUntilUnread else { return }

    _ = hideVisibleReadPosts()
    let remainingVisiblePosts = visiblePosts

    if remainingVisiblePosts.contains(where: { !($0.data?.winstonSeen ?? false) }) || reachedEnd || after == nil {
      hidingReadPostsUntilUnread = false
      return
    }

    guard !inFlight else { return }

    let appliedCount = await load(more: true, sort: sort, contentWidth: contentWidth)
    guard appliedCount > 0 else {
      hidingReadPostsUntilUnread = false
      return
    }

    await continueHidingReadPostsUntilUnread(sort: sort, contentWidth: contentWidth)
  }

  @discardableResult
  private func load(more: Bool, sort: SubListingSortOption, contentWidth: CGFloat) async -> Int {
    guard !inFlight else { return 0 }
    let generation = loadGeneration
    let requestIdentity = feedIdentity
    inFlight = true
    phase = .loading
    defer {
      if generation == loadGeneration {
        inFlight = false
        if phase == .loading {
          phase = posts.isEmpty ? .idle : .loaded
        }
      }
    }

    let cursor = more ? after : nil
    AppDiagnostics.asyncBreadcrumb("Aurora feed fetch started", metadata: [
      "sub": subreddit.id, "feedIdentity": requestIdentity, "more": "\(more)", "sort": sort.rawVal.value,
      "width": "\(Int(contentWidth))", "after": cursor ?? "nil"
    ])
    let result = await pageLoader(subreddit, requestIdentity == "saved", cursor, sort, max(1, contentWidth))

    guard !Task.isCancelled else {
      AppDiagnostics.asyncRecord(.info, category: "ui.aurora.feed",
        message: "Aurora feed fetch cancelled",
        metadata: ["sub": subreddit.id, "feedIdentity": requestIdentity, "more": "\(more)", "sort": sort.rawVal.value])
      return 0
    }
    guard generation == loadGeneration, requestIdentity == feedIdentity else { return 0 }

    switch result {
    case .cancelled:
      AppDiagnostics.asyncRecord(.info, category: "ui.aurora.feed",
        message: "Aurora feed fetch cancelled",
        metadata: ["sub": subreddit.id, "feedIdentity": requestIdentity, "more": "\(more)", "sort": sort.rawVal.value])
      return 0
    case .failed:
      phase = posts.isEmpty ? .failed : .loaded
      AppDiagnostics.asyncRecord(.error, category: "ui.aurora.feed",
        message: "Aurora feed fetch failed",
        metadata: ["sub": subreddit.id, "feedIdentity": requestIdentity, "more": "\(more)", "sort": sort.rawVal.value])
      return 0
    case .success(let newPosts, let nextAfter):
      return await applyPage(
        newPosts: newPosts,
        nextAfter: nextAfter,
        more: more,
        sort: sort,
        contentWidth: contentWidth,
        requestIdentity: requestIdentity
      )
    }
  }

  @discardableResult
  private func applyPage(newPosts: [Post], nextAfter: String?, more: Bool, sort: SubListingSortOption, contentWidth: CGFloat, requestIdentity: String) async -> Int {
    // Author avatars are fetched lazily in the background, exactly like the legacy feed.
    let avatarSize = AuroraPostPresentation.avatarSize
    RedditWire.shared.applyAvatars(toPosts: newPosts, avatarSize: avatarSize)

    if shouldRetryEmptyInitialPage(more: more, received: newPosts.count, nextAfter: nextAfter) {
      retriedEmptyInitialPage = true
      AppDiagnostics.asyncRecord(
        .warning,
        category: "ui.aurora.feed",
        message: "Aurora feed initial page was empty; retrying once",
        metadata: ["sub": subreddit.id, "feedIdentity": requestIdentity, "sort": sort.rawVal.value]
      )
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled, requestIdentity == feedIdentity else { return 0 }
      inFlight = false
      return await load(more: false, sort: sort, contentWidth: contentWidth)
    }

    let fresh = more ? newPosts.filter { !loadedIDs.contains($0.id) } : newPosts.deduped { $0.id }

    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      if more {
        posts.append(contentsOf: fresh)
      } else {
        loadedIDs.removeAll(keepingCapacity: true)
        hiddenPostIDs.removeAll(keepingCapacity: true)
        posts = fresh
      }
      refreshVisiblePosts()
    }
    fresh.forEach { loadedIDs.insert($0.id) }
    after = nextAfter
    reachedEnd = nextAfter == nil
    phase = posts.isEmpty ? .empty : .loaded
    AppDiagnostics.asyncRecord(newPosts.isEmpty ? .warning : .info, category: "ui.aurora.feed",
      message: "Aurora feed fetch applied",
      metadata: [
        "sub": subreddit.id, "feedIdentity": requestIdentity, "received": "\(newPosts.count)", "applied": "\(fresh.count)",
        "total": "\(posts.count)", "after": nextAfter ?? "nil"
      ])
    return fresh.count
  }

  private func shouldRetryEmptyInitialPage(more: Bool, received: Int, nextAfter: String?) -> Bool {
    !more && posts.isEmpty && received == 0 && nextAfter == nil && !retriedEmptyInitialPage
  }

  private func refreshVisiblePosts() {
    visiblePosts = posts.filter { !hiddenPostIDs.contains($0.id) }
  }

  private static func defaultPageLoader(subreddit: Subreddit, savedFeed: Bool, cursor: String?, sort: SubListingSortOption, contentWidth: CGFloat) async -> AuroraFeedPageResult {
    // The Saved feed is a separate Reddit surface (no sort), so it has its own fetch.
    let response: ([Post]?, String?)?
    if savedFeed {
      response = await subreddit.fetchSavedPosts(after: cursor, contentWidth: contentWidth)
    } else {
      response = await subreddit.fetchPosts(sort: sort, after: cursor, contentWidth: contentWidth)
    }

    if Task.isCancelled {
      return .cancelled
    }
    guard let result = response, let posts = result.0 else {
      return .failed
    }
    return .success(posts: posts, after: result.1)
  }

  private static func stableFeedIdentity(for sub: Subreddit) -> String {
    if feedsAndSuch.contains(sub.id) {
      return sub.id
    }
    return normalizedFeedToken(sub.feedName)
  }

  private static func normalizedFeedToken(_ raw: String) -> String {
    var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if token.lowercased().hasPrefix("r/") {
      token.removeFirst(2)
    }
    return token.lowercased()
  }
}
