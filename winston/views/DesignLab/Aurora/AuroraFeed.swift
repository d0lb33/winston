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
  private var latestFrameByID: [String: AuroraReadFrame] = [:]
  private var previousFrameByID: [String: AuroraReadFrame] = [:]
  private var visiblePostIDs: Set<String> = []
  private var isScrollingDown = false

  func updateFrame(_ frame: AuroraReadFrame, for postID: String) {
    ScrollPerfDiagnostics.bump("auroraRead.frameUpdate")
    latestFrameByID[postID] = frame
    if frame.isVisible {
      visiblePostIDs.insert(postID)
    }
  }

  func remove(postID: String) {
    ScrollPerfDiagnostics.bump("auroraRead.frameRemove")
    latestFrameByID.removeValue(forKey: postID)
    previousFrameByID.removeValue(forKey: postID)
    visiblePostIDs.remove(postID)
  }

  func markIfDisappearedPastTop(_ post: Post, readOnScroll: Bool) {
    ScrollPerfDiagnostics.bump("auroraRead.disappearCheck")
    guard readOnScroll, isScrollingDown, FeedScrollWorkCoordinator.shared.isScrolling else { return }
    guard visiblePostIDs.contains(post.id) else { return }
    ScrollPerfDiagnostics.bump("auroraRead.markSeen.disappear")
    FeedScrollWorkCoordinator.shared.markSeenWhenIdle(post)
  }

  func markCrossedPostsIfNeeded(offsetY: CGFloat, visiblePosts: [Post], readOnScroll: Bool) {
    ScrollPerfDiagnostics.measure("auroraRead.crossedCheck", slowThresholdMs: 4, slowMessage: "Read-on-scroll crossed-post check was slow", metadata: ["visiblePosts": "\(visiblePosts.count)", "trackedFrames": "\(latestFrameByID.count)"]) {
      let scrollingDown = previousScrollOffsetY.map { offsetY > $0 } ?? false
      isScrollingDown = scrollingDown
      defer {
        previousScrollOffsetY = offsetY
        previousFrameByID = latestFrameByID
      }

      guard readOnScroll, scrollingDown else { return }

      let crossedIDs: Set<String> = Set(latestFrameByID.compactMap { id, frame in
        guard let previousFrame = previousFrameByID[id] else { return nil }
        return previousFrame.maxY > 0 && frame.maxY <= 0 ? id : nil
      })
      guard !crossedIDs.isEmpty else { return }

      for _ in crossedIDs {
        ScrollPerfDiagnostics.bump("auroraRead.markSeen.crossed")
      }
      visiblePosts
        .filter { crossedIDs.contains($0.id) }
        .forEach { FeedScrollWorkCoordinator.shared.markSeenWhenIdle($0) }
    }
  }
}

private struct AuroraReadFrame: Equatable {
  let minY: CGFloat
  let maxY: CGFloat
  let viewportHeight: CGFloat

  var height: CGFloat {
    max(maxY - minY, 1)
  }

  var isVisible: Bool {
    maxY > 0 && minY < viewportHeight
  }
}

struct AuroraFeedScrollPosition: Equatable {
  let id: String
  let anchorY: CGFloat

  var unitPoint: UnitPoint {
    UnitPoint(x: 0.5, y: min(1, max(0, anchorY)))
  }
}

/// Names the focused visible post so scroll position can be restored across the compact↔wide
/// shell swap. A plain (non-observable) box so per-frame geometry churn never triggers a view
/// re-render. `List` does not write its scroll position back through `.scrollPosition(id:)`
/// (that's a ScrollView API — verified nil on List), so we derive the focus row from row frames.
private final class AuroraVisibleRowsBox {
  private var frames: [String: AuroraReadFrame] = [:]

  func update(_ frame: AuroraReadFrame, id: String) { frames[id] = frame }
  func remove(_ id: String) { frames.removeValue(forKey: id) }

  /// The row around the user's reading line, plus an anchor that keeps that row in roughly
  /// the same viewport position after a resize. Saving the topmost sliver and restoring it to
  /// `.top` makes repeated rotate/fold cycles "walk" upward through the feed.
  func focusedPosition() -> AuroraFeedScrollPosition? {
    let visibleFrames = frames.filter { _, frame in frame.isVisible }
    guard !visibleFrames.isEmpty else { return nil }
    let viewportHeight = visibleFrames.first?.value.viewportHeight ?? 1
    let focusY = viewportHeight * 0.38

    let focused = visibleFrames.min { lhs, rhs in
      focusDistance(frame: lhs.value, focusY: focusY) < focusDistance(frame: rhs.value, focusY: focusY)
    }
    guard let (id, frame) = focused else { return nil }
    return AuroraFeedScrollPosition(id: id, anchorY: restoreAnchorY(for: frame))
  }

