//
//  InlineVideoCoordinator.swift
//  winston
//
//  Coordinates inline video playback across the feed so that only ONE video
//  (the one nearest the viewport center) autoplays at a time, and so that all
//  inline players pause while the feed is actively scrolling. This collapses
//  N simultaneous AVPlayer decoders down to 1, which is the main cause of
//  scroll hitches in video-heavy subreddits.
//
//  Autoplay is not removed — it is gated. When scrolling settles, the centered
//  video resumes; the rest keep their already-rendered frame (or poster).
//

import SwiftUI
import Observation

@MainActor
@Observable
final class InlineVideoCoordinator {
  static let shared = InlineVideoCoordinator()

  /// The feed-item key (post id) of the single video allowed to autoplay inline.
  private(set) var activeVideoKey: String?

  /// Nearby inline videos allowed to mount a paused AVPlayer so their first frame can
  /// be ready before they become centered. This stays tiny and is cleared on fast scroll.
  private(set) var warmVideoKeys: Set<String> = []

  /// True while the feed scroll view is interacting/decelerating. While true,
  /// inline playback is paused regardless of which video is active.
  private(set) var isScrolling: Bool = false

  /// True when center updates indicate the feed is moving quickly enough that mounting
  /// nearby paused players would likely hurt scroll smoothness more than it helps.
  private(set) var isFastScrolling: Bool = false

  // Latest per-row centers and viewport height, updated as the feed reports geometry.
  // ObservationIgnored: written every frame during scroll — must not invalidate views.
  @ObservationIgnored private var latestCenters: [InlineVideoCenter] = []
  @ObservationIgnored var viewportHeight: CGFloat = .screenH
  @ObservationIgnored private var lastCentersMeanY: CGFloat?
  @ObservationIgnored private var lastCentersTimestamp: TimeInterval?
  @ObservationIgnored private var lastScrollDeltaY: CGFloat = 0

  private let warmAheadCount = 3
  private let fastScrollVelocityThreshold: CGFloat = 2_200

  private init() {}

  func setActive(_ key: String?) {
    guard key != activeVideoKey else { return }
    activeVideoKey = key
  }

  func setScrolling(_ scrolling: Bool) {
    guard scrolling != isScrolling else { return }
    isScrolling = scrolling
  }

  func isActive(_ key: String?) -> Bool {
    key != nil && key == activeVideoKey
  }

  func isWarm(_ key: String?) -> Bool {
    guard let key else { return false }
    return warmVideoKeys.contains(key)
  }

  /// Cheap per-frame sink for row centers. Does NOT elect (and does not invalidate
  /// views) — election is deferred to rest, since nothing plays while scrolling.
  func updateCenters(_ centers: [InlineVideoCenter]) {
    latestCenters = centers.sorted { $0.midY < $1.midY }
    updateScrollVelocity(from: latestCenters)

    // Only (re)populate the warm set at rest. Mounting paused AVPlayers + AVPlayerLayers
    // mid-scroll (attaching to the player and kicking off HLS asset loading on the main
    // thread) is the main remaining source of fast-scroll hitches. `electCenteredVideo`
    // already warms neighbors when the feed settles, so the next video is still ready by
    // the time you stop — we just stop paying for it during the scroll itself.
    guard !isScrolling else { return }
    updateWarmVideoKeys()
  }

  /// Pick the video nearest the viewport center and make it active. Called when the
  /// feed settles (scroll idle), not per-frame.
  func electCenteredVideo() {
    let center = viewportHeight / 2
    let nearest = latestCenters.min(by: { abs($0.midY - center) < abs($1.midY - center) })?.key
    setActive(nearest)
    isFastScrolling = false
    updateWarmVideoKeys()
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
      if !warmVideoKeys.isEmpty { warmVideoKeys = [] }
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
      warmVideoKeys = nextKeys
    }
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

  /// Drive the coordinator from a scrollable feed: report scroll phase (for isScrolling)
  /// and elect the centered video when the feed settles. No per-frame election work —
  /// nothing plays while scrolling, so the centered choice only matters at rest.
  func driveInlineVideoCoordinator(coordinateSpace: String) -> some View {
    self
      .coordinateSpace(.named(coordinateSpace))
      .onScrollPhaseChange { _, phase in
        let scrolling = phase != .idle
        InlineVideoCoordinator.shared.setScrolling(scrolling)
        if !scrolling { InlineVideoCoordinator.shared.electCenteredVideo() }
      }
      .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, newHeight in
        if newHeight > 0 { InlineVideoCoordinator.shared.viewportHeight = newHeight }
      }
      .onPreferenceChange(InlineVideoCenterPreferenceKey.self) { centers in
        // Cheap per-frame sink. Only elect when at rest (debounced for the initial,
        // no-scroll layout where onScrollPhaseChange never fires).
        InlineVideoCoordinator.shared.updateCenters(centers)
        guard !InlineVideoCoordinator.shared.isScrolling else { return }
        DispatchQueue.main.debounce(delay: 0.1, context: "inlineVideoActive") {
          InlineVideoCoordinator.shared.electCenteredVideo()
        }
      }
  }
}
