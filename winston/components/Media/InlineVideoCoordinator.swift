//
//  InlineVideoCoordinator.swift
//  winston
//
//  Coordinates inline video playback across the feed so that only ONE video
//  (the one nearest the viewport center) autoplays at a time. This collapses
//  N simultaneous AVPlayer decoders down to 1, which is the main cause of
//  scroll hitches in video-heavy subreddits.
//
//  Autoplay is not removed — it is gated. The active video keeps playing during
//  scroll, and when scrolling settles the centered video becomes active.
//

import SwiftUI
import Observation
import Foundation

@MainActor
final class FeedScrollWorkCoordinator {
  static let shared = FeedScrollWorkCoordinator()

  let idleDelay: TimeInterval = 0.18
  private let seenBatchMaxAge: TimeInterval = 1.0
  private(set) var isScrolling = false
  private(set) var isSettling = false

  private var idleWorkItem: DispatchWorkItem?
  private var seenBatchWorkItem: DispatchWorkItem?
  private var scheduledWorkItems: [String: DispatchWorkItem] = [:]
  private var pendingWork: [String: () -> Void] = [:]
  private var pendingSeenPosts: [String: Post] = [:]

  var shouldDeferWork: Bool { isScrolling || isSettling }

  private init() {}

  func setScrolling(_ scrolling: Bool) {
    guard scrolling != isScrolling else { return }
    isScrolling = scrolling

    if scrolling {
      isSettling = false
      idleWorkItem?.cancel()
      idleWorkItem = nil
      cancelScheduledWorkItems()
    } else {
      isSettling = true
      scheduleIdleFlush()
    }
  }

  func performWhenIdle(key: String, delay: TimeInterval? = nil, _ work: @escaping () -> Void) {
    pendingWork[key] = work
    scheduledWorkItems[key]?.cancel()

    guard !shouldDeferWork else { return }
    schedulePendingWork(key: key, delay: delay ?? 0)
  }

  func cancel(key: String) {
    pendingWork.removeValue(forKey: key)
    scheduledWorkItems.removeValue(forKey: key)?.cancel()
  }

  func markSeenWhenIdle(_ post: Post) {
    guard isScrolling || isSettling else { return }
    guard post.data?.winstonSeen != true else { return }
    post.setLocalSeenState(true)
    pendingSeenPosts[post.id] = post

    if shouldDeferWork {
      scheduleSeenBatchFlush()
    } else {
      scheduleIdleFlush(delay: 0)
    }
  }

  func flushPendingWork() {
    idleWorkItem?.cancel()
    idleWorkItem = nil
    seenBatchWorkItem?.cancel()
    seenBatchWorkItem = nil
    isSettling = false
    cancelScheduledWorkItems()

    let workItems = pendingWork
    pendingWork.removeAll(keepingCapacity: true)
    workItems.values.forEach { $0() }

    flushPendingSeenPosts()
  }

  private func scheduleIdleFlush(delay: TimeInterval? = nil) {
    idleWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      Task { @MainActor in
        self?.flushPendingWork()
      }
    }
    idleWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? idleDelay), execute: item)
  }

  private func scheduleSeenBatchFlush() {
    guard seenBatchWorkItem == nil else { return }

    let item = DispatchWorkItem { [weak self] in
      Task { @MainActor in
        self?.flushPendingSeenPosts()
      }
    }
    seenBatchWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + seenBatchMaxAge, execute: item)
  }

  private func flushPendingSeenPosts() {
    seenBatchWorkItem?.cancel()
    seenBatchWorkItem = nil

    let seenPostIDs = Set(pendingSeenPosts.values.filter { $0.data?.winstonSeen == true }.map(\.id))
    pendingSeenPosts.removeAll(keepingCapacity: true)
    guard !seenPostIDs.isEmpty else { return }

    Task(priority: .background) {
      await Post.persistSeenPostIDs(seenPostIDs)
    }
  }

  private func schedulePendingWork(key: String, delay: TimeInterval) {
    let item = DispatchWorkItem { [weak self] in
      Task { @MainActor in
        guard let self, !self.shouldDeferWork, let work = self.pendingWork.removeValue(forKey: key) else { return }
        self.scheduledWorkItems.removeValue(forKey: key)
        work()
      }
    }
    scheduledWorkItems[key] = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  private func cancelScheduledWorkItems() {
    scheduledWorkItems.values.forEach { $0.cancel() }
    scheduledWorkItems.removeAll(keepingCapacity: true)
  }
}

@MainActor
@Observable
final class InlineVideoCoordinator {
  static let shared = InlineVideoCoordinator()

  /// The feed-item key (post id) of the single video allowed to autoplay inline.
  private(set) var activeVideoKey: String?

  /// Nearby inline videos allowed to mount a paused AVPlayer so their first frame can
  /// be ready before they become centered. This stays tiny and is cleared on fast scroll.
  private(set) var warmVideoKeys: Set<String> = []

