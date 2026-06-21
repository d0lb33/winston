//
//  AuroraMediaViewer.swift
//  winston
//
//  BETA fullscreen media viewer (opt-in via Settings → Behavior → Beta).
//
//  Goals vs. the legacy LightBoxImage / FullScreenVP:
//   • One unified viewer for image / GIF / video that shares a single gesture + dismiss + chrome layer.
//   • Native follow-finger swipe-to-dismiss that hands off to the system zoom transition
//     (.navigationTransition(.zoom)) so the media zooms back into its source card. The dismiss is NOT
//     animated by us — we only translate/scale/dim live, then call dismiss(). (Avoids the double-animation
//     that made the old viewers feel off.)
//   • Swipe horizontally to scrub/fast-forward GIFs and videos (haptic + glass HUD).
//   • Liquid-glass chrome throughout.
//
//  Reuses existing building blocks: LightBoxElementView (image/gif page + zoom + gif scrub),
//  InlineAVPlayerLayerRepresentable + SharedVideo (video), interpolatorBuilder, Hap.
//

import SwiftUI
import Defaults
import AVFoundation
import AVKit
import CoreMedia

// MARK: - Page model

enum AuroraMediaPage: Identifiable, Equatable {
  /// A static image OR an animated GIF (distinguished by file extension).
  case image(ImgExtracted)
  case video(SharedVideo)

  var id: String {
    switch self {
    case .image(let img): return "img-\(img.id)"
    case .video(let v): return "vid-\(v.url.absoluteString)"
    }
  }

  var isGIF: Bool {
    if case .image(let img) = self { return img.url.pathExtension.lowercased() == "gif" }
    return false
  }
  var isVideo: Bool { if case .video = self { return true } else { return false } }
  /// Whether this page has a timeline that the horizontal-swipe scrub gesture can drive.
  var isScrubbable: Bool { isGIF || isVideo }
}

// MARK: - Viewer

struct AuroraMediaViewer: View {
  let pages: [AuroraMediaPage]
  var startIndex: Int = 0
  var postTitle: String? = nil
  var doLiveText: Bool = false
  var markAsSeen: (() async -> ())? = nil
  var returnTransitionSourceID: String? = nil

  @Environment(\.dismiss) private var dismiss

  private static let pageSpacing: CGFloat = 24

  private enum DragAxis { case horizontal, vertical }
  /// State machine for the unified drag on scrubbable (gif/video) pages.
  private enum TouchPhase { case idle, deciding, scrubbing, panning }

  // Carousel
  @State private var activeIndex = 0
  @State private var xPos: CGFloat = 0

  // Pan (dismiss + paging)
  @State private var drag: CGSize = .zero
  @State private var dragOffset: CGSize?
  @State private var dragAxis: DragAxis?

  // Image zoom (reported by ZoomableScrollView inside LightBoxElementView)
  @State private var scale: CGFloat = 1
  @State private var isZoomed = false
  @State private var isPinching = false

  // Chrome
  @State private var showChrome = true

  // GIF scrub
  @State private var gifPlaybackState: GIFPlaybackState?
  @State private var isGifScrubbing = false
  @State private var gifScrubStartProgress: Double?
  @State private var gifScrubProgressRequest: Double?

  // Video playback / scrub
  @State private var videoProgress: Double = 0
  @State private var videoScrubStartProgress: Double?
  @State private var wasPlayingBeforeScrub = false
  @State private var timeObserver: Any?
  @State private var observedPlayer: AVPlayer?
  @State private var loopObserver: NSObjectProtocol?

  // Serialized seek pipeline: at most one seek in flight; the latest requested target is coalesced
  // into `pendingVideoSeekProgress` and applied when the current seek completes. `videoSeekGeneration`
  // invalidates stale completion callbacks after a page change / teardown.
  @State private var isVideoSeekInFlight = false
  @State private var pendingVideoSeekProgress: Double?
  @State private var pendingVideoSeekInteractive = false
  @State private var videoSeekGeneration = 0

