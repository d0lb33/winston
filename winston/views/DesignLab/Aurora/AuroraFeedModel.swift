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
  private(set) var loading = false
  private(set) var reachedEnd = false
  private(set) var failed = false

  /// The community / special feed currently driving the column.
  private(set) var subreddit: Subreddit

  @ObservationIgnored private var loadedIDs: Set<String> = []
  @ObservationIgnored private var after: String?
  @ObservationIgnored private var inFlight = false

  init(subreddit: Subreddit) {
    self.subreddit = subreddit
  }

  /// Point the column at a different feed and clear state so the feed's `.task(id:)`
  /// reloads from the top. Synchronous so the view sees the reset immediately.
  func prepare(for sub: Subreddit) {
    guard sub.id != subreddit.id else { return }
    subreddit = sub
    posts = []
    loadedIDs.removeAll(keepingCapacity: true)
    after = nil
    reachedEnd = false
    failed = false
  }

  func loadInitialIfNeeded(sort: SubListingSortOption, contentWidth: CGFloat) async {
    print("AURORA_FEED loadInitialIfNeeded sub=\(subreddit.id) posts=\(posts.count) inFlight=\(inFlight)")
    guard posts.isEmpty, !inFlight else { return }
    await load(more: false, sort: sort, contentWidth: contentWidth)
  }

  func reload(sort: SubListingSortOption, contentWidth: CGFloat) async {
    await load(more: false, sort: sort, contentWidth: contentWidth)
  }

  func loadMore(sort: SubListingSortOption, contentWidth: CGFloat) async {
    guard !reachedEnd, !inFlight, !posts.isEmpty else { return }
    await load(more: true, sort: sort, contentWidth: contentWidth)
  }

  func post(id: String) -> Post? { posts.first { $0.id == id } }

  private func load(more: Bool, sort: SubListingSortOption, contentWidth: CGFloat) async {
    guard !inFlight else { return }
    inFlight = true
    loading = true
    failed = false
    defer { inFlight = false; loading = false }

    let cursor = more ? after : nil
    print("AURORA_FEED load sub=\(subreddit.id) more=\(more) sort=\(sort.rawVal.value) width=\(contentWidth)")
    AppDiagnostics.asyncBreadcrumb("Aurora feed fetch started", metadata: [
      "sub": subreddit.id, "more": "\(more)", "sort": sort.rawVal.value,
      "width": "\(Int(contentWidth))", "after": cursor ?? "nil"
    ])
    guard let result = await subreddit.fetchPosts(sort: sort, after: cursor, contentWidth: max(1, contentWidth)),
          let newPosts = result.0 else {
      print("AURORA_FEED fetchPosts returned NIL for sub=\(subreddit.id)")
      failed = posts.isEmpty
      AppDiagnostics.asyncRecord(.error, category: "ui.aurora.feed",
        message: "Aurora feed fetch returned nil",
        metadata: ["sub": subreddit.id, "more": "\(more)", "sort": sort.rawVal.value])
      return
    }
    print("AURORA_FEED got \(newPosts.count) posts for sub=\(subreddit.id) after=\(result.1 ?? "nil")")

    // Author avatars are fetched lazily in the background, exactly like the legacy feed.
    let avatarSize = getEnabledTheme().postLinks.theme.badge.avatar.size
    Task(priority: .background) {
      await RedditWire.shared.updatePostsWithAvatar(posts: newPosts, avatarSize: avatarSize)
    }

    let fresh = newPosts.filter { !loadedIDs.contains($0.id) }
    withAnimation {
      if more {
        posts.append(contentsOf: fresh)
      } else {
        loadedIDs.removeAll(keepingCapacity: true)
        posts = fresh
      }
    }
    fresh.forEach { loadedIDs.insert($0.id) }
    after = result.1
    reachedEnd = result.1 == nil
    print("AURORA_FEED posts now \(posts.count) for sub=\(subreddit.id)")
    AppDiagnostics.asyncRecord(newPosts.isEmpty ? .warning : .info, category: "ui.aurora.feed",
      message: "Aurora feed fetch applied",
      metadata: [
        "sub": subreddit.id, "received": "\(newPosts.count)", "applied": "\(fresh.count)",
        "total": "\(posts.count)", "after": result.1 ?? "nil"
      ])
  }
}