  /// True while the feed scroll view is interacting/decelerating. Used to defer
  /// expensive media setup; it does not pause the active inline player.
  private(set) var isScrolling: Bool = false

  /// True when center updates indicate the feed is moving quickly enough that mounting
  /// nearby paused players would likely hurt scroll smoothness more than it helps.
  private(set) var isFastScrolling: Bool = false

  // Latest per-row centers and viewport height, updated as the feed reports geometry.
  // ObservationIgnored: written every frame during scroll — must not invalidate views.
  @ObservationIgnored private var latestCenters: [InlineVideoCenter] = []
  @ObservationIgnored var viewportHeight: CGFloat = 1
  @ObservationIgnored private var lastCentersMeanY: CGFloat?
  @ObservationIgnored private var lastCentersTimestamp: TimeInterval?
  @ObservationIgnored private var lastScrollDeltaY: CGFloat = 0

  private let warmAheadCount = 3
  private let fastScrollVelocityThreshold: CGFloat = 2_200

  private init() {}

  func setActive(_ key: String?) {
    guard key != activeVideoKey else { return }
    ScrollPerfProbe.shared.bump("inlineActiveChange")
    activeVideoKey = key
  }

  func setScrolling(_ scrolling: Bool) {
    guard scrolling != isScrolling else { return }
    ScrollPerfProbe.shared.bump(scrolling ? "scrollBegan" : "scrollEnded")
    isScrolling = scrolling
    if scrolling {
      updateWarmVideoKeys(forceEmpty: true)
    }
  }

  func isActive(_ key: String?) -> Bool {
    key != nil && key == activeVideoKey
  }

  func isWarm(_ key: String?) -> Bool {
    guard let key else { return false }
    return warmVideoKeys.contains(key)
  }

  /// Cheap per-frame sink for row centers. Slow scrolls may elect the centered video
  /// immediately; fast scrolls wait until velocity drops or the feed settles.
  func updateCenters(_ centers: [InlineVideoCenter]) {
    ScrollPerfProbe.shared.bump("inlineCenterUpdate")
    latestCenters = centers.sorted { $0.midY < $1.midY }
    updateScrollVelocity(from: latestCenters)

    if isScrolling {
      guard !isFastScrolling else { return }
      electCenteredVideo(updateWarmSet: false)
      return
    }

    // Only (re)populate the warm set at rest. Mounting paused AVPlayers + AVPlayerLayers
    // mid-scroll (attaching to the player and kicking off HLS asset loading on the main
    // thread) is the main remaining source of fast-scroll hitches. `electCenteredVideo`
    // already warms neighbors when the feed settles, so the next video is still ready by
    // the time you stop — we just stop paying for it during the scroll itself.
    guard !FeedScrollWorkCoordinator.shared.shouldDeferWork else { return }
    updateWarmVideoKeys()
  }

  /// Pick the video nearest the viewport center and make it active. Called when the
  /// feed settles, or while slow scrolling.
  func electCenteredVideo(updateWarmSet: Bool = true) {
    let center = viewportHeight / 2
    let nearest = latestCenters.min(by: { abs($0.midY - center) < abs($1.midY - center) })?.key
    setActive(nearest)
    if updateWarmSet {
      isFastScrolling = false
      updateWarmVideoKeys()
    }
  }

  private func updateScrollVelocity(from centers: [InlineVideoCenter]) {
    guard !centers.isEmpty else {
      setFastScrolling(false)
      return
    }

    let meanY = centers.reduce(CGFloat.zero) { $0 + $1.midY } / CGFloat(centers.count)
    let now = Date.timeIntervalSinceReferenceDate
    defer {
      lastCentersMeanY = meanY
      lastCentersTimestamp = now
    }

    guard isScrolling, let lastCentersMeanY, let lastCentersTimestamp else {
      setFastScrolling(false)
      return
    }

    let elapsed = max(now - lastCentersTimestamp, 0.001)
    let delta = meanY - lastCentersMeanY
    lastScrollDeltaY = delta
    setFastScrolling(abs(delta) / elapsed > fastScrollVelocityThreshold)
  }

  private func setFastScrolling(_ fast: Bool) {
    guard fast != isFastScrolling else { return }
    isFastScrolling = fast
    if fast {
      updateWarmVideoKeys(forceEmpty: true)
    }
  }

