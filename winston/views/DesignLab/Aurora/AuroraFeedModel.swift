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
  /// How many times the INITIAL page came back empty and we auto-retried. A transient empty
  /// (e.g. Home/subscriptions not hydrated yet, or a momentary empty response) is the classic
  /// "go Home → blank until I pull-to-refresh" cause; we retry a few times with backoff before
  /// settling into `.empty`, instead of latching blank after a single attempt.
  @ObservationIgnored private var emptyInitialRetries = 0
  @ObservationIgnored private static let maxEmptyInitialRetries = 2
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
    ScrollPerfDiagnostics.bump("auroraFeedModel.resetFeedState")
    posts = []
    hiddenPostIDs.removeAll(keepingCapacity: true)
    refreshVisiblePosts()
    loadedIDs.removeAll(keepingCapacity: true)
    after = nil
    inFlight = false
    phase = .idle
    reachedEnd = false
    hidingReadPostsUntilUnread = false
    emptyInitialRetries = 0
  }

  func loadInitialIfNeeded(sort: SubListingSortOption, contentWidth: CGFloat) async {
    // Recover from ANY non-loaded state when there's no content and nothing in flight —
    // including `.empty`/`.failed`/`.cancelled`/`.idle`. (The old `phase != .empty` guard
    // latched the feed blank: an empty/cancelled first load could never auto-retry, so the
    // only recovery was a manual pull-to-refresh — the "go Home → blank until I refresh" bug.)
    // This is called once per view appearance (from `.task(id:)` + `.onAppear`) and is
    // in-flight-guarded, so it never loops.
    guard posts.isEmpty, !inFlight else {
      AppDiagnostics.asyncBreadcrumb("Aurora initial load skipped", metadata: [
        "feedIdentity": feedIdentity,
        "reason": !posts.isEmpty ? "hasContent" : "inFlight",
        "phase": "\(phase)",
        "posts": "\(posts.count)"
      ])
      return
    }
    AppDiagnostics.asyncBreadcrumb("Aurora initial load starting", metadata: [
      "feedIdentity": feedIdentity, "phase": "\(phase)", "emptyRetries": "\(emptyInitialRetries)"
    ])
    await load(more: false, sort: sort, contentWidth: contentWidth)
  }

  func reload(sort: SubListingSortOption, contentWidth: CGFloat) async {
    resetHiddenPosts()
    emptyInitialRetries = 0
    await load(more: false, sort: sort, contentWidth: contentWidth)
  }

  @discardableResult
  func loadMore(sort: SubListingSortOption, contentWidth: CGFloat) async -> Int {
    guard !reachedEnd, !inFlight, !posts.isEmpty else { return 0 }
    return await load(more: true, sort: sort, contentWidth: contentWidth)
  }

  func post(id: String) -> Post? { posts.first { $0.id == id } }

  func hideReadPosts(sort: SubListingSortOption, contentWidth: CGFloat) async {
    hidingReadPostsUntilUnread = true
    await continueHidingReadPostsUntilUnread(sort: sort, contentWidth: contentWidth)
  }

  private func resetHiddenPosts() {
    guard !hiddenPostIDs.isEmpty else { return }
    ScrollPerfDiagnostics.bump("auroraFeedModel.resetHiddenPosts")
    hiddenPostIDs.removeAll(keepingCapacity: true)
    refreshVisiblePosts()
  }

  @discardableResult
  private func hideVisibleReadPosts() -> Int {
    let start = ScrollPerfDiagnostics.now()
    let readPosts = visiblePosts.filter { $0.data?.winstonSeen == true }
    guard !readPosts.isEmpty else { return 0 }

    withAnimation {
      readPosts.forEach { post in
        hiddenPostIDs.insert(post.id)
      }
      refreshVisiblePosts()
    }

    ScrollPerfDiagnostics.recordDuration(
      category: "auroraFeedModel.hideVisibleReadPosts",
      message: "Hide read posts update was slow",
      elapsedNanos: ScrollPerfDiagnostics.now() - start,
      thresholdMs: 12,
      metadata: ["hidden": "\(readPosts.count)", "visible": "\(visiblePosts.count)"]
    )
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
    guard !inFlight else {
      AppDiagnostics.asyncBreadcrumb("Aurora feed load skipped (already in flight)", metadata: [
        "feedIdentity": feedIdentity, "more": "\(more)", "phase": "\(phase)"
      ])
      return 0
    }
    let start = ScrollPerfDiagnostics.now()
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
      } else {
        // A newer load (via prepare) superseded this one and owns `inFlight`; don't touch it.
        // `prepare`/`resetFeedState` already reset `inFlight`, so this can't latch — but log it
        // so a future stuck-spinner is traceable.
        AppDiagnostics.asyncBreadcrumb("Aurora feed load superseded mid-flight", metadata: [
          "requestIdentity": requestIdentity, "feedIdentity": feedIdentity,
          "loadGen": "\(generation)", "currentGen": "\(loadGeneration)"
        ])
      }
    }

    let cursor = more ? after : nil
    AppDiagnostics.asyncBreadcrumb("Aurora feed fetch started", metadata: [
      "sub": subreddit.id, "feedIdentity": requestIdentity, "more": "\(more)", "sort": sort.rawVal.value,
      "width": "\(Int(contentWidth))", "after": cursor ?? "nil"
    ])
    let result = await pageLoader(subreddit, requestIdentity == "saved", cursor, sort, max(1, contentWidth))
    ScrollPerfDiagnostics.recordDuration(
      category: "auroraFeedModel.pageLoader",
      message: "Aurora feed page loader was slow",
      elapsedNanos: ScrollPerfDiagnostics.now() - start,
      thresholdMs: 250,
      metadata: ["sub": subreddit.id, "feedIdentity": requestIdentity, "more": "\(more)", "sort": sort.rawVal.value]
    )

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
    let start = ScrollPerfDiagnostics.now()
    // Author avatars are fetched lazily in the background, exactly like the legacy feed.
    let avatarSize = AuroraPostPresentation.avatarSize
    ScrollPerfDiagnostics.measure("auroraFeedModel.applyAvatars", slowThresholdMs: 8, slowMessage: "Aurora feed avatar application was slow", metadata: ["posts": "\(newPosts.count)"]) {
      RedditWire.shared.applyAvatars(toPosts: newPosts, avatarSize: avatarSize)
    }

    if shouldRetryEmptyInitialPage(more: more, received: newPosts.count, nextAfter: nextAfter) {
      emptyInitialRetries += 1
      // Exponential backoff: 300ms, 600ms, … — covers a feed that's empty for a moment while
      // subscriptions/auth hydrate, without hammering the API.
      let delayNanos = UInt64(300_000_000) << (emptyInitialRetries - 1)
      AppDiagnostics.asyncRecord(
        .warning,
        category: "ui.aurora.feed",
        message: "Aurora feed initial page empty; retrying",
        metadata: [
          "sub": subreddit.id, "feedIdentity": requestIdentity, "sort": sort.rawVal.value,
          "attempt": "\(emptyInitialRetries)/\(Self.maxEmptyInitialRetries)",
          "delayMs": "\(delayNanos / 1_000_000)"
        ]
      )
      try? await Task.sleep(nanoseconds: delayNanos)
      guard !Task.isCancelled, requestIdentity == feedIdentity else { return 0 }
      inFlight = false
      return await load(more: false, sort: sort, contentWidth: contentWidth)
    }

    // Not retrying. If the INITIAL page is genuinely empty, log that we've settled — a future
    // "blank Home" report is then immediately distinguishable (settled-empty vs. stuck/cancelled).
    if !more && newPosts.isEmpty {
      AppDiagnostics.asyncRecord(
        .warning,
        category: "ui.aurora.feed",
        message: "Aurora feed settled empty",
        metadata: [
          "sub": subreddit.id, "feedIdentity": requestIdentity, "sort": sort.rawVal.value,
          "emptyRetries": "\(emptyInitialRetries)"
        ]
      )
    }

    let fresh = ScrollPerfDiagnostics.measure("auroraFeedModel.dedupe", slowThresholdMs: 4, slowMessage: "Aurora feed dedupe was slow", metadata: ["received": "\(newPosts.count)", "loaded": "\(loadedIDs.count)"]) {
      more ? newPosts.filter { !loadedIDs.contains($0.id) } : newPosts.deduped { $0.id }
    }

    var transaction = Transaction()
    transaction.disablesAnimations = true
    ScrollPerfDiagnostics.measure("auroraFeedModel.applyTransaction", slowThresholdMs: 10, slowMessage: "Aurora feed apply transaction was slow", metadata: ["fresh": "\(fresh.count)", "more": "\(more)"]) {
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
    ScrollPerfDiagnostics.recordDuration(
      category: "auroraFeedModel.applyPage",
      message: "Aurora feed page application was slow",
      elapsedNanos: ScrollPerfDiagnostics.now() - start,
      thresholdMs: 20,
      metadata: [
        "sub": subreddit.id,
        "feedIdentity": requestIdentity,
        "received": "\(newPosts.count)",
        "applied": "\(fresh.count)",
        "total": "\(posts.count)",
        "more": "\(more)"
      ]
    )
    return fresh.count
  }

  private func shouldRetryEmptyInitialPage(more: Bool, received: Int, nextAfter: String?) -> Bool {
    !more && posts.isEmpty && received == 0 && nextAfter == nil && emptyInitialRetries < Self.maxEmptyInitialRetries
  }

  private func refreshVisiblePosts() {
    visiblePosts = ScrollPerfDiagnostics.measure("auroraFeedModel.refreshVisiblePosts", slowThresholdMs: 4, slowMessage: "Aurora visible-post filter was slow", metadata: ["posts": "\(posts.count)", "hidden": "\(hiddenPostIDs.count)"]) {
      posts.filter { !hiddenPostIDs.contains($0.id) }
    }
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