  private func focusDistance(frame: AuroraReadFrame, focusY: CGFloat) -> CGFloat {
    if frame.minY <= focusY, frame.maxY >= focusY { return 0 }
    return min(abs(frame.minY - focusY), abs(frame.maxY - focusY))
  }

  private func restoreAnchorY(for frame: AuroraReadFrame) -> CGFloat {
    let denominator = frame.viewportHeight - frame.height
    guard abs(denominator) > 1 else { return 0.5 }
    return min(1, max(0, frame.minY / denominator))
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
  let scrollToTopRequest: Int
  let onScrollStateChanged: (Bool) -> Void
  var onCompactNavigate: ((NavDest) -> Void)? = nil
  @Environment(\.contentWidth) private var contentWidth
  @Environment(\.horizontalSizeClass) private var hSize
  @Default(.PostLinkDefSettings) private var postLinkDefSettings

  @Binding private var scrollPosition: AuroraFeedScrollPosition?
  @State private var readOnScrollTracker = AuroraReadOnScrollTracker()
  @State private var visibleRows = AuroraVisibleRowsBox()
  @State private var handledInitialAppear = false
  /// Last observed content offset. Mirrors the live scroll geometry so reselect's
  /// "can scroll to top" can be re-derived on every appearance (see `.onAppear`),
  /// rather than depending on `onScrollGeometryChange` — a *change* handler that does
  /// not re-fire for a preserved offset when this feed re-appears after a pushed post.
  @State private var lastContentOffsetY: CGFloat = 0

  init(
    model: AuroraFeedModel,
    title: String,
    community: Subreddit?,
    selectedPostID: Binding<String?>,
    scrollPosition: Binding<AuroraFeedScrollPosition?>,
    sort: Binding<SubListingSortOption>,
    scrollToTopRequest: Int = 0,
    onScrollStateChanged: @escaping (Bool) -> Void = { _ in },
    onCompactNavigate: ((NavDest) -> Void)? = nil
  ) {
    self.model = model
    self.title = title
    self.community = community
    self._selectedPostID = selectedPostID
    self._scrollPosition = scrollPosition
    self._sort = sort
    self.scrollToTopRequest = scrollToTopRequest
    self.onScrollStateChanged = onScrollStateChanged
    self.onCompactNavigate = onCompactNavigate
  }

  var body: some View {
    let _ = ScrollPerfDiagnostics.bump("auroraFeed.body")
    let visiblePosts = model.visiblePosts
    // Decode the Codable PostLink settings ONCE per body eval (not per scroll frame in
    // onOffsetChange, nor per card in the ForEach background / card body). The plain
    // value is threaded into each row via `settings:` → `.environment(\.auroraCardSettings)`.
    let cardSettings = AuroraCardSettings(postLinkDefSettings)

    GeometryReader { geometry in
      let rowWidth = max(1, geometry.size.width)

      ScrollViewReader { proxy in
        List(selection: $selectedPostID) {
          Color.clear
            .frame(height: 0)
            .id(Self.topID)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityHidden(true)
          if let community {
            AuroraCommunityHeader(sub: community)
              .listRowBackground(Color.clear)
              .listRowSeparator(.hidden)
              .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 2, trailing: 14))
          }
          ForEach(visiblePosts) { post in
            AuroraPostCardRow(post: post, availableRowWidth: rowWidth, isSelected: post.id == selectedPostID && hSize == .regular, onCompactNavigate: onCompactNavigate, settings: cardSettings)
              .tag(post.id)
              .id(post.id)
              .background {
                // Always on: feeds the topmost-visible tracker so scroll position survives a
                // fold/unfold. Read-on-scroll piggybacks on the same single frame read.
                Color.clear
                  .onGeometryChange(for: AuroraReadFrame.self) { proxy in
                    let frame = proxy.frame(in: .named("auroraFeed"))
                    return AuroraReadFrame(
                      minY: frame.minY,
                      maxY: frame.maxY,
                      viewportHeight: geometry.size.height
                    )
                  } action: { frame in
                    visibleRows.update(frame, id: post.id)
                    if cardSettings.readOnScroll {
                      readOnScrollTracker.updateFrame(frame, for: post.id)
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
                ScrollPerfDiagnostics.bump("auroraFeed.rowAppear")
                if post.id == visiblePosts.last?.id {
                  ScrollPerfDiagnostics.event(
                    "Aurora feed load-more triggered",
                    metadata: ["post": post.id, "visiblePosts": "\(visiblePosts.count)", "sort": sort.rawVal.value]
                  )
                  Task { @MainActor in
                    await model.loadMore(sort: sort, contentWidth: contentWidth)
                  }
                }
              }
              .onDisappear {
                ScrollPerfDiagnostics.bump("auroraFeed.rowDisappear")
                visibleRows.remove(post.id)
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
        // NOTE: `.scrollPosition(id:)` is a ScrollView (+ `scrollTargetLayout`) API — on a
        // `List` it never writes the position back through the binding (verified: the binding
        // stays nil while scrolling). So we name the focused visible row ourselves below and
        // restore it via the ScrollViewReader proxy on appear (see `.onAppear`).
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
          geometry.contentOffset.y
        } action: { _, offsetY in
          lastContentOffsetY = offsetY
          onScrollStateChanged(offsetY > 8)
          // Persist where we are (the focused on-screen post) so a fold/unfold that recreates
          // this List can land back here instead of jumping to the top. Only record while
          // genuinely scrolled down (> 8pt): rotation tears the List down by collapsing its
          // offset toward 0, and writing the top sentinel there would clobber the saved post.
          // The top sentinel is recorded only by the explicit scroll-to-top action below.
          if offsetY > 8, let focusedPosition = visibleRows.focusedPosition(), focusedPosition != scrollPosition {
            scrollPosition = focusedPosition
          }
          ScrollPerfDiagnostics.measure("auroraFeed.offsetChange", slowThresholdMs: 3, slowMessage: "Aurora feed offset handling was slow", metadata: ["visiblePosts": "\(visiblePosts.count)", "readOnScroll": "\(cardSettings.readOnScroll)"]) {
            readOnScrollTracker.markCrossedPostsIfNeeded(offsetY: offsetY, visiblePosts: visiblePosts, readOnScroll: cardSettings.readOnScroll)
          }
        }
        .onChange(of: scrollToTopRequest) { _, _ in
          withAnimation(.snappy) {
            proxy.scrollTo(Self.topID, anchor: .top)
          }
          scrollPosition = AuroraFeedScrollPosition(id: Self.topID, anchorY: 0)
          onScrollStateChanged(false)
        }
        .onAppear {
          // Re-assert reselect's "can scroll to top" from the live offset on EVERY appearance.
          // Returning from a pushed post (compact) fires onAppear with the List's offset
          // preserved, but our onDisappear forced the flag false — so a scrolled feed looked
          // "already at top" and a tab reselect popped instead of scrolling up. onScrollGeometry-
          // Change is a *change* handler and won't re-fire for the preserved offset, so re-derive.
          onScrollStateChanged(lastContentOffsetY > 8)

          guard !handledInitialAppear else { return }
          handledInitialAppear = true
          // The compact (NavigationStack) and wide (NavigationSplitView) shells are separate
          // view trees, so folding/unfolding recreates this List. Restore to the post that was
          // near the user's reading line before the swap (recorded in the shared binding during
          // scroll) so the fresh List lands where we left off instead of jumping to the top. Do
          // this only for this feed view's initial appearance; returning from a pushed post can
          // also trigger onAppear, and reapplying the saved anchor there moves the feed.
          if let scrollPosition, scrollPosition.id != Self.topID {
            proxy.scrollTo(scrollPosition.id, anchor: scrollPosition.unitPoint)
            // The recreated List starts at offset 0, so the geometry handler hasn't run yet —
            // mark us scrolled-down to match the restored anchor so reselect scrolls to top first.
            lastContentOffsetY = max(lastContentOffsetY, 9)
            onScrollStateChanged(true)
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .driveInlineVideoCoordinator(coordinateSpace: "auroraFeed", posts: visiblePosts)
        .refreshable { await model.reload(sort: sort, contentWidth: contentWidth) }
        .overlay { if visiblePosts.isEmpty { emptyState(hasLoadedPosts: !model.posts.isEmpty) } }
      }
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
      ScrollPerfDiagnostics.event(
        "Aurora feed task started",
        metadata: ["feedIdentity": model.feedIdentity, "visiblePosts": "\(model.visiblePosts.count)"]
      )
      await model.loadInitialIfNeeded(sort: sort, contentWidth: contentWidth)
    }
    .onAppear {
      ScrollPerfDiagnostics.event(
        "Aurora feed appeared",
        metadata: ["feedIdentity": model.feedIdentity, "visiblePosts": "\(model.visiblePosts.count)", "scrollPosition": scrollPosition?.id ?? "nil", "scrollAnchorY": scrollPosition.map { String(format: "%.3f", $0.anchorY) } ?? "nil"]
      )
      // Belt-and-suspenders recovery: if a previous load was cancelled or settled empty and
      // the `.task(id:)` doesn't re-fire on this re-appearance, re-attempt here. The model's
      // in-flight + has-content guards make this a no-op when a load is running or content
      // exists, so it never double-loads.
      Task { @MainActor in await model.loadInitialIfNeeded(sort: sort, contentWidth: contentWidth) }
    }
    .onDisappear {
      onScrollStateChanged(false)
      ScrollPerfDiagnostics.event(
        "Aurora feed disappeared",
        metadata: ["feedIdentity": model.feedIdentity, "visiblePosts": "\(model.visiblePosts.count)", "scrollPosition": scrollPosition?.id ?? "nil", "scrollAnchorY": scrollPosition.map { String(format: "%.3f", $0.anchorY) } ?? "nil"]
      )
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
