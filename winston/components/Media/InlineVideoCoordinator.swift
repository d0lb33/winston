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
import Defaults
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
  private(set) var isMediaReturnTransitionActive = false

  private var idleWorkItem: DispatchWorkItem?
  private var seenBatchWorkItem: DispatchWorkItem?
  private var scheduledWorkItems: [String: DispatchWorkItem] = [:]
  private var pendingWork: [String: () -> Void] = [:]
  private var pendingSeenPosts: [String: Post] = [:]

  var shouldDeferWork: Bool { isScrolling || isSettling || isMediaReturnTransitionActive }

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

  func beginMediaReturnTransition() {
    isMediaReturnTransitionActive = true
    idleWorkItem?.cancel()
    idleWorkItem = nil
    seenBatchWorkItem?.cancel()
    seenBatchWorkItem = nil
    cancelScheduledWorkItems()
  }

  func endMediaReturnTransition() {
    guard isMediaReturnTransitionActive else { return }
    isMediaReturnTransitionActive = false
    isScrolling = false
    isSettling = true
    scheduleIdleFlush(delay: 0)
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
  var hostHasFrame = false
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
  private var deferredScrollUpdates = 0
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

    if FeedScrollWorkCoordinator.shared.shouldDeferWork {
      deferredScrollUpdates += 1
      ScrollPerfProbe.shared.bump("mediaPrefetch.deferred")
      ScrollPerfProbe.shared.bump("mediaPrefetch.deferred.\(lastDirection)")
      FeedScrollWorkCoordinator.shared.performWhenIdle(key: "mediaPrefetch.window") { [weak self, window] in
        guard let self else { return }
        self.startImagePrefetch(for: window)
        self.startVideoPrewarm(for: window, limit: policy.videoAheadCount, maxConcurrent: policy.maxVideoConcurrency)
      }
      return
    }

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
      "mediaPrefetchDeferredScrollUpdates": "\(deferredScrollUpdates)",
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
      return (4, 1, 1)
    }
    if pathIsExpensive {
      return (6, 1, 1)
    }
    return (8, 2, 1)
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
  /// The active media surface, in the feed coordinate space. Kept for diagnostics and
  /// for the legacy reusable host path; the active feed video is now rendered by a
  /// row-local host so it composites naturally with SwiftUI navigation chrome.
  private(set) var activeSurface: InlineVideoSurfaceSnapshot?
  /// Non-nil while fullscreen owns the active player's visual surface.
  private(set) var fullscreenVideoKey: String?
  /// Non-nil while SwiftUI's zoom transition is returning fullscreen media to a feed source.
  private(set) var returnTransitionSourceID: String?
  private(set) var isReturnTransitionActive = false
  /// Bumped when passive row registrations change. The registrations dictionary is ignored
  /// for observation because it can hold player resources, so the host observes this token.
  private(set) var registrationGeneration = 0

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
  @ObservationIgnored private var latestVisibilityByKey: [String: InlineVideoVisibility] = [:]
  @ObservationIgnored var viewportHeight: CGFloat = 1
  @ObservationIgnored var viewportFrameGlobal: CGRect = .zero
  @ObservationIgnored private var lastScrollOffsetY: CGFloat?
  @ObservationIgnored private var lastScrollOffsetTimestamp: TimeInterval?
  @ObservationIgnored private var lastScrollDeltaY: CGFloat = 0
  @ObservationIgnored private var playbackStates: [String: InlineVideoPlaybackState] = [:]
  @ObservationIgnored private var prefetchVideoKeys: Set<String> = []
  @ObservationIgnored private var activeSince: [String: CFTimeInterval] = [:]
  @ObservationIgnored private var attachStartedAt: [String: CFTimeInterval] = [:]
  @ObservationIgnored private var attachCompletedAt: [String: CFTimeInterval] = [:]
  @ObservationIgnored private var lastActiveChangeTime: CFTimeInterval = 0
  @ObservationIgnored private var registeredVideos: [String: InlineVideoRegistration] = [:]
  @ObservationIgnored private var navigationPreservedKeys: Set<String> = []
  @ObservationIgnored private var returnTransitionTask: Task<Void, Never>?

  private let warmAheadCount = 1
  private let fastScrollVelocityThreshold: CGFloat = 2_200
  private let playVisibleThreshold: CGFloat = 0.18
  private let pauseVisibleThreshold: CGFloat = 0.04
  private let activeSwitchVisibleFloor: CGFloat = 0.14
  private let activeSwitchMinImprovement: CGFloat = 96
  private let activeSwitchMinimumDwell: CFTimeInterval = 0.28
  private let firstFrameDiagnosticThresholdMs: Double = 300

  private init() {}

  var movingTowardLaterPosts: Bool {
    lastScrollDeltaY >= 0
  }

  func state(for key: String) -> InlineVideoPlaybackState {
    if let existing = playbackStates[key] { return existing }
    let state = InlineVideoPlaybackState(key: key)
    playbackStates[key] = state
    applyPlaybackValues(to: state)
    return state
  }

  func registerVideo(
    _ sharedVideo: SharedVideo,
    for key: String,
    blurNSFW: Bool,
    smallNSFWIcon: Bool,
    cornerRadius: CGFloat
  ) {
    let nextRegistration = InlineVideoRegistration(
      sharedVideo: sharedVideo,
      blurNSFW: blurNSFW,
      smallNSFWIcon: smallNSFWIcon,
      cornerRadius: cornerRadius
    )
    guard registeredVideos[key] != nextRegistration else { return }
    registeredVideos[key] = nextRegistration
    registrationGeneration += 1
  }

  func unregisterVideo(for key: String, sharedVideo: SharedVideo) {
    guard registeredVideos[key]?.sharedVideo === sharedVideo else { return }
    registeredVideos.removeValue(forKey: key)
    registrationGeneration += 1
    if activeVideoKey == key {
      setActive(nil)
    }
  }

  func registeredVideo(for key: String) -> InlineVideoRegistration? {
    registeredVideos[key]
  }

  func isRegisteredVideo(_ sharedVideo: SharedVideo) -> Bool {
    registeredVideos.values.contains { $0.sharedVideo === sharedVideo }
  }

  func setFullscreenOwner(_ key: String?, active: Bool) {
    let nextKey = active ? key : nil
    guard fullscreenVideoKey != nextKey else { return }
    fullscreenVideoKey = nextKey
  }

  func beginReturnTransition(sourceID: String?, duration: TimeInterval = 0.6) {
    guard let sourceID, !sourceID.isEmpty else { return }
    returnTransitionTask?.cancel()
    FeedScrollWorkCoordinator.shared.beginMediaReturnTransition()
    isScrolling = false
    isFastScrolling = false
    returnTransitionSourceID = sourceID
    isReturnTransitionActive = true
    if fullscreenVideoKey == nil, registeredVideos[sourceID] != nil {
      fullscreenVideoKey = sourceID
    }
    returnTransitionTask = Task { @MainActor [weak self] in
      let nanos = UInt64(max(duration, 0.1) * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanos)
      self?.endReturnTransition(sourceID: sourceID)
    }
  }

  func endReturnTransition(sourceID: String? = nil) {
    if let sourceID, returnTransitionSourceID != sourceID { return }
    returnTransitionTask?.cancel()
    returnTransitionTask = nil
    let endingSourceID = returnTransitionSourceID
    returnTransitionSourceID = nil
    isReturnTransitionActive = false
    if fullscreenVideoKey == endingSourceID {
      fullscreenVideoKey = nil
    }
    FeedScrollWorkCoordinator.shared.endMediaReturnTransition()
    processLatestVisibilities()
    updatePlaybackStates()
  }

  func preservePlaybackForNonScrollDisappearance(key: String) {
    guard activeVideoKey == key, !isScrolling else { return }
    navigationPreservedKeys.insert(key)
  }

  func consumeNavigationPreservation(for key: String) -> Bool {
    navigationPreservedKeys.remove(key) != nil
  }

  func shouldPreservePlaybackOnLayerDetach(key: String) -> Bool {
    fullscreenVideoKey == key ||
      returnTransitionSourceID == key ||
      consumeNavigationPreservation(for: key) ||
      (activeVideoKey == key && !isScrolling)
  }

  func setActive(_ key: String?) {
    guard key != activeVideoKey else { return }
    if let activeVideoKey, let state = playbackStates[activeVideoKey], state.hostHasFrame {
      state.hostHasFrame = false
    }
    ScrollPerfProbe.shared.bump("inlineActiveChange")
    activeVideoKey = key
    lastActiveChangeTime = CACurrentMediaTime()
    if let key {
      activeSince[key] = CACurrentMediaTime()
      if let state = playbackStates[key], state.hostHasFrame {
        state.hostHasFrame = false
      }
    }
    updateActiveSurface()
    updatePlaybackStates()
  }

  private func clearActiveVideo() {
    setActive(nil)
    electCenteredVideo(updateWarmSet: false, force: true)
  }

  func setHostHasFrame(_ hasFrame: Bool, for key: String) {
    let state = self.state(for: key)
    if state.hostHasFrame != hasFrame {
      state.hostHasFrame = hasFrame
    }
  }

  func setScrolling(_ scrolling: Bool) {
    guard !isReturnTransitionActive else { return }
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
    let now = CACurrentMediaTime()
    let elapsedMs = (CACurrentMediaTime() - started) * 1000
    let attachStartedElapsedMs = attachStartedAt[key].map { (now - $0) * 1000 }
    let attachCompletedElapsedMs = attachCompletedAt[key].map { (now - $0) * 1000 }
    activeSince.removeValue(forKey: key)
    attachStartedAt.removeValue(forKey: key)
    attachCompletedAt.removeValue(forKey: key)
    guard elapsedMs >= firstFrameDiagnosticThresholdMs else { return }
    let level: DiagnosticLevel = elapsedMs >= 500 ? .warning : .info
    AppDiagnostics.asyncRecord(
      level,
      category: "ui.video",
      message: "Inline video first frame ready",
      metadata: inlineStageMetadata(
        key: key,
        sharedVideo: sharedVideo,
        player: sharedVideo.isPlayerLoaded ? sharedVideo.player : nil,
        extra: [
          "timeToFirstFrameMs": String(format: "%.1f", elapsedMs),
          "attachStartedToFirstFrameMs": attachStartedElapsedMs.map { String(format: "%.1f", $0) } ?? "nil",
          "attachCompletedToFirstFrameMs": attachCompletedElapsedMs.map { String(format: "%.1f", $0) } ?? "nil"
        ]
      )
    )
  }

  func recordInlineAttachStarted(key: String) {
    attachStartedAt[key] = CACurrentMediaTime()
  }

  func recordInlineAttachCompleted(
    key: String,
    sharedVideo: SharedVideo,
    player: AVPlayer,
    wasPlayerLoaded: Bool,
    attachElapsedMs: Double
  ) {
    attachCompletedAt[key] = CACurrentMediaTime()
    guard attachElapsedMs >= 50 else { return }
    AppDiagnostics.asyncRecord(
      .warning,
      category: "ui.video",
      message: "Inline playback attach completed",
      metadata: inlineStageMetadata(
        key: key,
        sharedVideo: sharedVideo,
        player: player,
        extra: [
          "playerLoadedBeforeAttach": "\(wasPlayerLoaded)",
          "attachElapsedMs": String(format: "%.1f", attachElapsedMs)
        ]
      )
    )
  }

  func recordInlineFirstFrameStillWaiting(key: String, sharedVideo: SharedVideo) {
    guard activeVideoKey == key, activeSince[key] != nil else { return }
    AppDiagnostics.asyncRecord(
      .warning,
      category: "ui.video",
      message: "Inline video first frame still waiting",
      metadata: inlineStageMetadata(
        key: key,
        sharedVideo: sharedVideo,
        player: sharedVideo.isPlayerLoaded ? sharedVideo.player : nil
      )
    )
  }

  private func inlineStageMetadata(
    key: String,
    sharedVideo: SharedVideo,
    player: AVPlayer?,
    extra: [String: String] = [:]
  ) -> [String: String] {
    let cacheKey = SharedVideo.cacheKey(
      url: sharedVideo.url,
      size: sharedVideo.size,
      downloadURL: sharedVideo.downloadURL,
      posterURL: sharedVideo.posterURL
    )
    let now = CACurrentMediaTime()
    var metadata: [String: String] = [
      "feedItemKey": "\(key.hashValue)",
      "cacheKeyHash": "\(cacheKey.hashValue)",
      "urlHash": "\(sharedVideo.url.absoluteString.hashValue)",
      "downloadURLHash": sharedVideo.downloadURL.map { "\($0.absoluteString.hashValue)" } ?? "nil",
      "posterURLHash": sharedVideo.posterURL.map { "\($0.absoluteString.hashValue)" } ?? "nil",
      "videoSize": "\(sharedVideo.size.width)x\(sharedVideo.size.height)",
      "playerLoaded": "\(sharedVideo.isPlayerLoaded)",
      "activeElapsedMs": activeSince[key].map { String(format: "%.1f", (now - $0) * 1000) } ?? "nil",
      "attachStartedElapsedMs": attachStartedAt[key].map { String(format: "%.1f", (now - $0) * 1000) } ?? "nil",
      "attachCompletedElapsedMs": attachCompletedAt[key].map { String(format: "%.1f", (now - $0) * 1000) } ?? "nil",
      "isActive": "\(activeVideoKey == key)",
      "isScrolling": "\(isScrolling)",
      "isFastScrolling": "\(isFastScrolling)",
      "activeVisible": activeVisibilityDescription,
      "visibleCount": "\(latestVisibilities.count)",
      "registeredCount": "\(registeredVideos.count)"
    ]
    metadata.merge(
      AVPlayerRepresentable.playerViewMetadata(player: player, view: nil)
    ) { _, new in new }
    metadata.merge(extra) { _, new in new }
    return metadata
  }

  /// Cheap per-frame sink for row visibility. Any actually visible video is eligible;
  /// when multiple videos are visible, the one nearest the viewport center plays.
  @discardableResult
  func updateVisibilities(_ visibilities: [InlineVideoVisibility]) -> [InlineVideoVisibility] {
    latestVisibilityByKey = Dictionary(
      visibilities.map { normalizedVisibility($0) }.map { ($0.key, $0) },
      uniquingKeysWith: { _, newest in newest }
    )
    return processLatestVisibilities()
  }

  @discardableResult
  func updateVisibility(_ visibility: InlineVideoVisibility) -> [InlineVideoVisibility] {
    latestVisibilityByKey[visibility.key] = normalizedVisibility(visibility)
    return processLatestVisibilities()
  }

  @discardableResult
  func removeVisibility(for key: String) -> [InlineVideoVisibility] {
    latestVisibilityByKey.removeValue(forKey: key)
    return processLatestVisibilities()
  }

  func updateScrollOffset(_ offsetY: CGFloat) {
    guard !isReturnTransitionActive else { return }
    let now = Date.timeIntervalSinceReferenceDate
    defer {
      lastScrollOffsetY = offsetY
      lastScrollOffsetTimestamp = now
    }

    guard isScrolling, let lastScrollOffsetY, let lastScrollOffsetTimestamp else {
      setFastScrolling(false)
      return
    }

    let elapsed = max(now - lastScrollOffsetTimestamp, 0.001)
    let delta = offsetY - lastScrollOffsetY
    lastScrollDeltaY = delta
    setFastScrolling(abs(delta) / elapsed > fastScrollVelocityThreshold)
  }

  private func normalizedVisibility(_ visibility: InlineVideoVisibility) -> InlineVideoVisibility {
    visibility.normalized(viewportHeight: viewportHeight)
  }

  private func processLatestVisibilities() -> [InlineVideoVisibility] {
    ScrollPerfProbe.shared.bump("inlineCenterUpdate")
    latestVisibilities = latestVisibilityByKey.values.sorted { $0.midY < $1.midY }
    guard !isReturnTransitionActive else { return latestVisibilities }
    updateVisibleFractions()
    pauseActiveIfNeeded()
    updateActiveSurface()

    if isScrolling {
      // During a fast fling, do not start MediaToolbox work for each card that briefly
      // crosses center. Keep the current active video until it leaves; elect the next one
      // when scrolling slows or settles.
      if !isFastScrolling || activeVideoKey == nil {
        electCenteredVideo(updateWarmSet: false)
      }
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
  func electCenteredVideo(updateWarmSet: Bool = true, force: Bool = false) {
    let center = viewportFrameGlobal == .zero ? viewportHeight / 2 : viewportFrameGlobal.midY
    let nearestCandidate = latestVisibilities
      .filter { $0.visibleFraction >= playVisibleThreshold }
      .min(by: { abs($0.midY - center) < abs($1.midY - center) })
    guard let nearest = nearestCandidate else {
      if updateWarmSet {
        isFastScrolling = false
        updateWarmVideoKeys()
      }
      return
    }

    if force || shouldSwitchActiveVideo(to: nearest, viewportCenter: center) {
      setActive(nearest.key)
    }
    if updateWarmSet {
      isFastScrolling = false
      updateWarmVideoKeys()
    }
  }

  private func shouldSwitchActiveVideo(
    to candidate: InlineVideoVisibility,
    viewportCenter center: CGFloat
  ) -> Bool {
    guard let activeVideoKey else { return true }
    guard candidate.key != activeVideoKey else { return false }
    guard let activeVisibility = latestVisibilityByKey[activeVideoKey] else { return true }
    guard activeVisibility.visibleFraction >= pauseVisibleThreshold else { return true }

    let activeDistance = abs(activeVisibility.midY - center)
    let candidateDistance = abs(candidate.midY - center)
    if activeVisibility.visibleFraction >= activeSwitchVisibleFloor,
       activeDistance <= candidateDistance + activeSwitchMinImprovement {
      return false
    }

    let elapsed = CACurrentMediaTime() - lastActiveChangeTime
    if elapsed < activeSwitchMinimumDwell,
       activeVisibility.visibleFraction >= pauseVisibleThreshold {
      return false
    }

    return true
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

    let center = viewportFrameGlobal == .zero ? viewportHeight / 2 : viewportFrameGlobal.midY
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
    guard !isReturnTransitionActive else { return }
    guard let activeVideoKey else { return }
    guard let visibility = latestVisibilities.first(where: { $0.key == activeVideoKey }) else {
      clearActiveVideo()
      return
    }
    if visibility.visibleFraction < pauseVisibleThreshold {
      clearActiveVideo()
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

  private func updateActiveSurface() {
    guard !isReturnTransitionActive else { return }
    guard let activeVideoKey,
          let visibility = latestVisibilityByKey[activeVideoKey],
          visibility.visibleFraction >= pauseVisibleThreshold else {
      if activeSurface != nil {
        ScrollPerfProbe.shared.bump("inlineHostDetach")
        activeSurface = nil
      }
      return
    }

    let nextSurface = InlineVideoSurfaceSnapshot(visibility: visibility)
    if activeSurface?.key != nextSurface.key {
      ScrollPerfProbe.shared.bump("inlineHostAttach")
    } else if activeSurface != nextSurface {
      ScrollPerfProbe.shared.bump("inlineHostMove")
    }
    if activeSurface != nextSurface {
      activeSurface = nextSurface
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
      "inlineReturnActive": "\(isReturnTransitionActive)",
      "inlineReturnSource": returnTransitionSourceID.map { "\($0.hashValue)" } ?? "nil",
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
  let minX: CGFloat
  let maxX: CGFloat
  let minY: CGFloat
  let maxY: CGFloat
  let viewportHeight: CGFloat
  let viewportMinY: CGFloat
  let viewportMaxY: CGFloat
  let visibleFraction: CGFloat

  var width: CGFloat {
    max(maxX - minX, 1)
  }

  var height: CGFloat {
    max(maxY - minY, 1)
  }

  var midX: CGFloat {
    (minX + maxX) / 2
  }

  var midY: CGFloat {
    (minY + maxY) / 2
  }

  func normalized(viewportHeight: CGFloat) -> InlineVideoVisibility {
    let rowHeight = max(maxY - minY, 1)
    let viewportMinY = viewportMinY
    let viewportMaxY = viewportMaxY > viewportMinY ? viewportMaxY : viewportHeight
    let visibleHeight = max(0, min(maxY, viewportMaxY) - max(minY, viewportMinY))
    let fraction = min(1, max(0, visibleHeight / rowHeight))
    return InlineVideoVisibility(
      key: key,
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      viewportHeight: viewportHeight,
      viewportMinY: viewportMinY,
      viewportMaxY: viewportMaxY,
      visibleFraction: fraction
    )
  }
}

struct InlineVideoSurfaceSnapshot: Equatable {
  let key: String
  let minX: CGFloat
  let maxX: CGFloat
  let minY: CGFloat
  let maxY: CGFloat
  let visibleFraction: CGFloat

  var width: CGFloat { max(maxX - minX, 1) }
  var height: CGFloat { max(maxY - minY, 1) }
  var midX: CGFloat { (minX + maxX) / 2 }
  var midY: CGFloat { (minY + maxY) / 2 }

  init(visibility: InlineVideoVisibility) {
    self.key = visibility.key
    self.minX = visibility.minX
    self.maxX = visibility.maxX
    self.minY = visibility.minY
    self.maxY = visibility.maxY
    self.visibleFraction = visibility.visibleFraction
  }
}

struct InlineVideoRegistration: Equatable {
  let sharedVideo: SharedVideo
  let blurNSFW: Bool
  let smallNSFWIcon: Bool
  let cornerRadius: CGFloat

  static func == (lhs: InlineVideoRegistration, rhs: InlineVideoRegistration) -> Bool {
    lhs.sharedVideo === rhs.sharedVideo &&
      lhs.blurNSFW == rhs.blurNSFW &&
      lhs.smallNSFWIcon == rhs.smallNSFWIcon &&
      lhs.cornerRadius == rhs.cornerRadius
  }
}

private struct InlineVideoFrameSnapshot: Equatable {
  let minX: CGFloat
  let maxX: CGFloat
  let minY: CGFloat
  let maxY: CGFloat
}

/// Reports a row's vertical visibility so the feed can elect and pause inline video.
/// No-op for non-video rows so image/text feeds pay nothing.
private struct InlineVideoVisibilityTracker: ViewModifier {
  let key: String
  let coordinateSpace: String
  let enabled: Bool

  func body(content: Content) -> some View {
    if enabled {
      content
        .onGeometryChange(for: InlineVideoFrameSnapshot.self) { geo in
          let frame = geo.frame(in: .global)
          return InlineVideoFrameSnapshot(
            minX: frame.minX,
            maxX: frame.maxX,
            minY: frame.minY,
            maxY: frame.maxY
          )
        } action: { frame in
          let coordinator = InlineVideoCoordinator.shared
          let viewport = coordinator.viewportFrameGlobal
          let viewportHeight = max(viewport.height, coordinator.viewportHeight)
          guard viewportHeight > 1 else { return }
          let visibility = InlineVideoVisibility(
            key: key,
            minX: frame.minX,
            maxX: frame.maxX,
            minY: frame.minY,
            maxY: frame.maxY,
            viewportHeight: viewportHeight,
            viewportMinY: viewport.minY,
            viewportMaxY: viewport.maxY,
            visibleFraction: 0
          ).normalized(viewportHeight: viewportHeight)
          coordinator.updateVisibility(visibility)
        }
        .onDisappear {
          InlineVideoCoordinator.shared.preservePlaybackForNonScrollDisappearance(key: key)
          InlineVideoCoordinator.shared.removeVisibility(for: key)
        }
    } else {
      content
    }
  }
}

private struct InlineVideoCoordinateSpaceKey: EnvironmentKey {
  static let defaultValue: String? = nil
}

extension EnvironmentValues {
  var inlineVideoCoordinateSpace: String? {
    get { self[InlineVideoCoordinateSpaceKey.self] }
    set { self[InlineVideoCoordinateSpaceKey.self] = newValue }
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
      .environment(\.inlineVideoCoordinateSpace, coordinateSpace)
      .coordinateSpace(.named(coordinateSpace))
      .scrollDisabled(InlineVideoCoordinator.shared.isReturnTransitionActive)
      .allowsHitTesting(!InlineVideoCoordinator.shared.isReturnTransitionActive)
      .onGeometryChange(for: CGRect.self) { geometry in
        geometry.frame(in: .global)
      } action: { _, frame in
        InlineVideoCoordinator.shared.viewportFrameGlobal = frame
        if frame.height > 0 {
          InlineVideoCoordinator.shared.viewportHeight = frame.height
        }
      }
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
      .onScrollGeometryChange(for: FeedScrollGeometrySnapshot.self) { geometry in
        FeedScrollGeometrySnapshot(
          viewportHeight: geometry.containerSize.height,
          offsetY: geometry.contentOffset.y
        )
      } action: { _, snapshot in
        if snapshot.viewportHeight > 0 {
          InlineVideoCoordinator.shared.viewportHeight = snapshot.viewportHeight
        }
        InlineVideoCoordinator.shared.updateScrollOffset(snapshot.offsetY)
        InlineVideoCoordinator.shared.updatePrefetchTargetsFromCurrentWindow(posts: posts)
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

@MainActor
private final class InlinePlaybackResourceController {
  static let shared = InlinePlaybackResourceController()

  private var attachedVideos: [String: SharedVideo] = [:]
  private var loopObservers: [String: NSObjectProtocol] = [:]

  private init() {}

  func attach(key: String, video: SharedVideo, muted: Bool, loop: Bool, autoplay: Bool) -> AVPlayer {
    let attachStarted = CACurrentMediaTime()
    let wasPlayerLoaded = video.isPlayerLoaded
    InlineVideoCoordinator.shared.recordInlineAttachStarted(key: key)

    if let existingVideo = attachedVideos[key], existingVideo !== video {
      detach(key: key)
    }

    if attachedVideos[key] == nil {
      ScrollPerfProbe.shared.bump("inlineResourceCreate")
      attachedVideos[key] = video
    } else {
      ScrollPerfProbe.shared.bump("inlineResourceReuse")
    }

    let player = video.player
    applyPlaybackConfiguration(player: player, key: key, muted: muted, loop: loop, autoplay: autoplay)

    InlineVideoCoordinator.shared.recordInlineAttachCompleted(
      key: key,
      sharedVideo: video,
      player: player,
      wasPlayerLoaded: wasPlayerLoaded,
      attachElapsedMs: (CACurrentMediaTime() - attachStarted) * 1000
    )
    doThisAfter(0.5) {
      InlineVideoCoordinator.shared.recordInlineFirstFrameStillWaiting(key: key, sharedVideo: video)
    }
    return player
  }

  func updatePlayback(key: String, muted: Bool, loop: Bool, autoplay: Bool) {
    guard let video = attachedVideos[key], video.isPlayerLoaded else { return }
    applyPlaybackConfiguration(player: video.player, key: key, muted: muted, loop: loop, autoplay: autoplay)
  }

  private func applyPlaybackConfiguration(player: AVPlayer, key: String, muted: Bool, loop: Bool, autoplay: Bool) {
    player.isMuted = muted
    player.volume = muted ? 0 : 1
    player.currentItem?.preferredForwardBufferDuration = 2
    configureLooping(player: player, key: key, enabled: loop)

    if autoplay {
      if loop, restartLoopingPlaybackIfEnded(player) {
        return
      }
      player.play()
    } else {
      player.pause()
    }
  }

  func detach(key: String? = nil, preservePlayback: Bool = false) {
    guard let key else {
      for key in Array(attachedVideos.keys) {
        detach(key: key, preservePlayback: preservePlayback)
      }
      return
    }
    guard let video = attachedVideos[key] else { return }
    if preservePlayback {
      return
    }
    if video.isPlayerLoaded {
      video.player.pause()
      ScrollPerfProbe.shared.bump("inlineResourcePause")
    }
    attachedVideos.removeValue(forKey: key)
    removeLoopObserver(for: key)
  }

  private func configureLooping(player: AVPlayer, key: String, enabled: Bool) {
    removeLoopObserver(for: key)
    guard enabled, let item = player.currentItem else { return }
    loopObservers[key] = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification,
      object: item,
      queue: .main
    ) { [weak player] _ in
      player?.seek(to: .zero)
      player?.play()
    }
  }

  private func removeLoopObserver(for key: String) {
    if let loopObserver = loopObservers.removeValue(forKey: key) {
      NotificationCenter.default.removeObserver(loopObserver)
    }
  }

  private func restartLoopingPlaybackIfEnded(_ player: AVPlayer) -> Bool {
    guard let item = player.currentItem else { return false }
    let duration = CMTimeGetSeconds(item.duration)
    let currentTime = CMTimeGetSeconds(player.currentTime())
    guard duration.isFinite, currentTime.isFinite, duration > 0 else { return false }
    guard currentTime >= duration - 0.08 else { return false }

    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
      guard finished else { return }
      DispatchQueue.main.async {
        player.play()
      }
    }
    return true
  }
}

struct InlineRowPlaybackLayerHost: View {
  let key: String
  let sharedVideo: SharedVideo
  let shouldMount: Bool
  let muted: Bool
  let loop: Bool
  let autoplay: Bool
  let cornerRadius: CGFloat
  let size: CGSize
  var onReadyForDisplay: (() -> Void)?

  @State private var player: AVPlayer?
  @State private var attachedKey: String?
  @State private var readyForDisplay = false
  @State private var attachGeneration = UUID()
  @State private var attachTask: Task<Void, Never>?

  private var attachmentID: String {
    [
      key,
      sharedVideo.url.absoluteString,
      sharedVideo.downloadURL?.absoluteString ?? "",
      sharedVideo.posterURL?.absoluteString ?? "",
      "\(sharedVideo.size.width)x\(sharedVideo.size.height)",
      "\(shouldMount)"
    ].joined(separator: "|")
  }

  private var playbackConfigurationID: String {
    [
      "\(muted)",
      "\(loop)",
      "\(autoplay)"
    ].joined(separator: "|")
  }

  var body: some View {
    ReusableInlineAVPlayerLayerRepresentable(
      player: player,
      videoGravity: .resizeAspectFill,
      cornerRadius: cornerRadius,
      diagnosticPrefix: "inlineRowHost",
      onReadyForDisplay: {
        guard attachedKey == key else { return }
        readyForDisplay = true
        InlineVideoCoordinator.shared.setHostHasFrame(true, for: key)
        InlineVideoCoordinator.shared.recordFirstFrameReady(key: key, sharedVideo: sharedVideo)
        onReadyForDisplay?()
      }
    )
    .frame(width: size.width, height: size.height)
    .opacity(readyForDisplay && shouldMount ? 1 : 0)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .allowsHitTesting(false)
    .onAppear {
      scheduleAttachment()
    }
    .onChange(of: attachmentID) { _, _ in
      scheduleAttachment()
    }
    .onChange(of: playbackConfigurationID) { _, _ in
      updatePlaybackConfiguration()
    }
    .onDisappear {
      detachAttached()
    }
  }

  private func scheduleAttachment() {
    attachTask?.cancel()
    let generation = UUID()
    attachGeneration = generation
    readyForDisplay = false
    if let attachedKey {
      InlineVideoCoordinator.shared.setHostHasFrame(false, for: attachedKey)
    }

    guard shouldMount else {
      detachAttached()
      return
    }

    ScrollPerfProbe.shared.bump("inlineRowHost.playerSwapScheduled")
    attachTask = Task { @MainActor in
      await Task.yield()
      guard !Task.isCancelled, attachGeneration == generation else { return }
      let attachedPlayer = InlinePlaybackResourceController.shared.attach(
        key: key,
        video: sharedVideo,
        muted: muted,
        loop: loop,
        autoplay: autoplay
      )
      guard !Task.isCancelled, attachGeneration == generation else { return }
      attachedKey = key
      player = attachedPlayer
      ScrollPerfProbe.shared.bump("inlineRowHost.playerSwap")
    }
  }

  private func updatePlaybackConfiguration() {
    guard shouldMount, attachedKey == key else { return }
    InlinePlaybackResourceController.shared.updatePlayback(
      key: key,
      muted: muted,
      loop: loop,
      autoplay: autoplay
    )
  }

  private func detachAttached() {
    attachTask?.cancel()
    attachTask = nil
    attachGeneration = UUID()
    readyForDisplay = false
    guard let attachedKey else {
      player = nil
      return
    }
    InlineVideoCoordinator.shared.setHostHasFrame(false, for: attachedKey)
    InlinePlaybackResourceController.shared.detach(
      key: attachedKey,
      preservePlayback: InlineVideoCoordinator.shared.shouldPreservePlaybackOnLayerDetach(key: attachedKey)
    )
    self.attachedKey = nil
    player = nil
  }
}

struct InlinePlaybackHost: View {
  @Environment(\.videoDefSettings) private var videoDefSettings
  private let coordinator = InlineVideoCoordinator.shared

  var body: some View {
    let _ = coordinator.registrationGeneration
    if videoDefSettings.autoPlay, coordinator.fullscreenVideoKey == nil {
      InlinePlaybackLayerContainer(renderState: renderState)
    }
  }

  private var renderState: InlinePlaybackRenderState? {
    guard let surface = coordinator.activeSurface,
          let registration = coordinator.registeredVideo(for: surface.key) else {
      return nil
    }
    return InlinePlaybackRenderState(
      key: surface.key,
      surface: surface,
      sharedVideo: registration.sharedVideo,
      blurNSFW: registration.blurNSFW,
      smallNSFWIcon: registration.smallNSFWIcon,
      cornerRadius: registration.cornerRadius,
      muted: videoDefSettings.mute,
      loop: videoDefSettings.loop,
      autoplay: videoDefSettings.autoPlay
    )
  }
}

private struct InlinePlaybackRenderState: Equatable {
  let key: String
  let surface: InlineVideoSurfaceSnapshot
  let sharedVideo: SharedVideo
  let blurNSFW: Bool
  let smallNSFWIcon: Bool
  let cornerRadius: CGFloat
  let muted: Bool
  let loop: Bool
  let autoplay: Bool

  var attachmentID: String {
    [
      key,
      sharedVideo.url.absoluteString,
      sharedVideo.downloadURL?.absoluteString ?? "",
      sharedVideo.posterURL?.absoluteString ?? "",
      "\(sharedVideo.size.width)x\(sharedVideo.size.height)"
    ].joined(separator: "|")
  }

  var playbackConfigurationID: String {
    [
      "\(muted)",
      "\(loop)",
      "\(autoplay)"
    ].joined(separator: "|")
  }

  static func == (lhs: InlinePlaybackRenderState, rhs: InlinePlaybackRenderState) -> Bool {
    lhs.key == rhs.key &&
      lhs.surface == rhs.surface &&
      lhs.sharedVideo == rhs.sharedVideo &&
      lhs.blurNSFW == rhs.blurNSFW &&
      lhs.smallNSFWIcon == rhs.smallNSFWIcon &&
      lhs.cornerRadius == rhs.cornerRadius &&
      lhs.muted == rhs.muted &&
      lhs.loop == rhs.loop &&
      lhs.autoplay == rhs.autoplay
  }
}

private struct InlinePlaybackLayerContainer: View {
  let renderState: InlinePlaybackRenderState?
  @State private var player: AVPlayer?
  @State private var attachedKey: String?
  @State private var readyForDisplay = false
  @State private var attachGeneration = UUID()
  @State private var attachTask: Task<Void, Never>?

  var body: some View {
    GeometryReader { proxy in
      let overlayFrame = proxy.frame(in: .global)
      let surface = renderState?.surface
      let width = surface?.width ?? 1
      let height = surface?.height ?? 1
      let cornerRadius = renderState?.cornerRadius ?? 0
      let localMidX = surface.map { $0.midX - overlayFrame.minX } ?? -10_000
      let localMidY = surface.map { $0.midY - overlayFrame.minY } ?? -10_000

      ReusableInlineAVPlayerLayerRepresentable(
        player: player,
        videoGravity: .resizeAspectFill,
        cornerRadius: cornerRadius,
        diagnosticPrefix: "inlineReusableHost",
        onReadyForDisplay: {
          guard let renderState, attachedKey == renderState.key else { return }
          readyForDisplay = true
          InlineVideoCoordinator.shared.setHostHasFrame(true, for: renderState.key)
          InlineVideoCoordinator.shared.recordFirstFrameReady(key: renderState.key, sharedVideo: renderState.sharedVideo)
        }
      )
      .frame(width: width, height: height)
      .mask(RR(cornerRadius, Color.black))
      .opacity(readyForDisplay && renderState != nil ? 1 : 0)
      .nsfw(
        renderState?.blurNSFW == true,
        smallIcon: renderState?.smallNSFWIcon == true,
        size: CGSize(width: width, height: height)
      )
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .position(x: localMidX, y: localMidY)
      .allowsHitTesting(false)
      .clipped()
      .onAppear {
        scheduleAttachment(renderState)
      }
      .onChange(of: renderState?.attachmentID) { _, _ in
        scheduleAttachment(renderState)
      }
      .onChange(of: renderState?.playbackConfigurationID) { _, _ in
        updatePlaybackConfiguration(renderState)
      }
      .onDisappear {
        detachAttached()
      }
    }
  }

  private func scheduleAttachment(_ state: InlinePlaybackRenderState?) {
    attachTask?.cancel()
    let generation = UUID()
    attachGeneration = generation
    readyForDisplay = false
    if let attachedKey {
      InlineVideoCoordinator.shared.setHostHasFrame(false, for: attachedKey)
    }

    guard let state else {
      detachAttached()
      return
    }

    ScrollPerfProbe.shared.bump("inlineReusableHost.playerSwapScheduled")
    attachTask = Task { @MainActor in
      await Task.yield()
      guard !Task.isCancelled, attachGeneration == generation else { return }
      let attachedPlayer = InlinePlaybackResourceController.shared.attach(
        key: state.key,
        video: state.sharedVideo,
        muted: state.muted,
        loop: state.loop,
        autoplay: state.autoplay
      )
      guard !Task.isCancelled, attachGeneration == generation else { return }
      attachedKey = state.key
      player = attachedPlayer
      ScrollPerfProbe.shared.bump("inlineReusableHost.playerSwap")
    }
  }

  private func updatePlaybackConfiguration(_ state: InlinePlaybackRenderState?) {
    guard let state, attachedKey == state.key else { return }
    InlinePlaybackResourceController.shared.updatePlayback(
      key: state.key,
      muted: state.muted,
      loop: state.loop,
      autoplay: state.autoplay
    )
  }

  private func detachAttached() {
    attachTask?.cancel()
    attachTask = nil
    attachGeneration = UUID()
    readyForDisplay = false
    guard let attachedKey else {
      player = nil
      return
    }
    InlineVideoCoordinator.shared.setHostHasFrame(false, for: attachedKey)
    InlinePlaybackResourceController.shared.detach(
      key: attachedKey,
      preservePlayback: InlineVideoCoordinator.shared.shouldPreservePlaybackOnLayerDetach(key: attachedKey)
    )
    self.attachedKey = nil
    player = nil
  }
}

private struct ReusableInlineAVPlayerLayerRepresentable: UIViewRepresentable {
  let player: AVPlayer?
  let videoGravity: AVLayerVideoGravity
  let cornerRadius: CGFloat
  let diagnosticPrefix: String
  var onReadyForDisplay: (() -> Void)?

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> PlayerLayerView {
    ScrollPerfProbe.shared.bump("\(diagnosticPrefix).make")
    let view = PlayerLayerView(diagnosticPrefix: diagnosticPrefix)
    view.backgroundColor = .clear
    view.playerLayer.player = player
    view.playerLayer.videoGravity = videoGravity
    view.setCornerRadius(cornerRadius)
    context.coordinator.onReadyForDisplay = onReadyForDisplay
    context.coordinator.observe(view.playerLayer)
    return view
  }

  func updateUIView(_ uiView: PlayerLayerView, context: Context) {
    ScrollPerfProbe.shared.bump("\(diagnosticPrefix).update")
    context.coordinator.onReadyForDisplay = onReadyForDisplay
    if uiView.playerLayer.player !== player {
      ScrollPerfProbe.shared.bump("\(diagnosticPrefix).playerLayerPlayerSet")
      uiView.playerLayer.player = player
    }
    if uiView.playerLayer.videoGravity != videoGravity {
      uiView.playerLayer.videoGravity = videoGravity
    }
    uiView.setCornerRadius(cornerRadius)
  }

  static func dismantleUIView(_ uiView: PlayerLayerView, coordinator: Coordinator) {
    coordinator.invalidate()
    uiView.playerLayer.player = nil
  }

  final class Coordinator {
    var onReadyForDisplay: (() -> Void)?
    private var observation: NSKeyValueObservation?

    func observe(_ layer: AVPlayerLayer) {
      observation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
        guard layer.isReadyForDisplay else { return }
        let callback = self?.onReadyForDisplay
        DispatchQueue.main.async { callback?() }
      }
    }

    func invalidate() {
      observation?.invalidate()
      observation = nil
    }
  }

  final class PlayerLayerView: UIView {
    let playerLayer = AVPlayerLayer()
    let diagnosticPrefix: String

    init(diagnosticPrefix: String) {
      self.diagnosticPrefix = diagnosticPrefix
      super.init(frame: .zero)
      configureLayers()
    }

    override init(frame: CGRect) {
      self.diagnosticPrefix = "inlineReusableHost"
      super.init(frame: frame)
      configureLayers()
    }

    required init?(coder: NSCoder) {
      self.diagnosticPrefix = "inlineReusableHost"
      super.init(coder: coder)
      configureLayers()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      ScrollPerfProbe.shared.bump("\(diagnosticPrefix).frameUpdate")
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      playerLayer.frame = bounds
      CATransaction.commit()
    }

    func setCornerRadius(_ radius: CGFloat) {
      layer.cornerRadius = radius
      layer.masksToBounds = radius > 0
      layer.cornerCurve = .continuous
      playerLayer.cornerRadius = radius
      playerLayer.masksToBounds = radius > 0
      playerLayer.cornerCurve = .continuous
    }

    private func configureLayers() {
      layer.addSublayer(playerLayer)
      layer.masksToBounds = true
      layer.cornerCurve = .continuous
      playerLayer.masksToBounds = true
      playerLayer.cornerCurve = .continuous
    }
  }
}

private struct FeedScrollGeometrySnapshot: Equatable {
  let viewportHeight: CGFloat
  let offsetY: CGFloat
}
