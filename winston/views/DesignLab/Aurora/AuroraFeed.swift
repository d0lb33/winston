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

private struct AuroraReadCandidate: Equatable {
  let id: String
  let maxY: CGFloat
}

private struct AuroraReadCandidatePreferenceKey: PreferenceKey {
  static var defaultValue: [AuroraReadCandidate] = []

  static func reduce(value: inout [AuroraReadCandidate], nextValue: () -> [AuroraReadCandidate]) {
    value.append(contentsOf: nextValue())
  }
}

struct AuroraFeed: View {
  let model: AuroraFeedModel
  let title: String
  /// The real community backing this feed (for the header + join). nil for Popular/Home/All.
  let community: Subreddit?
  @Binding var selectedPostID: String?
  @Binding var sort: SubListingSortOption
  var onCompactNavigate: ((Router.NavDest) -> Void)? = nil
  @Environment(\.contentWidth) private var contentWidth
  @Environment(\.horizontalSizeClass) private var hSize
  @Default(.PostLinkDefSettings) private var postLinkDefSettings

  @State private var previousScrollOffsetY: CGFloat?
  @State private var latestReadCandidateMaxYByID: [String: CGFloat] = [:]
  @State private var previousReadCandidateMaxYByID: [String: CGFloat] = [:]

  var body: some View {
    let visiblePosts = model.visiblePosts

    List(selection: $selectedPostID) {
      if let community {
        AuroraCommunityHeader(sub: community)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
          .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 2, trailing: 14))
      }
      ForEach(visiblePosts) { post in
        AuroraCard(post: post, isSelected: post.id == selectedPostID && hSize == .regular, onCompactNavigate: onCompactNavigate)
          .tag(post.id)
          .background {
            if postLinkDefSettings.readOnScroll {
              GeometryReader { proxy in
                Color.clear.preference(
                  key: AuroraReadCandidatePreferenceKey.self,
                  value: [AuroraReadCandidate(id: post.id, maxY: proxy.frame(in: .named("auroraFeed")).maxY)]
                )
              }
            }
          }
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
          .listRowInsets(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14))
          .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { Task { _ = await post.vote(.up) } } label: { Label("Upvote", systemImage: "arrow.up") }
              .tint(.orange)
            Button { Task { _ = await post.vote(.down) } } label: { Label("Downvote", systemImage: "arrow.down") }
              .tint(.indigo)
          }
          .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { Task { _ = await post.saveToggle() } } label: {
              Label(post.data?.saved == true ? "Unsave" : "Save", systemImage: "bookmark")
            }
            .tint(.green)
          }
          .onAppear {
            if post.id == visiblePosts.last?.id {
              Task { await model.loadMore(sort: sort, contentWidth: contentWidth) }
            }
          }
      }
      if model.loading && !visiblePosts.isEmpty {
        HStack { Spacer(); ProgressView(); Spacer() }
          .padding(.vertical, 16)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .driveInlineVideoCoordinator(coordinateSpace: "auroraFeed")
    .onScrollGeometryChange(for: CGFloat.self) { geometry in
      geometry.contentOffset.y
    } action: { _, newOffsetY in
      markReadCandidatesIfNeeded(offsetY: newOffsetY, visiblePosts: visiblePosts)
    }
    .onPreferenceChange(AuroraReadCandidatePreferenceKey.self) { candidates in
      latestReadCandidateMaxYByID = Dictionary(candidates.map { ($0.id, $0.maxY) }, uniquingKeysWith: min)
    }
    .refreshable { await model.reload(sort: sort, contentWidth: contentWidth) }
    .overlay { if visiblePosts.isEmpty { emptyState(hasLoadedPosts: !model.posts.isEmpty) } }
    .overlay(alignment: .bottomTrailing) {
      FeedFloatingToolbar {
        Task { await model.hideReadPosts(sort: sort, contentWidth: contentWidth) }
      }
      .equatable()
      .padding(.trailing, 12)
      .padding(.bottom, 12)
    }
    .onAppear {
      Task { await model.loadInitialIfNeeded(sort: sort, contentWidth: contentWidth) }
    }
    .onChange(of: sort) { _, newSort in
      Task { await model.reload(sort: newSort, contentWidth: contentWidth) }
    }
    .toolbar { sortToolbar }
  }

  private func markReadCandidatesIfNeeded(offsetY: CGFloat, visiblePosts: [Post]) {
    defer {
      previousScrollOffsetY = offsetY
      previousReadCandidateMaxYByID = latestReadCandidateMaxYByID
    }

    guard postLinkDefSettings.readOnScroll, let previousScrollOffsetY, offsetY > previousScrollOffsetY else { return }

    let crossedIDs: Set<String> = Set(latestReadCandidateMaxYByID.compactMap { id, maxY in
      guard let previousMaxY = previousReadCandidateMaxYByID[id] else { return nil }
      return previousMaxY > 0 && maxY <= 0 ? id : nil
    })
    guard !crossedIDs.isEmpty else { return }

    visiblePosts
      .filter { crossedIDs.contains($0.id) }
      .forEach { FeedScrollWorkCoordinator.shared.markSeenWhenIdle($0) }
  }

  @ViewBuilder private func emptyState(hasLoadedPosts: Bool) -> some View {
    if model.loading {
      ProgressView()
    } else if model.failed {
      ContentUnavailableView {
        Label("Couldn't load posts", systemImage: "wifi.exclamationmark")
      } description: {
        Text("Pull to try again.")
      }
    } else if hasLoadedPosts {
      ContentUnavailableView("No unread posts", systemImage: "eye.slash")
    } else {
      ContentUnavailableView("No posts", systemImage: "tray")
    }
  }

  @ToolbarContentBuilder private var sortToolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      PostSortMenu(selection: $sort)
    }
  }
}