  private func updateWarmVideoKeys(forceEmpty: Bool = false) {
    guard !forceEmpty, !isFastScrolling, !latestCenters.isEmpty else {
      if !warmVideoKeys.isEmpty {
        ScrollPerfProbe.shared.bump("inlineWarmChange")
        warmVideoKeys = []
      }
      return
    }

    let center = viewportHeight / 2
    let nearest = latestCenters.min(by: { abs($0.midY - center) < abs($1.midY - center) })
    let movingTowardLaterPosts = lastScrollDeltaY <= 0
    let ahead = movingTowardLaterPosts
      ? latestCenters.filter { $0.midY >= center }
      : Array(latestCenters.filter { $0.midY <= center }.reversed())

    var keys = Array(ahead.prefix(warmAheadCount).map(\.key))
    if let nearest, !keys.contains(nearest.key) {
      keys.insert(nearest.key, at: 0)
    }

    let nextKeys = Set(keys.prefix(warmAheadCount + 1))
    if nextKeys != warmVideoKeys {
      ScrollPerfProbe.shared.bump("inlineWarmChange")
      warmVideoKeys = nextKeys
    }
  }

  func diagnosticMetadata() -> [String: String] {
    [
      "inlineActive": activeVideoKey.map { "\($0.hashValue)" } ?? "nil",
      "inlineWarmCount": "\(warmVideoKeys.count)",
      "inlineCenters": "\(latestCenters.count)",
      "inlineScrolling": "\(isScrolling)",
      "inlineFastScrolling": "\(isFastScrolling)",
      "inlineViewportHeight": String(format: "%.1f", viewportHeight),
      "inlineLastDeltaY": String(format: "%.1f", lastScrollDeltaY)
    ]
  }
}

// MARK: - Per-row center reporting

/// A feed row's video key and its vertical center within the feed's coordinate space.
struct InlineVideoCenter: Equatable {
  let key: String
  let midY: CGFloat
}

struct InlineVideoCenterPreferenceKey: PreferenceKey {
  static var defaultValue: [InlineVideoCenter] = []
  static func reduce(value: inout [InlineVideoCenter], nextValue: () -> [InlineVideoCenter]) {
    value.append(contentsOf: nextValue())
  }
}

/// Reports a row's vertical center (in the named feed coordinate space) so the feed can
/// elect the centered video. No-op for non-video rows so image/text feeds pay nothing.
private struct InlineVideoCenterTracker: ViewModifier {
  let key: String
  let coordinateSpace: String
  let enabled: Bool

  func body(content: Content) -> some View {
    if enabled {
      content.background(
        GeometryReader { geo in
          Color.clear.preference(
            key: InlineVideoCenterPreferenceKey.self,
            value: [InlineVideoCenter(key: key, midY: geo.frame(in: .named(coordinateSpace)).midY)]
          )
        }
      )
    } else {
      content
    }
  }
}

extension View {
  /// Track this row's center for single-active-video election. `enabled` should be true
  /// only for rows that contain an inline video (see `MediaExtractedType.isInlineVideo`).
  func trackInlineVideoCenter(key: String, coordinateSpace: String, enabled: Bool) -> some View {
    modifier(InlineVideoCenterTracker(key: key, coordinateSpace: coordinateSpace, enabled: enabled))
  }

  /// Drive the coordinator from a scrollable feed: report scroll phase (for deferring
  /// expensive work) and elect the centered video when the feed settles. Slow scrolls
  /// can also elect from center updates; fast scrolls wait.
  func driveInlineVideoCoordinator(coordinateSpace: String) -> some View {
    self
      .modifier(FeedScrollCoordinatorDriver(coordinateSpace: coordinateSpace))
  }
}

private struct FeedScrollCoordinatorDriver: ViewModifier {
  @Environment(\.scenePhase) private var scenePhase
  let coordinateSpace: String

  func body(content: Content) -> some View {
    content
      .environment(\.deferMediaWorkWhileScrolling, true)
      .coordinateSpace(.named(coordinateSpace))
      .onScrollPhaseChange { _, phase in
        let scrolling = phase != .idle
        FeedScrollWorkCoordinator.shared.setScrolling(scrolling)
        InlineVideoCoordinator.shared.setScrolling(scrolling)
        if !scrolling {
          FeedScrollWorkCoordinator.shared.performWhenIdle(key: "inlineVideo.elect.\(coordinateSpace)") {
            InlineVideoCoordinator.shared.electCenteredVideo()
          }
        }
      }
      .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, newHeight in
        if newHeight > 0 { InlineVideoCoordinator.shared.viewportHeight = newHeight }
      }
      .onPreferenceChange(InlineVideoCenterPreferenceKey.self) { centers in
        InlineVideoCoordinator.shared.updateCenters(centers)
        guard !InlineVideoCoordinator.shared.isScrolling else { return }
        FeedScrollWorkCoordinator.shared.performWhenIdle(key: "inlineVideo.elect.\(coordinateSpace)") {
          InlineVideoCoordinator.shared.electCenteredVideo()
        }
      }
      .onChange(of: scenePhase) { _, newPhase in
        if newPhase != .active {
          FeedScrollWorkCoordinator.shared.flushPendingWork()
        }
      }
      .onDisappear {
        FeedScrollWorkCoordinator.shared.flushPendingWork()
      }
  }
}
