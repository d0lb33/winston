//
//  AuroraFeed.swift
//  winston
//
//  Aurora — the middle (content) column. A selection-driven List of real posts,
//  paginated through AuroraFeedModel (→ Subreddit.fetchPosts). In compact width the
//  NavigationSplitView collapses to a stack and selecting a card pushes the detail;
//  in regular width the same selection populates the third (detail) pane.
//

import SwiftUI
import Defaults

@MainActor
private final class AuroraReadOnScrollTracker {
  private var previousScrollOffsetY: CGFloat?
  private var latestMaxYByID: [String: CGFloat] = [:]
  private var previousMaxYByID: [String: CGFloat] = [:]
  private var isScrollingDown = false

  func updateMaxY(_ maxY: CGFloat, for postID: String) {
    latestMaxYByID[postID] = maxY
  }

  func remove(postID: String) {
    latestMaxYByID.removeValue(forKey: postID)
    previousMaxYByID.removeValue(forKey: postID)
  }

  func markIfDisappearedPastTop(_ post: Post, readOnScroll: Bool) {
    guard readOnScroll, isScrollingDown, FeedScrollWorkCoordinator.shared.isScrolling else { return }
    FeedScrollWorkCoordinator.shared.markSeenWhenIdle(post)
  }

  func markCrossedPostsIfNeeded(offsetY: CGFloat, visiblePosts: [Post], readOnScroll: Bool) {
    let scrollingDown = previousScrollOffsetY.map { offsetY > $0 } ?? false
    isScrollingDown = scrollingDown
    defer {
      previousScrollOffsetY = offsetY
      previousMaxYByID = latestMaxYByID
    }

    guard readOnScroll, scrollingDown else { return }

    let crossedIDs: Set<String> = Set(latestMaxYByID.compactMap { id, maxY in
      guard let previousMaxY = previousMaxYByID[id] else { return nil }
      return previousMaxY > 0 && maxY <= 0 ? id : nil
    })
    guard !crossedIDs.isEmpty else { return }

    visiblePosts
      .filter { crossedIDs.contains($0.id) }
      .forEach { FeedScrollWorkCoordinator.shared.markSeenWhenIdle($0) }
  }
}

struct AuroraFeed: View {
  private static let topID = "aurora-feed-top"

  let model: AuroraFeedModel
  let title: String
  /// The real community backing this feed (for the header + join). nil for Popular/Home/All.
  let community: Subreddit?
  @Binding private var selectedPostID: String?
  @Binding private var sort: SubListingSortOption
  let tabInteractionTab: Nav.TabIdentifier?
  let tabInteractions: TabInteractionCenter?
  let tabInteractionRequest: TabInteractionRequest?
  var onCompactNavigate: ((NavDest) -> Void)? = nil
  @Environment(\.contentWidth) private var contentWidth
  @Environment(\.horizontalSizeClass) private var hSize
  @Default(.PostLinkDefSettings) private var postLinkDefSettings

  @State private var readOnScrollTracker = AuroraReadOnScrollTracker()

  init(
    model: AuroraFeedModel,
    title: String,
    community: Subreddit?,
    selectedPostID: Binding<String?>,
    sort: Binding<SubListingSortOption>,
    tabInteractionTab: Nav.TabIdentifier? = nil,
    tabInteractions: TabInteractionCenter? = nil,
    tabInteractionRequest: TabInteractionRequest? = nil,
    onCompactNavigate: ((NavDest) -> Void)? = nil
  ) {
    self.model = model
    self.title = title
    self.community = community
    self._selectedPostID = selectedPostID
    self._sort = sort
    self.tabInteractionTab = tabInteractionTab
    self.tabInteractions = tabInteractions
    self.tabInteractionRequest = tabInteractionRequest
    self.onCompactNavigate = onCompactNavigate
  }

