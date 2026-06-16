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
import AVFoundation
import Network
import Nuke
import QuartzCore

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
final class InlineVideoPlaybackState {
  let key: String
  var shouldPlay = false
  var shouldMountPlayer = false
  var isPrefetchTarget = false
  var visibleFraction: CGFloat = 0

  init(key: String) {
    self.key = key
  }
}

@MainActor
final class MediaPrefetchCoordinator {
  static let shared = MediaPrefetchCoordinator()

  private struct PendingVideo: Equatable {
    let key: String
    let url: URL
  }

  private let monitor = NWPathMonitor()
  private let monitorQueue = DispatchQueue(label: "lo.cafe.winston.media-prefetch.path")
  private var pathIsExpensive = false
  private var pathIsConstrained = false
  private var lastImageSignature = ""
  private var lastVideoSignature = ""
  private var pendingVideos: [PendingVideo] = []
  private var activeVideoTasks: [String: Task<Void, Never>] = [:]
  private var prewarmedVideoKeys: Set<String> = []
  private var prefetchVideoKeys: Set<String> = []
  private var cancelledFastScrollUpdates = 0
  private var lastDirection = "down"
  private var lastWindowPostCount = 0
  private var lastImageRequestCount = 0
  private var lastVideoTargetCount = 0
  private var lastQueuedVideoCount = 0
  private var lastFastScrollSkipDirection = "none"

  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      Task { @MainActor in
        self?.pathIsExpensive = path.isExpensive
        self?.pathIsConstrained = path.isConstrained
      }
    }
    monitor.start(queue: monitorQueue)
  }

  func updateFeedWindow(
    posts: [Post],
    visibilities: [InlineVideoVisibility],
    movingTowardLaterPosts: Bool,
    isFastScrolling: Bool
  ) {
    guard !posts.isEmpty else {
      updatePrefetchVideoKeys([])
      return
    }

    lastDirection = movingTowardLaterPosts ? "down" : "up"
    if isFastScrolling {
      cancelledFastScrollUpdates += 1
      lastFastScrollSkipDirection = lastDirection
      ScrollPerfProbe.shared.bump("mediaPrefetch.fastScrollSkip")
      ScrollPerfProbe.shared.bump("mediaPrefetch.fastScrollSkip.\(lastDirection)")
      return
    }

    let policy = currentPolicy()
    let window = postWindow(
      posts: posts,
      visibilities: visibilities,
      movingTowardLaterPosts: movingTowardLaterPosts,
      imageAheadCount: policy.imageAheadCount
    )
    lastWindowPostCount = window.count

    startImagePrefetch(for: window)
    startVideoPrewarm(for: window, limit: policy.videoAheadCount, maxConcurrent: policy.maxVideoConcurrency)
  }

  func isPrefetchTarget(_ key: String) -> Bool {
    prefetchVideoKeys.contains(key)
  }

  func diagnosticMetadata() -> [String: String] {
    [
      "mediaPrefetchVideoTargets": "\(prefetchVideoKeys.count)",
      "mediaPrefetchActiveVideoTasks": "\(activeVideoTasks.count)",
      "mediaPrefetchPrewarmedVideos": "\(prewarmedVideoKeys.count)",
      "mediaPrefetchFastScrollSkips": "\(cancelledFastScrollUpdates)",
      "mediaPrefetchDirection": lastDirection,
      "mediaPrefetchFastSkipDirection": lastFastScrollSkipDirection,
      "mediaPrefetchWindowPosts": "\(lastWindowPostCount)",
      "mediaPrefetchImageRequests": "\(lastImageRequestCount)",
      "mediaPrefetchVideoCandidates": "\(lastVideoTargetCount)",
      "mediaPrefetchQueuedVideos": "\(lastQueuedVideoCount)",
      "mediaPrefetchExpensiveNetwork": "\(pathIsExpensive)",
      "mediaPrefetchConstrainedNetwork": "\(pathIsConstrained)",
      "mediaPrefetchLowPower": "\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
    ]
  }

  private func currentPolicy() -> (imageAheadCount: Int, videoAheadCount: Int, maxVideoConcurrency: Int) {
    if ProcessInfo.processInfo.isLowPowerModeEnabled || pathIsConstrained {
      return (6, 2, 1)
    }
    if pathIsExpensive {
      return (8, 2, 1)
    }
    return (12, 4, 2)
  }

  private func postWindow(
    posts: [Post],
    visibilities: [InlineVideoVisibility],
    movingTowardLaterPosts: Bool,
    imageAheadCount: Int
  ) -> [Post] {
    let visibleIDs = Set(visibilities.filter { $0.visibleFraction > 0 }.map(\.key))
    let visiblePosts = posts.filter { visibleIDs.contains($0.id) }

    let anchorID = InlineVideoCoordinator.shared.activeVideoKey
      ?? visibilities.max(by: { $0.visibleFraction < $1.visibleFraction })?.key
    let anchorIndex = anchorID.flatMap { id in posts.firstIndex(where: { $0.id == id }) } ?? 0

    let ahead: [Post]
    if movingTowardLaterPosts {
      ahead = Array(posts.dropFirst(anchorIndex).prefix(imageAheadCount))
    } else {
      let prefix = posts.prefix(anchorIndex + 1).reversed()
      ahead = Array(prefix.prefix(imageAheadCount))
    }

    var seen: Set<String> = []
    return (visiblePosts + ahead).filter { post in
      seen.insert(post.id).inserted
    }
  }

  private func startImagePrefetch(for posts: [Post]) {
    let requests = posts.flatMap { imageRequests(for: $0) }
    lastImageRequestCount = requests.count
    let signature = requests.map(\.description).joined(separator: "|")
    guard !requests.isEmpty, signature != lastImageSignature else { return }
    lastImageSignature = signature
    ScrollPerfProbe.shared.bump("mediaPrefetch.images")
    ScrollPerfProbe.shared.bump("mediaPrefetch.images.\(lastDirection)")
    Post.prefetcher.startPrefetching(with: requests)
    if AppDiagnostics.isEnabled(.debug, category: "ui.media.prefetch") {
      AppDiagnostics.asyncRecord(
        .debug,
        category: "ui.media.prefetch",
        message: "Media image prefetch window updated",
        metadata: ["posts": "\(posts.count)", "requests": "\(requests.count)"]
      )
    }
  }

  private func startVideoPrewarm(for posts: [Post], limit: Int, maxConcurrent: Int) {
    let videos = posts.compactMap { videoTarget(for: $0) }
    lastVideoTargetCount = videos.count
    let limited = Array(videos.prefix(limit))
    let signature = limited.map(\.key).joined(separator: "|")
    guard signature != lastVideoSignature else { return }
    lastVideoSignature = signature
    updatePrefetchVideoKeys(Set(limited.map(\.key)))

    pendingVideos = limited.filter { target in
      !prewarmedVideoKeys.contains(target.key) && activeVideoTasks[target.key] == nil
    }
    lastQueuedVideoCount = pendingVideos.count
    if !pendingVideos.isEmpty {
      ScrollPerfProbe.shared.bump("mediaPrefetch.videoQueued")
      ScrollPerfProbe.shared.bump("mediaPrefetch.videoQueued.\(lastDirection)")
    }
    startQueuedVideoPrewarmIfNeeded(maxConcurrent: maxConcurrent)
  }

  private func startQueuedVideoPrewarmIfNeeded(maxConcurrent: Int? = nil) {
    let limit = maxConcurrent ?? currentPolicy().maxVideoConcurrency
    while activeVideoTasks.count < limit, !pendingVideos.isEmpty {
      let target = pendingVideos.removeFirst()
      activeVideoTasks[target.key] = Task { [weak self, key = target.key, url = target.url] in
        let asset = AVURLAsset(url: url)
        _ = try? await asset.load(.isPlayable)
        await MainActor.run {
          guard let self else { return }
          self.activeVideoTasks.removeValue(forKey: key)
          self.prewarmedVideoKeys.insert(key)
          ScrollPerfProbe.shared.bump("mediaPrefetch.videoAsset")
          self.startQueuedVideoPrewarmIfNeeded()
        }
      }
    }
  }

  private func updatePrefetchVideoKeys(_ keys: Set<String>) {
    guard keys != prefetchVideoKeys else { return }
    prefetchVideoKeys = keys
    InlineVideoCoordinator.shared.setPrefetchVideoKeys(keys)
  }

  private func imageRequests(for post: Post) -> [ImageRequest] {
    guard let media = post.winstonData?.extractedMediaForcedNormal ?? post.winstonData?.extractedMedia else { return [] }
    switch media {
    case .imgs(let imgs):
      return imgs.map(\.request)
    case .video(let sharedVideo):
      guard let posterURL = sharedVideo.posterURL else { return [] }
      return [
        winstonImageRequest(
          url: posterURL,
          processors: [ImageProcessors.ScaleFixer()],
          priority: .high,
          thumbnail: nil
        )
      ]
    case .yt(let yt):
      return [yt.thumbnailRequest]
    case .repost(let repost):
      return imageRequests(for: repost)
    default:
      return []
    }
  }

  private func videoTarget(for post: Post) -> PendingVideo? {
    guard let media = post.winstonData?.extractedMediaForcedNormal ?? post.winstonData?.extractedMedia else { return nil }
    switch media {
    case .video(let sharedVideo):
      return PendingVideo(
        key: post.id,
        url: sharedVideo.downloadURL ?? sharedVideo.url
      )
    case .repost(let repost):
      return videoTarget(for: repost).map { PendingVideo(key: post.id, url: $0.url) }
    default:
      return nil
    }
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

  // Latest per-row visibility and viewport height, updated as the feed reports geometry.
  // ObservationIgnored: written every frame during scroll — must not invalidate views.
  @ObservationIgnored private var latestVisibilities: [InlineVideoVisibility] = []
  @ObservationIgnored var viewportHeight: CGFloat = 1
  @ObservationIgnored private var lastVisibilityMeanY: CGFloat?
  @ObservationIgnored private var lastVisibilityTimestamp: TimeInterval?
  @ObservationIgnored private var lastScrollDeltaY: CGFloat = 0
  @ObservationIgnored private var playbackStates: [String: InlineVideoPlaybackState] = [:]
  @ObservationIgnored private var prefetchVideoKeys: Set<String> = []
  @ObservationIgnored private var activeSince: [String: CFTimeInterval] = [:]

  private let warmAheadCount = 1
  private let fastScrollVelocityThreshold: CGFloat = 2_200
  private let playVisibleThreshold: CGFloat = 0.55
  private let pauseVisibleThreshold: CGFloat = 0.15

  private init() {}

  var movingTowardLaterPosts: Bool {
    lastScrollDeltaY <= 0
  }

  func state(for key: String) -> InlineVideoPlaybackState {
    if let existing = playbackStates[key] { return existing }
    let state = InlineVideoPlaybackState(key: key)
    playbackStates[key] = state
    applyPlaybackValues(to: state)
    return state
  }

  func setActive(_ key: String?) {
    guard key != activeVideoKey else { return }
    ScrollPerfProbe.shared.bump("inlineActiveChange")
    activeVideoKey = key
    if let key {
      activeSince[key] = CACurrentMediaTime()
    }
    updatePlaybackStates()
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

  func setPrefetchVideoKeys(_ keys: Set<String>) {
    guard keys != prefetchVideoKeys else { return }
    prefetchVideoKeys = keys
    updatePlaybackStates()
  }

  func recordFirstFrameReady(key: String, sharedVideo: SharedVideo) {
    guard let started = activeSince[key] else { return }
    let elapsedMs = (CACurrentMediaTime() - started) * 1000
    activeSince.removeValue(forKey: key)
    AppDiagnostics.asyncRecord(
      .info,
      category: "ui.video",
      message: "Inline video first frame ready",
      metadata: [
        "feedItemKey": "\(key.hashValue)",
        "timeToFirstFrameMs": String(format: "%.1f", elapsedMs),
        "playerLoaded": "\(sharedVideo.isPlayerLoaded)"
      ]
    )
  }

  /// Cheap per-frame sink for row visibility. Slow scrolls may elect a mostly visible
  /// video immediately; fast scrolls pause offscreen media but defer new mounts.
  @discardableResult
  func updateVisibilities(_ visibilities: [InlineVideoVisibility]) -> [InlineVideoVisibility] {
    ScrollPerfProbe.shared.bump("inlineCenterUpdate")
    latestVisibilities = visibilities.map { $0.normalized(viewportHeight: viewportHeight) }.sorted { $0.midY < $1.midY }
    updateScrollVelocity(from: latestVisibilities)
    updateVisibleFractions()
    pauseActiveIfNeeded()

    if isScrolling {
      guard !isFastScrolling else { return latestVisibilities }
      electCenteredVideo(updateWarmSet: false)
      return latestVisibilities
    }

    // Only (re)populate the warm set at rest. Mounting paused AVPlayers + AVPlayerLayers
    // mid-scroll (attaching to the player and kicking off HLS asset loading on the main
    // thread) is the main remaining source of fast-scroll hitches. `electCenteredVideo`
    // already warms neighbors when the feed settles, so the next video is still ready by
    // the time you stop — we just stop paying for it during the scroll itself.
    guard !FeedScrollWorkCoordinator.shared.shouldDeferWork else { return latestVisibilities }
    electCenteredVideo()
    return latestVisibilities
  }

  /// Pick the sufficiently visible video nearest the viewport center and make it active.
  /// Called when the feed settles, or while slow scrolling.
  func electCenteredVideo(updateWarmSet: Bool = true) {
    let center = viewportHeight / 2
    let nearest = latestVisibilities
      .filter { $0.visibleFraction >= playVisibleThreshold }
      .min(by: { abs($0.midY - center) < abs($1.midY - center) })?.key
    if let nearest {
      setActive(nearest)
    }
    if updateWarmSet {
      isFastScrolling = false
      updateWarmVideoKeys()
    }
  }

  private func updateScrollVelocity(from visibilities: [InlineVideoVisibility]) {
    guard !visibilities.isEmpty else {
      setFastScrolling(false)
      return
    }

    let meanY = visibilities.reduce(CGFloat.zero) { $0 + $1.midY } / CGFloat(visibilities.count)
    let now = Date.timeIntervalSinceReferenceDate
    defer {
      lastVisibilityMeanY = meanY
      lastVisibilityTimestamp = now
    }

    guard isScrolling, let lastVisibilityMeanY, let lastVisibilityTimestamp else {
      setFastScrolling(false)
      return
    }

    let elapsed = max(now - lastVisibilityTimestamp, 0.001)
    let delta = meanY - lastVisibilityMeanY
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
    guard !forceEmpty, !isFastScrolling, !latestVisibilities.isEmpty else {
      if !warmVideoKeys.isEmpty {
        ScrollPerfProbe.shared.bump("inlineWarmChange")
        warmVideoKeys = []
        updatePlaybackStates()
      }
      return
    }

    let center = viewportHeight / 2
    let ahead = movingTowardLaterPosts
      ? latestVisibilities.filter { $0.midY >= center && $0.key != activeVideoKey }
      : Array(latestVisibilities.filter { $0.midY <= center && $0.key != activeVideoKey }.reversed())
    let nextKeys = Set(ahead.prefix(warmAheadCount).map(\.key))
    if nextKeys != warmVideoKeys {
      ScrollPerfProbe.shared.bump("inlineWarmChange")
      warmVideoKeys = nextKeys
      updatePlaybackStates()
    }
  }

  private func pauseActiveIfNeeded() {
    guard let activeVideoKey else { return }
    guard let visibility = latestVisibilities.first(where: { $0.key == activeVideoKey }) else {
      setActive(nil)
      return
    }
    if visibility.visibleFraction < pauseVisibleThreshold {
      setActive(nil)
    }
  }

  private func updateVisibleFractions() {
    let fractions = Dictionary(uniqueKeysWithValues: latestVisibilities.map { ($0.key, $0.visibleFraction) })
    for state in playbackStates.values {
      let nextFraction = fractions[state.key] ?? 0
      if state.visibleFraction != nextFraction {
        state.visibleFraction = nextFraction
      }
    }
  }

  private func updatePlaybackStates() {
    prunePlaybackStates()
    for state in playbackStates.values {
      applyPlaybackValues(to: state)
    }
  }

  private func applyPlaybackValues(to state: InlineVideoPlaybackState) {
    let shouldPlay = state.key == activeVideoKey
    let shouldMount = shouldPlay || warmVideoKeys.contains(state.key)
    let isPrefetchTarget = prefetchVideoKeys.contains(state.key)
    if state.shouldPlay != shouldPlay { state.shouldPlay = shouldPlay }
    if state.shouldMountPlayer != shouldMount { state.shouldMountPlayer = shouldMount }
    if state.isPrefetchTarget != isPrefetchTarget { state.isPrefetchTarget = isPrefetchTarget }
  }

  private func prunePlaybackStates() {
    guard playbackStates.count > 120 else { return }
    let visible = Set(latestVisibilities.map(\.key))
    let keep = visible.union(warmVideoKeys).union(prefetchVideoKeys).union(activeVideoKey.map { [$0] } ?? [])
    playbackStates = playbackStates.filter { keep.contains($0.key) }
  }

  func latestVisibilitySnapshot() -> [InlineVideoVisibility] {
    latestVisibilities
  }

  func updatePrefetchTargetsFromCurrentWindow(posts: [Post]) {
    MediaPrefetchCoordinator.shared.updateFeedWindow(
      posts: posts,
      visibilities: latestVisibilities,
      movingTowardLaterPosts: movingTowardLaterPosts,
      isFastScrolling: isFastScrolling
    )
  }

  private var activeVisibilityDescription: String {
    guard let activeVideoKey,
          let visibility = latestVisibilities.first(where: { $0.key == activeVideoKey }) else {
      return "nil"
    }
    return String(format: "%.2f", visibility.visibleFraction)
  }

  func diagnosticMetadata() -> [String: String] {
    var metadata = [
      "inlineActive": activeVideoKey.map { "\($0.hashValue)" } ?? "nil",
      "inlineWarmCount": "\(warmVideoKeys.count)",
      "inlinePrefetchCount": "\(prefetchVideoKeys.count)",
      "inlineTrackedStates": "\(playbackStates.count)",
      "inlineVisibilities": "\(latestVisibilities.count)",
      "inlineScrolling": "\(isScrolling)",
      "inlineFastScrolling": "\(isFastScrolling)",
      "inlineViewportHeight": String(format: "%.1f", viewportHeight),
      "inlineLastDeltaY": String(format: "%.1f", lastScrollDeltaY),
      "inlineDirection": movingTowardLaterPosts ? "down" : "up",
      "inlineActiveVisible": activeVisibilityDescription
    ]
    MediaPrefetchCoordinator.shared.diagnosticMetadata().forEach { key, value in
      metadata[key] = value
    }
    return metadata
  }
}

// MARK: - Per-row visibility reporting

/// A feed row's video bounds and visible fraction within the feed coordinate space.
struct InlineVideoVisibility: Equatable {
  let key: String
  let minY: CGFloat
  let maxY: CGFloat
  let viewportHeight: CGFloat
  let visibleFraction: CGFloat

  var midY: CGFloat {
    (minY + maxY) / 2
  }

  func normalized(viewportHeight: CGFloat) -> InlineVideoVisibility {
    let rowHeight = max(maxY - minY, 1)
    let visibleHeight = max(0, min(maxY, viewportHeight) - max(minY, 0))
    let fraction = min(1, max(0, visibleHeight / rowHeight))
    return InlineVideoVisibility(
      key: key,
      minY: minY,
      maxY: maxY,
      viewportHeight: viewportHeight,
      visibleFraction: fraction
    )
  }
}

struct InlineVideoVisibilityPreferenceKey: PreferenceKey {
  static var defaultValue: [InlineVideoVisibility] = []
  static func reduce(value: inout [InlineVideoVisibility], nextValue: () -> [InlineVideoVisibility]) {
    value.append(contentsOf: nextValue())
  }
}

/// Reports a row's vertical visibility so the feed can elect and pause inline video.
/// No-op for non-video rows so image/text feeds pay nothing.
private struct InlineVideoVisibilityTracker: ViewModifier {
  let key: String
  let coordinateSpace: String
  let enabled: Bool

  func body(content: Content) -> some View {
    if enabled {
      content.background(
        GeometryReader { geo in
          let frame = geo.frame(in: .named(coordinateSpace))
          let viewportHeight = InlineVideoCoordinator.shared.viewportHeight
          let visibility = InlineVideoVisibility(
            key: key,
            minY: frame.minY,
            maxY: frame.maxY,
            viewportHeight: viewportHeight,
            visibleFraction: 0
          ).normalized(viewportHeight: viewportHeight)
          Color.clear.preference(
            key: InlineVideoVisibilityPreferenceKey.self,
            value: [visibility]
          )
        }
      )
    } else {
      content
    }
  }
}

extension View {
  /// Track this row's visibility for single-active-video election. `enabled` should be true
  /// only for rows that contain an inline video (see `MediaExtractedType.isInlineVideo`).
  func trackInlineVideoCenter(key: String, coordinateSpace: String, enabled: Bool) -> some View {
    modifier(InlineVideoVisibilityTracker(key: key, coordinateSpace: coordinateSpace, enabled: enabled))
  }

  /// Drive the coordinator from a scrollable feed: report scroll phase (for deferring
  /// expensive work) and elect the centered video when the feed settles. Slow scrolls
  /// can also elect from center updates; fast scrolls wait.
  func driveInlineVideoCoordinator(coordinateSpace: String, posts: [Post] = []) -> some View {
    self
      .modifier(FeedScrollCoordinatorDriver(coordinateSpace: coordinateSpace, posts: posts))
  }
}

private struct FeedScrollCoordinatorDriver: ViewModifier {
  @Environment(\.scenePhase) private var scenePhase
  let coordinateSpace: String
  let posts: [Post]

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
            InlineVideoCoordinator.shared.updatePrefetchTargetsFromCurrentWindow(posts: posts)
          }
        }
      }
      .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, newHeight in
        if newHeight > 0 { InlineVideoCoordinator.shared.viewportHeight = newHeight }
      }
      .onPreferenceChange(InlineVideoVisibilityPreferenceKey.self) { visibilities in
        let normalized = InlineVideoCoordinator.shared.updateVisibilities(visibilities)
        MediaPrefetchCoordinator.shared.updateFeedWindow(
          posts: posts,
          visibilities: normalized,
          movingTowardLaterPosts: InlineVideoCoordinator.shared.movingTowardLaterPosts,
          isFastScrolling: InlineVideoCoordinator.shared.isFastScrolling
        )
        guard !InlineVideoCoordinator.shared.isScrolling else { return }
        FeedScrollWorkCoordinator.shared.performWhenIdle(key: "inlineVideo.elect.\(coordinateSpace)") {
          InlineVideoCoordinator.shared.electCenteredVideo()
          InlineVideoCoordinator.shared.updatePrefetchTargetsFromCurrentWindow(posts: posts)
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
