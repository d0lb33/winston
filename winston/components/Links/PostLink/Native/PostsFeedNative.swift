//
//  PostsFeedNative.swift
//  winston
//
//  The native, ADAPTIVE posts feed. One code path for every form factor: a
//  ScrollView + LazyVGrid whose column count is derived from the AVAILABLE WIDTH
//  (not the device idiom), so it shows a single column on a phone / folded display
//  and reflows to 2–3 columns as the window / unfolded display grows. Replaces both
//  the iOS List and the iPad Waterfall while the "Native interface" toggle is on.
//
//  Adaptivity notes (iOS 27): no `IPAD` / `UIScreen.main` here — columns come from
//  the measured viewport width, rows self-size, and `scrollPosition(id:)` keeps the
//  top post in view across a resize / fold (index targets would shift when the
//  column count changes). A fold is just a scene resize, so all @State survives.
//

import SwiftUI
import Defaults

struct PostsFeedNative: View {
  var showSub = false
  var feedStyleKey: String?
  var lastPostAfter: String?
  weak var subreddit: Subreddit?
  var filters: [FilterData]
  var posts: [Post]
  var filter: String
  var filterCallback: ((String) -> ())
  var searchText: String
  var searchCallback: ((String?) -> ())
  var editCustomFilter: ((FilterData) -> ())
  var hideReadPosts: (() -> ())
  var fetch: (Bool, String?, Bool) -> ()
  var selectedTheme: WinstonTheme
  var loading: Bool

  @Binding var reachedEndOfFeed: Bool

  @Default(.PostLinkDefSettings) private var postLinkDefSettings
  @Default(.SubredditFeedDefSettings) private var feedDefSettings
  @Environment(\.contentWidth) private var contentWidth

  @State private var containerWidth: CGFloat = 0
  @State private var topVisibleID: String?

  private let gutter: CGFloat = 12
  private let maxContentWidth: CGFloat = 1300

  func loadMorePosts() {
    guard !loading, !reachedEndOfFeed, lastPostAfter != nil else { return }
    if !searchText.isEmpty { fetch(true, searchText, true) } else { fetch(true, nil, true) }
  }

  var body: some View {
    let styleKey = feedStyleKey ?? subreddit?.id ?? ""
    let isFiltered = filter != "flair:All"
    let isCompact = postLinkDefSettings.resolvedPostStyle(
      styleOverride: feedDefSettings.postStylePerSubreddit[styleKey],
      compactOverride: feedDefSettings.compactPerSubreddit[styleKey]
    ) == .compact
    let minColWidth: CGFloat = isCompact ? 320 : 400
    let effectiveWidth = min(containerWidth > 0 ? containerWidth : max(contentWidth, 1), maxContentWidth)
    let cols = max(1, Int((effectiveWidth + gutter) / (minColWidth + gutter)))
    let colWidth = (effectiveWidth - gutter * CGFloat(cols - 1)) / CGFloat(max(cols, 1))
    let cellContentWidth = max(1, colWidth - 32) // minus the row's horizontal padding
    let columns = Array(repeating: GridItem(.flexible(), spacing: gutter), count: cols)
    let isSingleColumn = cols == 1

    ScrollView {
      VStack(spacing: 0) {
        LazyVGrid(columns: columns, alignment: .leading, spacing: isSingleColumn ? 0 : gutter) {
          ForEach(posts, id: \.id) { post in
            cell(post, styleKey: styleKey, cellContentWidth: cellContentWidth, isSingleColumn: isSingleColumn, isFiltered: isFiltered)
          }
        }
        .scrollTargetLayout()

        footer(isFiltered: isFiltered)
      }
      .frame(maxWidth: maxContentWidth)
      .frame(maxWidth: .infinity)
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { newWidth in
      containerWidth = newWidth
    }
    .scrollPosition(id: $topVisibleID, anchor: .top)
    .scrollIndicators(.never)
    .driveInlineVideoCoordinator(coordinateSpace: "subredditFeed")
    .floatingMenu(subId: styleKey, filters: filters, selected: filter, filterCallback: filterCallback, searchText: searchText, searchCallback: searchCallback, customFilterCallback: editCustomFilter, hideReadPosts: hideReadPosts)
  }

  @ViewBuilder
  private func cell(_ post: Post, styleKey: String, cellContentWidth: CGFloat, isSingleColumn: Bool, isFiltered: Bool) -> some View {
    if let sub = subreddit ?? post.winstonData?.subreddit, let winstonData = post.winstonData {
      VStack(spacing: 0) {
        PostLink(
          id: post.id,
          theme: selectedTheme.postLinks,
          showSub: showSub,
          compactPerSubreddit: feedDefSettings.compactPerSubreddit[styleKey],
          postStyleOverride: feedDefSettings.postStylePerSubreddit[styleKey],
          contentWidth: cellContentWidth,
          defSettings: postLinkDefSettings,
          useNative: true
        )
        .equatable()
        .environmentObject(sub)
        .environmentObject(post)
        .environmentObject(winstonData)

        if isSingleColumn && selectedTheme.postLinks.divider.style != .no {
          Divider().opacity(0.4)
        }
      }
      // Inline-video center election (autoplay) only in single column. In a multi-column
      // grid, many video rows reporting their center per frame thrashes the layout
      // (InlineVideoCenterPreferenceKey "updated multiple times per frame") and leaves
      // players mounted-but-frameless (black boxes). Multi-column shows posters + tap-to-play.
      .trackInlineVideoCenter(key: post.id, coordinateSpace: "subredditFeed", enabled: isSingleColumn && winstonData.extractedMedia?.isInlineVideo == true)
      .task(priority: .background) {
        if post.id == posts.last?.id && !isFiltered { loadMorePosts() }
      }
    }
  }

  @ViewBuilder
  private func footer(isFiltered: Bool) -> some View {
    if isFiltered && posts.isEmpty {
      Text("No filtered posts")
        .frame(maxWidth: .infinity)
        .font(.system(size: 22, weight: .semibold))
        .opacity(0.5)
        .padding(.vertical, 24)
    }

    if loading {
      ProgressView()
        .progressViewStyle(.circular)
        .frame(maxWidth: .infinity, minHeight: posts.isEmpty && !isFiltered ? 400 : 100)
        .padding(.vertical, 16)
    }

    if isFiltered && !loading && !reachedEndOfFeed {
      Button {
        loadMorePosts()
      } label: {
        Label("LOAD MORE", systemImage: "arrow.clockwise.circle.fill")
          .frame(maxWidth: .infinity)
          .font(.system(size: 16, weight: .bold))
          .foregroundStyle(selectedTheme.general.accentColor())
          .padding(.top, 12)
          .padding(.bottom, 48)
      }
    }

    if reachedEndOfFeed {
      EndOfFeedView()
    }
  }
}
