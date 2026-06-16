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

@Observable
@MainActor
final class AuroraFeedModel {
  private(set) var posts: [Post] = []
  private(set) var hiddenPostIDs: Set<String> = []
  private(set) var loading = false
  private(set) var reachedEnd = false
  private(set) var failed = false

  /// The community / special feed currently driving the column.
  private(set) var subreddit: Subreddit

  @ObservationIgnored private var loadedIDs: Set<String> = []
  @ObservationIgnored private var after: String?
  @ObservationIgnored private var inFlight = false
  @ObservationIgnored private var hidingReadPostsUntilUnread = false
  @ObservationIgnored private var retriedEmptyInitialPage = false
  @ObservationIgnored private var loadGeneration = 0

  init(subreddit: Subreddit) {
    self.subreddit = subreddit
  }

  var feedIdentity: String {
    if feedsAndSuch.contains(subreddit.id) {
      return subreddit.id
    }
    return subreddit.feedName.lowercased()
  }

  var visiblePosts: [Post] {
    posts.filter { !hiddenPostIDs.contains($0.id) && !($0.data?.winstonHidden ?? false) }
  }

  /// Point the column at a different feed and clear state so the next appearance
  /// reloads from the top. Synchronous so the view sees the reset immediately.
  func prepare(for sub: Subreddit) {
    guard feedIdentity(for: sub) != feedIdentity else { return }
    resetHiddenPosts()
    subreddit = sub
    posts = []
    hiddenPostIDs.removeAll(keepingCapacity: true)
    loadedIDs.removeAll(keepingCapacity: true)
    after = nil
    inFlight = false
    loading = false
    loadGeneration += 1
    reachedEnd = false
    failed = false
    hidingReadPostsUntilUnread = false
    retriedEmptyInitialPage = false
  }

  func prepareForAccountSwitch(defaultSubreddit: Subreddit) {
    resetHiddenPosts()
    subreddit = defaultSubreddit
    posts = []
    hiddenPostIDs.removeAll(keepingCapacity: true)
    loadedIDs.removeAll(keepingCapacity: true)
    after = nil
    inFlight = false
    loading = false
    loadGeneration += 1
    reachedEnd = false
    failed = false
    hidingReadPostsUntilUnread = false
    retriedEmptyInitialPage = false
  }

  func loadInitialIfNeeded(sort: SubListingSortOption, contentWidth: CGFloat) async {
    guard posts.isEmpty, !inFlight else { return }
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
    guard !hiddenPostIDs.isEmpty || posts.contains(where: { $0.data?.winstonHidden == true }) else { return }
    posts.forEach { $0.data?.winstonHidden = false }
    hiddenPostIDs.removeAll(keepingCapacity: true)
  }

  @discardableResult
  private func hideVisibleReadPosts() -> Int {
    let readPosts = visiblePosts.filter { $0.data?.winstonSeen == true }
    guard !readPosts.isEmpty else { return 0 }

    withAnimation {
      readPosts.forEach { post in
        post.data?.winstonHidden = true
        hiddenPostIDs.insert(post.id)
      }
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
    inFlight = true
    loading = true
    failed = false
    defer {
      if generation == loadGeneration {
        inFlight = false
        loading = false
      }
    }

    let cursor = more ? after : nil
    let requestIdentity = feedIdentity
    AppDiagnostics.asyncBreadcrumb("Aurora feed fetch started", metadata: [
      "sub": subreddit.id, "more": "\(more)", "sort": sort.rawVal.value,
      "width": "\(Int(contentWidth))", "after": cursor ?? "nil"
    ])
    // The Saved feed is a separate Reddit surface (no sort), so it has its own fetch.
    let response: ([Post]?, String?)?
    if subreddit.id == "saved" {
      response = await subreddit.fetchSavedPosts(after: cursor, contentWidth: max(1, contentWidth))
    } else {
      response = await subreddit.fetchPosts(sort: sort, after: cursor, contentWidth: max(1, contentWidth))
    }
    guard !Task.isCancelled, requestIdentity == feedIdentity else { return 0 }

    guard let result = response, let newPosts = result.0 else {
      guard generation == loadGeneration else { return 0 }
      failed = posts.isEmpty
      AppDiagnostics.asyncRecord(.error, category: "ui.aurora.feed",
        message: "Aurora feed fetch returned nil",
        metadata: ["sub": subreddit.id, "more": "\(more)", "sort": sort.rawVal.value])
      return 0
    }
    guard generation == loadGeneration else { return 0 }

    // Author avatars are fetched lazily in the background, exactly like the legacy feed.
    let avatarSize = AuroraPostPresentation.avatarSize
    RedditWire.shared.applyAvatars(toPosts: newPosts, avatarSize: avatarSize)

    if shouldRetryEmptyInitialPage(more: more, received: newPosts.count, nextAfter: result.1) {
      retriedEmptyInitialPage = true
      AppDiagnostics.asyncRecord(
        .warning,
        category: "ui.aurora.feed",
        message: "Aurora feed initial page was empty; retrying once",
        metadata: ["sub": subreddit.id, "sort": sort.rawVal.value]
      )
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled, requestIdentity == feedIdentity else { return 0 }
      inFlight = false
      loading = false
      return await load(more: false, sort: sort, contentWidth: contentWidth)
    }

    let fresh = more ? newPosts.filter { !loadedIDs.contains($0.id) } : newPosts.deduped { $0.id }
    withAnimation {
      if more {
        posts.append(contentsOf: fresh)
      } else {
        loadedIDs.removeAll(keepingCapacity: true)
        hiddenPostIDs.removeAll(keepingCapacity: true)
        posts = fresh
      }
    }
    fresh.forEach { loadedIDs.insert($0.id) }
    after = result.1
    reachedEnd = result.1 == nil
    AppDiagnostics.asyncRecord(newPosts.isEmpty ? .warning : .info, category: "ui.aurora.feed",
      message: "Aurora feed fetch applied",
      metadata: [
        "sub": subreddit.id, "received": "\(newPosts.count)", "applied": "\(fresh.count)",
        "total": "\(posts.count)", "after": result.1 ?? "nil"
      ])
    return fresh.count
  }

  private func shouldRetryEmptyInitialPage(more: Bool, received: Int, nextAfter: String?) -> Bool {
    !more && posts.isEmpty && received == 0 && nextAfter == nil && !retriedEmptyInitialPage
  }

  private func feedIdentity(for sub: Subreddit) -> String {
    if feedsAndSuch.contains(sub.id) {
      return sub.id
    }
    return sub.feedName.lowercased()
  }
}