  @State private var isPlaying = false
  @State private var isMuted = false

  /// Unified flag for the scrub gesture (drives the HUD + gesture gating).
  @State private var isScrubbing = false

  @State private var viewportSize: CGSize = .zero

  // Unified-drag state machine (scrubbable pages)
  @State private var touchPhase: TouchPhase = .idle
  @State private var isClosing = false

  // MARK: Derived

  private var currentPage: AuroraMediaPage? {
    pages.indices.contains(activeIndex) ? pages[activeIndex] : nil
  }
  private var activeVideo: SharedVideo? { video(at: activeIndex) }
  private func video(at index: Int) -> SharedVideo? {
    guard pages.indices.contains(index) else { return nil }
    if case .video(let v) = pages[index] { return v }
    return nil
  }
  private var pageWidth: CGFloat { max(viewportSize.width, 1) }

  /// Gestures are suppressed while the image scroll view is zoomed so its pinch/pan win.
  private var gesturesEnabled: Bool { !isZoomed && scale <= 1.01 }
  private var activePageIsScrubbable: Bool { currentPage?.isScrubbable ?? false }

  // MARK: Body

  var body: some View {
    ZStack {
      GeometryReader { proxy in
        mediaLayer(size: CGSize(width: max(proxy.size.width, 1), height: max(proxy.size.height, 1)))
      }
      .ignoresSafeArea()

      // Chrome is a sibling that does NOT ignore the safe area, so SwiftUI lays it out inside the
      // safe area automatically — below the notch / Dynamic Island and above the home indicator —
      // while the media behind it stays edge-to-edge.
      chromeLayer
    }
    .preferredColorScheme(.dark)
    .statusBar(hidden: true)
    .presentationBackground(.clear)
  }

  @ViewBuilder
  private func mediaLayer(size: CGSize) -> some View {
    let dragAmount = abs(drag.height)
    let interp = interpolatorBuilder([0, 260], value: dragAmount)
    let isVerticalDrag = dragAxis == .vertical
    let dimOpacity = isVerticalDrag ? interp([1, 0], false) : 1
    let contentScale = isVerticalDrag ? interp([1, 0.86], true) : 1

    ZStack {
      Color.black.opacity(dimOpacity)
        .frame(width: size.width, height: size.height)

      // Gestures live on the MEDIA layer (their descendants are the media pages), so they override
      // the pages for scrub/dismiss but leave the chrome controls — which are outside this layer —
      // tappable. Exactly one is ever attached (mutually exclusive by page type), so two
      // high-priority gestures never run at once (that simultaneity is what froze the UI).
      carousel(size: size, contentScale: contentScale)
        .contentShape(Rectangle())
        .highPriorityGesture(gesturesEnabled && activePageIsScrubbable ? scrubbableUnifiedGesture : nil)
        .highPriorityGesture(gesturesEnabled && !activePageIsScrubbable ? panGesture : nil)
    }
    .frame(width: size.width, height: size.height)
    .onAppear { setup(size: size) }
    .onChange(of: size) { _, newSize in
      viewportSize = newSize
      xPos = -CGFloat(activeIndex) * (newSize.width + Self.pageSpacing)
    }
    .onChange(of: activeIndex) { handlePageChange() }
    .onDisappear {
      if !isClosing {
        cleanupMediaState()
      }
    }
  }

  // MARK: Carousel