  var body: some View {
    let visiblePosts = model.visiblePosts
    // Decode the Codable PostLink settings ONCE per body eval (not per scroll frame in
    // onOffsetChange, nor per card in the ForEach background / card body). The plain
    // value is threaded into each row via `settings:` → `.environment(\.auroraCardSettings)`.
    let cardSettings = AuroraCardSettings(postLinkDefSettings)

    GeometryReader { geometry in
      let rowWidth = max(1, geometry.size.width)

      TabScrollRoot(
        topID: Self.topID,
        tab: tabInteractionTab,
        tabInteractions: tabInteractions,
        request: tabInteractionRequest,
        selection: $selectedPostID,
        onOffsetChange: { offsetY in
          readOnScrollTracker.markCrossedPostsIfNeeded(offsetY: offsetY, visiblePosts: visiblePosts, readOnScroll: cardSettings.readOnScroll)
        }
      ) {
          if let community {
            AuroraCommunityHeader(sub: community)
              .listRowBackground(Color.clear)
              .listRowSeparator(.hidden)
              .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 2, trailing: 14))
          }
          ForEach(visiblePosts) { post in
            AuroraPostCardRow(post: post, availableRowWidth: rowWidth, isSelected: post.id == selectedPostID && hSize == .regular, onCompactNavigate: onCompactNavigate, settings: cardSettings)
              .tag(post.id)
              .background {
                if cardSettings.readOnScroll {
                  Color.clear
                    .onGeometryChange(for: CGFloat.self) { proxy in
                      proxy.frame(in: .named("auroraFeed")).maxY
                    } action: { maxY in
                      readOnScrollTracker.updateMaxY(maxY, for: post.id)
                    }
                }
              }
              .listRowBackground(Color.clear)
              .listRowSeparator(.hidden)
              .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
              .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { Task { _ = await post.vote(.up) } } label: { Label("Upvote", systemImage: "arrow.up") }
                  .tint(.orange)
                Button { Task { _ = await post.vote(.down) } } label: { Label("Downvote", systemImage: "arrow.down") }
                  .tint(.indigo)
              }
              .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button { SaveChooserInstance.shared.enable(.post(post)) } label: {
                  Label(post.data?.saved == true ? "Unsave" : "Save", systemImage: "bookmark")
                }
                .tint(.green)
              }
              .onAppear {
                if post.id == visiblePosts.last?.id {
                  Task { @MainActor in
                    await model.loadMore(sort: sort, contentWidth: contentWidth)
                  }
                }
              }
              .onDisappear {
                readOnScrollTracker.markIfDisappearedPastTop(post, readOnScroll: cardSettings.readOnScroll)
                readOnScrollTracker.remove(postID: post.id)
              }
          }
          // Isolated so a pagination `loading` toggle re-renders ONLY this footer, not
          // the whole feed body (which reads model.visiblePosts and would otherwise
          // re-evaluate every ForEach row on each load — a per-page scroll hitch).
          AuroraFeedLoadingFooter(model: model)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .driveInlineVideoCoordinator(coordinateSpace: "auroraFeed", posts: visiblePosts)
      .refreshable { await model.reload(sort: sort, contentWidth: contentWidth) }
      .overlay { if visiblePosts.isEmpty { emptyState(hasLoadedPosts: !model.posts.isEmpty) } }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .overlay(alignment: .bottomTrailing) {
      FeedFloatingToolbar {
        Task { @MainActor in await model.hideReadPosts(sort: sort, contentWidth: contentWidth) }
      }
      .equatable()
      .padding(.trailing, 12)
      .padding(.bottom, 12)
    }
    .task(id: model.feedIdentity) { @MainActor in
      await model.loadInitialIfNeeded(sort: sort, contentWidth: contentWidth)
    }
    .onChange(of: sort) { _, newSort in
      Task { @MainActor in await model.reload(sort: newSort, contentWidth: contentWidth) }
    }
    .toolbar { sortToolbar }
  }

  @ViewBuilder private func emptyState(hasLoadedPosts: Bool) -> some View {
    if model.phase == .idle || model.loading {
      ProgressView()
    } else if model.failed {
      ContentUnavailableView {
        Label("Couldn't load posts", systemImage: "wifi.exclamationmark")
      } description: {
        Text("Pull to try again.")
      }
    } else if hasLoadedPosts {
      ContentUnavailableView("No unread posts", systemImage: "eye.slash")
    } else if model.phase == .empty {
      ContentUnavailableView("No posts", systemImage: "tray")
    } else {
      ProgressView()
    }
  }

  @ToolbarContentBuilder private var sortToolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      PostSortMenu(selection: $sort)
    }
  }
}

/// The bottom load-more spinner, split out so `AuroraFeedModel.loading` is observed here
/// instead of in `AuroraFeed.body`. A `loading` flip then re-renders only this tiny row,
/// not the feed's whole `ForEach` — which is what made each pagination load hitch.
private struct AuroraFeedLoadingFooter: View {
  let model: AuroraFeedModel

  var body: some View {
    if model.loading && !model.visiblePosts.isEmpty {
      HStack { Spacer(); ProgressView(); Spacer() }
        .padding(.vertical, 16)
    }
  }
}
