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

enum AuroraSort: String, CaseIterable {
  case hot, new, top
  var label: String { rawValue.capitalized }
  var symbol: String {
    switch self {
    case .hot: "flame.fill"
    case .new: "clock.fill"
    case .top: "arrow.up.circle.fill"
    }
  }
  var listing: SubListingSortOption {
    switch self {
    case .hot: .hot
    case .new: .new
    case .top: .top(.all)
    }
  }
}

struct AuroraFeed: View {
  let model: AuroraFeedModel
  let title: String
  /// The real community backing this feed (for the header + join). nil for Popular/Home/All.
  let community: Subreddit?
  @Binding var selectedPostID: String?
  @Binding var sort: AuroraSort
  @Environment(\.contentWidth) private var contentWidth
  @Environment(\.horizontalSizeClass) private var hSize

  var body: some View {
    List(selection: $selectedPostID) {
      if let community {
        AuroraCommunityHeader(sub: community)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
          .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 2, trailing: 14))
      }
      ForEach(model.posts) { post in
        AuroraCard(post: post, isSelected: post.id == selectedPostID && hSize == .regular)
          .tag(post.id)
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
            if post.id == model.posts.last?.id {
              Task { await model.loadMore(sort: sort.listing, contentWidth: contentWidth) }
            }
          }
      }
      if model.loading && !model.posts.isEmpty {
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
    .refreshable { await model.reload(sort: sort.listing, contentWidth: contentWidth) }
    .overlay { if model.posts.isEmpty { emptyState } }
    .task(id: model.subreddit.id) {
      await model.loadInitialIfNeeded(sort: sort.listing, contentWidth: contentWidth)
    }
    .onChange(of: sort) { _, newSort in
      Task { await model.reload(sort: newSort.listing, contentWidth: contentWidth) }
    }
    .safeAreaInset(edge: .bottom) {
      AuroraSortBar(sort: $sort)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
  }

  @ViewBuilder private var emptyState: some View {
    if model.loading {
      ProgressView()
    } else if model.failed {
      ContentUnavailableView {
        Label("Couldn't load posts", systemImage: "wifi.exclamationmark")
      } description: {
        Text("Pull to try again.")
      }
    } else {
      ContentUnavailableView("No posts", systemImage: "tray")
    }
  }
}

struct AuroraSortBar: View {
  @Binding var sort: AuroraSort
  @Environment(\.auroraTheme) private var theme

  var body: some View {
    HStack {
      Spacer()
      HStack(spacing: 4) {
        ForEach(AuroraSort.allCases, id: \.self) { s in
          Button {
            withAnimation(.snappy) { sort = s }
          } label: {
            Label(s.label, systemImage: s.symbol)
              .font(.caption.weight(.semibold))
              .padding(.horizontal, 13).padding(.vertical, 8)
              .foregroundStyle(sort == s ? (theme.isDark ? Color.black : Color.white) : Color.primary)
              .background { if sort == s { Capsule().fill(theme.accent) } }
          }
          .buttonStyle(.plain)
        }
      }
      .padding(5)
      .glassEffect(.regular.interactive(), in: .capsule)
      Spacer()
    }
  }
}