  @ViewBuilder
  private func carousel(size: CGSize, contentScale: CGFloat) -> some View {
    HStack(spacing: Self.pageSpacing) {
      ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
        let selected = index == activeIndex
        pageContent(page, selected: selected, size: size)
          .frame(width: size.width, height: size.height)
          .scaleEffect(selected && dragAxis == .vertical ? contentScale : 1)
          .offset(
            x: selected && dragAxis == .vertical ? drag.width : 0,
            y: selected && dragAxis == .vertical ? drag.height : 0
          )
          .allowsHitTesting(selected)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
    .offset(x: xPos + (dragAxis == .horizontal ? drag.width : 0))
    .frame(width: size.width, height: size.height, alignment: .leading)
  }

  @ViewBuilder
  private func pageContent(_ page: AuroraMediaPage, selected: Bool, size: CGSize) -> some View {
    switch page {
    case .image(let img):
      LightBoxElementView(
        el: img,
        onTap: { toggleChrome() },
        doLiveText: doLiveText,
        isActive: selected,
        isPinching: $isPinching,
        isZoomed: $isZoomed,
        zoomScale: $scale,
        gifPlaybackState: $gifPlaybackState,
        isGifScrubbing: $isGifScrubbing,
        gifScrubProgressRequest: selected ? gifScrubProgressRequest : nil,
        viewportSize: size
      )
    case .video(let v):
      // Tap-to-toggle-chrome is handled by the unified gesture (a separate onTapGesture here would
      // either be preempted by the high-priority drag or double-toggle).
      InlineAVPlayerLayerRepresentable(player: v.player, videoGravity: .resizeAspect)
        .frame(width: size.width, height: size.height)
        .background(Color.black)
        .contentShape(Rectangle())
    }
  }

  // MARK: Chrome

  @ViewBuilder
  private var chromeLayer: some View {
    let dragAmount = abs(drag.height)
    let interp = interpolatorBuilder([0, 260], value: dragAmount)
    let fade = dragAxis == .vertical ? interp([1, 0], false) : 1
    let chromeVisible = showChrome && !isScrubbing
    let topBarOpacity = chromeVisible ? fade : 0

    VStack(spacing: 0) {
      topBar
        .opacity(topBarOpacity)
        .allowsHitTesting(chromeVisible)
      Spacer(minLength: 0)
      if let v = activeVideo {
        videoControls(v)
          .opacity(topBarOpacity)
          .allowsHitTesting(chromeVisible)
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, 8)
    .padding(.bottom, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .bottom) {
      if isScrubbing {
        scrubHUD
          .padding(.bottom, 18)
          .transition(.opacity)
      }
    }
  }

  private var topBar: some View {
    HStack(spacing: 10) {
      Button { closeViewer() } label: {
        Image(systemName: "xmark")
          .font(.system(size: 15, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 38, height: 38)
          .auroraGlass(Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close")

      if let postTitle, !postTitle.isEmpty {
        Text(postTitle)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
          .lineLimit(1)
          .padding(.horizontal, 14)
          .padding(.vertical, 9)
          .auroraGlass(Capsule(style: .continuous))
      }

      Spacer(minLength: 0)

      if pages.count > 1 {
        Text("\(activeIndex + 1) / \(pages.count)")
          .font(.footnote.weight(.semibold).monospacedDigit())
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 9)
          .auroraGlass(Capsule(style: .continuous))
      }
    }
  }

  private func videoControls(_ v: SharedVideo) -> some View {
    HStack(spacing: 14) {
      Button { togglePlayback(v) } label: {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 30, height: 30)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isPlaying ? "Pause" : "Play")

      AuroraTimelineScrubber(
        progress: videoProgress,
        onScrub: { scrubTimeline(v, $0) },
        onFinish: { finishVideoScrub(v) }
      )
      .frame(height: 30)

      Button { toggleMute(v) } label: {
        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 30, height: 30)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isMuted ? "Unmute" : "Mute")

      AuroraAirPlayButton()
        .frame(width: 30, height: 30)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .auroraGlass(Capsule(style: .continuous))
  }

  private var scrubProgress: Double {
    if activeVideo != nil { return videoProgress }
    return gifPlaybackState?.progress ?? 0
  }

  private var scrubHUD: some View {
    VStack(spacing: 8) {
      if let v = activeVideo {
        let duration = videoDuration(v)
        Text("\(timeString(scrubProgress * duration)) / \(timeString(duration))")
          .font(.footnote.weight(.semibold).monospacedDigit())
          .foregroundStyle(.white)
      }
      GeometryReader { p in
        ZStack(alignment: .leading) {
          Capsule(style: .continuous).fill(.white.opacity(0.22))
          Capsule(style: .continuous)
            .fill(.white.opacity(0.95))
            .frame(width: max(6, p.size.width * min(max(scrubProgress, 0), 1)))
        }
      }
      .frame(width: 180, height: 5)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .auroraGlass(Capsule(style: .continuous))
  }

  // MARK: Gestures

  /// Single drag (minimumDistance 0 so a tap still gives us touch-down/up) that decides intent from
  /// the first decisive (~10pt) movement:
  ///  • Horizontal on a single scrubbable item → scrub immediately (haptic + glass HUD).
  ///  • Vertical → dismiss; horizontal in a gallery → page.
  ///  • Touch up with no movement → tap → toggle chrome.
  /// One gesture means engaging scrub never changes the gesture tree → no freeze.
  private var scrubbableUnifiedGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { onUnifiedChanged($0) }
      .onEnded { onUnifiedEnded($0) }
  }

  private var panGesture: some Gesture {
    DragGesture(minimumDistance: 12)
      .onChanged { onPanChanged($0) }
      .onEnded { onPanEnded($0) }
  }

  private func onUnifiedChanged(_ val: DragGesture.Value) {
    if touchPhase == .idle { touchPhase = .deciding }
    if touchPhase == .deciding {
      let dx = abs(val.translation.width)
      let dy = abs(val.translation.height)
      // Commit to an axis once the finger has moved decisively.
      guard max(dx, dy) > 10 else { return }
      if dx > dy && pages.count <= 1 {
        // Horizontal on a single scrubbable item → scrub instantly.
        touchPhase = .scrubbing
        beginScrub()
        updateScrub(translationWidth: val.translation.width)
      } else {
        // Vertical → dismiss; horizontal in a gallery → page.
        touchPhase = .panning
        onPanChanged(val)
      }
      return
    }
    switch touchPhase {
    case .scrubbing:
      updateScrub(translationWidth: val.translation.width)
    case .panning:
      onPanChanged(val)
    case .idle, .deciding:
      break
    }
  }

  private func onUnifiedEnded(_ val: DragGesture.Value) {
    let distance = hypot(val.translation.width, val.translation.height)
    switch touchPhase {
    case .scrubbing:
      endScrub()
    case .panning:
      onPanEnded(val)
    case .deciding, .idle:
      if distance <= 12 { toggleChrome() }
    }
    touchPhase = .idle
  }

  private func onPanChanged(_ val: DragGesture.Value) {
    guard !isScrubbing else { return }
    if dragAxis == nil || dragOffset == nil {
      dragOffset = val.translation
      if abs(val.predictedEndTranslation.width) > abs(val.predictedEndTranslation.height) {
        dragAxis = .horizontal
      } else {
        dragAxis = .vertical
      }
    }
    guard let axis = dragAxis, let offset = dragOffset else { return }
    // Horizontal is reserved for scrub on single (non-gallery) items.
    if axis == .horizontal && pages.count <= 1 { return }

    var transaction = Transaction()
    transaction.isContinuous = true
    transaction.animation = .interpolatingSpring(stiffness: 1000, damping: 100, initialVelocity: 0)
    var endPos = val.translation
    if axis == .horizontal { endPos.height = 0 }
    withTransaction(transaction) {
      drag = endPos - offset
    }
  }

  private func onPanEnded(_ val: DragGesture.Value) {
    guard !isScrubbing else { return }
    let axis = dragAxis
    let offsetWidth = dragOffset?.width ?? 0
    dragOffset = nil

    if axis == .horizontal && pages.count > 1 {
      let predictedEnd = val.predictedEndTranslation.width - offsetWidth
      drag = .zero
      xPos += val.translation.width - offsetWidth
      let step = predictedEnd < -(pageWidth / 2) ? 1 : (predictedEnd > pageWidth / 2 ? -1 : 0)
      let newIndex = min(pages.count - 1, max(0, activeIndex + step))
      let finalX = -(CGFloat(newIndex) * (pageWidth + Self.pageSpacing))
      let distance = abs(finalX - xPos)
      activeIndex = newIndex
      var velocity = distance > 1 ? abs(predictedEnd / distance) : 0
      velocity = velocity < 3.75 ? 0 : velocity * 2
      withAnimation(.interpolatingSpring(stiffness: 150, damping: 17, initialVelocity: velocity)) {
        xPos = finalX
        dragAxis = nil
      }
    } else if axis == .vertical {
      let shouldClose = abs(val.translation.height) > 120 || val.predictedEndTranslation.height > 420
      if shouldClose {
        // Hand off to the system zoom transition — do NOT wrap in withAnimation.
        closeViewer()
      } else {
        withAnimation(.interpolatingSpring(stiffness: 220, damping: 22, initialVelocity: 0)) {
          drag = .zero
          dragAxis = nil
        }
      }
    } else {
      withAnimation(.interpolatingSpring(stiffness: 220, damping: 22, initialVelocity: 0)) {
        drag = .zero
        dragAxis = nil
      }
    }
  }

  // MARK: Scrub

  private func beginScrub() {
    guard let page = currentPage, page.isScrubbable else { return }
    isScrubbing = true
    Hap.shared.play(intensity: 0.7, sharpness: 0.85)
    if let v = activeVideo {
      startVideoScrub(v)
    } else if page.isGIF {
      isGifScrubbing = true
      gifScrubStartProgress = gifPlaybackState?.progress ?? 0
    }
  }

  private func updateScrub(translationWidth: CGFloat) {
    guard isScrubbing, pageWidth > 0 else { return }
    let delta = Double(translationWidth / pageWidth)
    if let v = activeVideo {
      let start = videoScrubStartProgress ?? currentVideoProgress(v)
      videoScrubStartProgress = start
      seekVideo(v, to: min(max(start + delta, 0), 1), interactive: true)
    } else if currentPage?.isGIF == true {
      let start = gifScrubStartProgress ?? (gifPlaybackState?.progress ?? 0)
      gifScrubStartProgress = start
      gifScrubProgressRequest = min(max(start + delta, 0), 1)
    }
  }

  private func endScrub() {
    guard isScrubbing else { return }
    if let v = activeVideo { finishVideoScrub(v) }
    isGifScrubbing = false
    gifScrubStartProgress = nil
    gifScrubProgressRequest = nil
    isScrubbing = false
  }

  // MARK: Video helpers

  private func videoDuration(_ v: SharedVideo) -> TimeInterval {
    guard let duration = v.player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { return 0 }
    return duration
  }

  private func currentVideoProgress(_ v: SharedVideo) -> Double {
    let duration = videoDuration(v)
    guard duration > 0 else { return 0 }
    let currentTime = v.player.currentTime().seconds
    guard currentTime.isFinite else { return 0 }
    return min(max(currentTime / duration, 0), 1)
  }

  private func startVideoScrub(_ v: SharedVideo) {
    guard videoDuration(v) > 0, videoScrubStartProgress == nil else { return }
    videoScrubStartProgress = currentVideoProgress(v)
    videoProgress = videoScrubStartProgress ?? videoProgress
    wasPlayingBeforeScrub = v.player.rate != 0
    v.player.pause()
    isPlaying = false
  }

  private func finishVideoScrub(_ v: SharedVideo) {
    videoScrubStartProgress = nil
    if wasPlayingBeforeScrub {
      v.player.play()
      isPlaying = true
    }
    wasPlayingBeforeScrub = false
  }

  private func scrubTimeline(_ v: SharedVideo, _ progress: Double) {
    if videoScrubStartProgress == nil { startVideoScrub(v) }
    seekVideo(v, to: progress, interactive: true)
  }

  private func seekVideo(_ v: SharedVideo, to progress: Double, interactive: Bool) {
    let duration = videoDuration(v)
    guard duration > 0 else { return }
    let clamped = min(max(progress, 0), 1)
    videoProgress = clamped
    enqueueVideoSeek(v, progress: clamped, duration: duration, interactive: interactive)
  }

  private func togglePlayback(_ v: SharedVideo) {
    if v.player.rate == 0 {
      v.player.play()
      isPlaying = true
    } else {
      v.player.pause()
      isPlaying = false
    }
  }

  private func toggleMute(_ v: SharedVideo) {
    v.player.isMuted.toggle()
    isMuted = v.player.isMuted
  }

  private func installVideoTimeObserver(_ v: SharedVideo) {
    removeVideoTimeObserver()
    observedPlayer = v.player
    videoProgress = currentVideoProgress(v)
    timeObserver = v.player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
      queue: .main
    ) { _ in
      if videoScrubStartProgress == nil {
        let p = currentVideoProgress(v)
        if abs(p - videoProgress) > 0.0005 { videoProgress = p }
      }
      let playing = v.player.rate != 0
      if isPlaying != playing { isPlaying = playing }
      let muted = v.player.isMuted
      if isMuted != muted { isMuted = muted }
    }
    installVideoLoopObserver(v)
  }

  private func removeVideoTimeObserver() {
    if let timeObserver, let observedPlayer {
      observedPlayer.removeTimeObserver(timeObserver)
    }
    timeObserver = nil
    observedPlayer = nil
    removeVideoLoopObserver()
  }

  /// The inline coordinator removes its own loop observer when fullscreen takes over
  /// (`detach(preserveForFullscreen:)`), so the shared player has none while presented. Install our
  /// own here so the fullscreen video loops just like the feed. Gated by the user's loop setting.
  private func installVideoLoopObserver(_ v: SharedVideo) {
    removeVideoLoopObserver()
    guard Defaults[.VideoDefSettings].loop, let item = v.player.currentItem else { return }
    loopObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification,
      object: item,
      queue: .main
    ) { [weak player = v.player] _ in
      player?.seek(to: .zero)
      player?.play()
    }
  }

  private func removeVideoLoopObserver() {
    if let loopObserver {
      NotificationCenter.default.removeObserver(loopObserver)
    }
    loopObserver = nil
  }

  private func enqueueVideoSeek(_ v: SharedVideo, progress: Double, duration: TimeInterval, interactive: Bool) {
    pendingVideoSeekProgress = progress
    pendingVideoSeekInteractive = pendingVideoSeekInteractive || interactive
    guard !isVideoSeekInFlight else { return }
    performPendingVideoSeek(v, duration: duration)
  }

  private func performPendingVideoSeek(_ v: SharedVideo, duration: TimeInterval) {
    guard let progress = pendingVideoSeekProgress else { return }
    guard duration > 0 else {
      pendingVideoSeekProgress = nil
      pendingVideoSeekInteractive = false
      isVideoSeekInFlight = false
      return
    }
    let player = v.player
    let generation = videoSeekGeneration
    let interactive = pendingVideoSeekInteractive
    pendingVideoSeekProgress = nil
    pendingVideoSeekInteractive = false
    isVideoSeekInFlight = true

    let seconds = progress * duration
    let tolerance = interactive ? CMTime(seconds: 1.0 / 15.0, preferredTimescale: 600) : .zero
    player.seek(
      to: CMTime(seconds: seconds, preferredTimescale: 600),
      toleranceBefore: tolerance,
      toleranceAfter: tolerance
    ) { _ in
      DispatchQueue.main.async {
        guard videoSeekGeneration == generation else { return }
        isVideoSeekInFlight = false
        if pendingVideoSeekProgress != nil {
          performPendingVideoSeek(v, duration: videoDuration(v))
        }
      }
    }
  }

  private func cancelVideoSeekState() {
    videoSeekGeneration += 1
    isVideoSeekInFlight = false
    pendingVideoSeekProgress = nil
    pendingVideoSeekInteractive = false
    (observedPlayer ?? activeVideo?.player)?.currentItem?.cancelPendingSeeks()
  }

  private func cleanupMediaState() {
    touchPhase = .idle
    cancelVideoSeekState()
    isScrubbing = false
    isGifScrubbing = false
    gifScrubStartProgress = nil
    gifScrubProgressRequest = nil
    videoScrubStartProgress = nil
    wasPlayingBeforeScrub = false
    removeVideoTimeObserver()
  }

  private func closeViewer() {
    guard !isClosing else { return }
    isClosing = true
    InlineVideoCoordinator.shared.beginReturnTransition(sourceID: returnTransitionSourceID)
    dismiss()
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 450_000_000)
      cleanupMediaState()
    }
  }

  // MARK: Lifecycle

  private func setup(size: CGSize) {
    viewportSize = size
    let safe = min(max(startIndex, 0), max(pages.count - 1, 0))
    activeIndex = safe
    xPos = -CGFloat(safe) * (size.width + Self.pageSpacing)
    if let v = video(at: safe) {
      isMuted = v.player.isMuted
      isPlaying = v.player.rate != 0
      installVideoTimeObserver(v)
    }
    if let markAsSeen { Task { await markAsSeen() } }
  }

  private func handlePageChange() {
    cancelVideoSeekState()
    gifPlaybackState = nil
    isGifScrubbing = false
    gifScrubStartProgress = nil
    gifScrubProgressRequest = nil
    scale = 1
    isZoomed = false
    isScrubbing = false
    if let v = activeVideo {
      installVideoTimeObserver(v)
      isMuted = v.player.isMuted
      isPlaying = v.player.rate != 0
    } else {
      removeVideoTimeObserver()
    }
  }

  private func toggleChrome() {
    withAnimation(.easeOut(duration: 0.2)) { showChrome.toggle() }
  }

  private func timeString(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}

// MARK: - Liquid-glass background

private struct AuroraGlassBackground<S: Shape>: ViewModifier {
  let shape: S
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.glassEffect(.regular.interactive(), in: shape)
    } else {
      content
        .background { shape.fill(.ultraThinMaterial) }
        .overlay { shape.stroke(.white.opacity(0.16), lineWidth: 1) }
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
    }
  }
}

private extension View {
  func auroraGlass<S: Shape>(_ shape: S) -> some View { modifier(AuroraGlassBackground(shape: shape)) }
}

// MARK: - Glass timeline scrubber (tap / drag to seek)

private struct AuroraTimelineScrubber: View {
  let progress: Double
  let onScrub: (Double) -> Void
  let onFinish: () -> Void

  var body: some View {
    GeometryReader { proxy in
      let clamped = min(max(progress, 0), 1)
      let width = max(proxy.size.width, 1)
      ZStack(alignment: .leading) {
        Capsule(style: .continuous).fill(.white.opacity(0.22)).frame(height: 6)
        Capsule(style: .continuous).fill(.white.opacity(0.95)).frame(width: max(6, width * clamped), height: 6)
        Circle()
          .fill(.white)
          .frame(width: 15, height: 15)
          .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
          .offset(x: min(max(width * clamped - 7.5, 0), max(width - 15, 0)))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { val in onScrub(min(max(Double(val.location.x / width), 0), 1)) }
          .onEnded { _ in onFinish() }
      )
    }
  }
}

// MARK: - AirPlay

private struct AuroraAirPlayButton: UIViewRepresentable {
  func makeUIView(context: Context) -> AVRoutePickerView {
    let picker = AVRoutePickerView()
    picker.prioritizesVideoDevices = true
    picker.tintColor = .white
    picker.activeTintColor = .white
    picker.backgroundColor = .clear
    return picker
  }
  func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
