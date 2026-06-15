import SwiftUI
import Defaults
import CoreMedia
import AVKit
import AVFoundation
import Combine
import Nuke

final class SharedVideo: Equatable {
  static func == (lhs: SharedVideo, rhs: SharedVideo) -> Bool {
    lhs.url == rhs.url && lhs.downloadURL == rhs.downloadURL && lhs.posterURL == rhs.posterURL && lhs.size == rhs.size
  }

  let url: URL
  let downloadURL: URL?
  let posterURL: URL?
  let size: CGSize

  // The AVPlayer (and its expensive CoreMedia/MediaToolbox HLS asset loading) is created
  // lazily on first access. Only a video that actually needs to play pays for it, so a feed
  // full of video posts no longer spins up dozens of AVPlayerItems demuxing at once — the
  // CoreMedia lock contention that stalled the main thread during scroll.
  private var _player: AVPlayer?
  var player: AVPlayer {
    if let existing = _player { return existing }
    let newPlayer = ScrollPerfProbe.shared.measure("avPlayerCreate") { AVPlayer(url: url) }
    newPlayer.volume = 0.0
    _player = newPlayer
    if AppDiagnostics.isEnabled(.debug, category: "ui.video.cache") {
      AppDiagnostics.asyncRecord(
        .debug,
        category: "ui.video.cache",
        message: "SharedVideo created AVPlayer (lazy)",
        metadata: SharedVideo.cacheDiagnosticsMetadata(url: url, size: size, downloadURL: downloadURL, posterURL: posterURL, cacheKey: SharedVideo.cacheKey(url: url, size: size, downloadURL: downloadURL, posterURL: posterURL))
      )
    }
    return newPlayer
  }

  /// Whether the AVPlayer has been created yet (i.e. this video has been mounted to play).
  var isPlayerLoaded: Bool { _player != nil }

  static func get(url: URL, size: CGSize, downloadURL: URL? = nil, posterURL: URL? = nil, resetCache: Bool = false) -> SharedVideo {
    let cacheKey =  SharedVideo.cacheKey(url: url, size: size, downloadURL: downloadURL, posterURL: posterURL)
    
    if resetCache {
      Caches.videos.cache.removeValue(forKey: cacheKey)
      AppDiagnostics.asyncRecord(
        .warning,
        category: "ui.video.cache",
        message: "SharedVideo cache reset",
        metadata: SharedVideo.cacheDiagnosticsMetadata(url: url, size: size, downloadURL: downloadURL, posterURL: posterURL, cacheKey: cacheKey)
      )
    }
    
    if let sharedVideo = Caches.videos.get(key: cacheKey) {
      if AppDiagnostics.isEnabled(.debug, category: "ui.video.cache") {
        AppDiagnostics.asyncRecord(
          .debug,
          category: "ui.video.cache",
          message: "SharedVideo cache hit",
          metadata: SharedVideo.cacheDiagnosticsMetadata(url: url, size: size, downloadURL: downloadURL, posterURL: posterURL, cacheKey: cacheKey)
        )
      }
      return sharedVideo
    } else {
      let sharedVideo = SharedVideo(url: url, size: size, downloadURL: downloadURL, posterURL: posterURL)
      Caches.videos.addKeyValue(key: cacheKey, data: { sharedVideo }, expires: Date().dateByAdding(1, .day).date)
      if AppDiagnostics.isEnabled(.debug, category: "ui.video.cache") {
        AppDiagnostics.asyncRecord(
          .debug,
          category: "ui.video.cache",
          message: "SharedVideo cache miss",
          metadata: SharedVideo.cacheDiagnosticsMetadata(url: url, size: size, downloadURL: downloadURL, posterURL: posterURL, cacheKey: cacheKey)
        )
      }

      return sharedVideo
    }
  }

  static func cacheKey(url: URL, size: CGSize, downloadURL: URL? = nil, posterURL: URL? = nil) -> String {
    return "\(url.absoluteString):\(downloadURL?.absoluteString ?? ""):\(posterURL?.absoluteString ?? ""):\(size.width)x\(size.height)"
  }

  static func cacheDiagnosticsMetadata(url: URL, size: CGSize, downloadURL: URL?, posterURL: URL?, cacheKey: String) -> [String: String] {
    [
      "cacheKeyHash": "\(cacheKey.hashValue)",
      "url": url.absoluteString,
      "downloadURL": downloadURL?.absoluteString ?? "nil",
      "posterURL": posterURL?.absoluteString ?? "nil",
      "size": "\(size.width)x\(size.height)"
    ]
  }
  
  init(url: URL, size: CGSize, downloadURL: URL? = nil, posterURL: URL? = nil) {
    self.url = url
    self.downloadURL = downloadURL
    self.posterURL = posterURL
    self.size = size
  }
}

struct VideoPlayerPost: View, Equatable {
  static func == (lhs: VideoPlayerPost, rhs: VideoPlayerPost) -> Bool {
    lhs.url == rhs.url
      && lhs.sharedVideo == rhs.sharedVideo
      && lhs.compact == rhs.compact
      && lhs.contentWidth == rhs.contentWidth
      && lhs.maxMediaHeightScreenPercentage == rhs.maxMediaHeightScreenPercentage
      && lhs.diagnosticContext == rhs.diagnosticContext
      && lhs.feedItemKey == rhs.feedItemKey
  }
  
  weak var controller: UIViewController?
  var sharedVideo: SharedVideo?
  let markAsSeen: (() async -> ())?
  var compact = false
  var contentWidth: CGFloat
  var url: URL
  var size: CGSize
  let resetVideo: ((SharedVideo) -> ())?
  var maxMediaHeightScreenPercentage: CGFloat
  var diagnosticContext: String? = nil
  var feedItemKey: String? = nil
  @State private var firstFullscreen = false
  @State private var fullscreen = false
  @State private var preparedInlineVideoKey: String?
  @State private var observedVideoKey: String?
  @State private var videoObservers: [NSObjectProtocol] = []
  @State private var showInlinePoster = true
  @State private var posterLoaded = false
  @State private var posterUnavailable = false
  @State private var inlineVideoRefreshID = UUID()
  @State private var activeInlineVideoKey: String?
  @State private var posterHideGeneration = UUID()
  /// Cached mirror of `shouldMountPlayer`, written only by `syncInlineState` (driven by the
  /// `InlineVideoCoordinatorObserver` child). The body reads THIS instead of the computed
  /// `shouldMountPlayer`, so the heavy body no longer subscribes to the coordinator's
  /// `@Observable` state and re-evaluates only when this cell's own mount state flips.
  @State private var mountPlayer = false
  /// True once the live AVPlayerLayer has composited a real frame. The grey "no frame yet"
  /// backdrop and the poster both stay until this flips, so the poster→video handoff never
  /// reveals an empty/grey gap. Reset when the row is reused for a different video.
  @State private var playerReadyForDisplay = false
  @Default(.VideoDefSettings) private var videoDefSettings
  @Environment(\.scenePhase) private var scenePhase
  @Namespace private var videoNS

  private var autoPlayVideos: Bool { videoDefSettings.autoPlay }
  private var loopVideos: Bool { videoDefSettings.loop }
  private var muteVideos: Bool { videoDefSettings.mute }
  private var pauseBackgroundAudioOnFullscreen: Bool { videoDefSettings.pauseBGAudioOnFullscreen }

  /// Whether this inline player should be actively playing right now. In a gated feed
  /// (feedItemKey != nil) only the current active video plays. Scrolling does not pause
  /// the active media; the coordinator elects a new active video when the feed settles.
  /// Outside a gated feed (feedItemKey == nil — e.g. post detail, comments) behavior is
  /// unchanged: autoplay setting alone decides.
  private var shouldPlayInline: Bool {
    guard autoPlayVideos, !fullscreen else { return false }
    guard let feedItemKey else { return true }
    return InlineVideoCoordinator.shared.isActive(feedItemKey)
  }

  /// Whether to mount the live AVPlayer layer at all. Off-center feed videos render only
  /// their poster — never instantiating an AVPlayer — so a video-heavy feed no longer
  /// loads dozens of HLS assets at once (the CoreMedia lock storm). The active (centered)
  /// video, the fullscreen one, and non-feed usages mount as before.
  private var shouldMountPlayer: Bool {
    fullscreen || feedItemKey == nil || InlineVideoCoordinator.shared.isActive(feedItemKey) || InlineVideoCoordinator.shared.isWarm(feedItemKey) || hasRenderedInlineFrame
  }

  /// Once a warmed/active inline player has replaced its poster with a real frame, keep
  /// that player layer mounted while the row remains alive. Otherwise active/warm handoff
  /// can briefly swap in the grey placeholder even though full-quality media is ready.
  private var hasRenderedInlineFrame: Bool {
    sharedVideo?.isPlayerLoaded == true && !showInlinePoster
  }

  init(controller: UIViewController?, cachedVideo: SharedVideo?, markAsSeen: (() async -> ())?, compact: Bool = false, contentWidth: CGFloat, url: URL, resetVideo: ((SharedVideo) -> ())?, maxMediaHeightScreenPercentage: CGFloat, diagnosticContext: String? = nil, feedItemKey: String? = nil) {
    self.controller = controller
    self.sharedVideo = cachedVideo
    self.markAsSeen = markAsSeen
    self.compact = compact
    self.contentWidth = contentWidth
    self.url = url
    self.size = cachedVideo?.size ?? .zero
    self.resetVideo = resetVideo
    self.maxMediaHeightScreenPercentage = maxMediaHeightScreenPercentage
    self.diagnosticContext = diagnosticContext
    self.feedItemKey = feedItemKey
  }
  
  var safe: Double { getSafeArea().top + getSafeArea().bottom }

  private var renderedVideoSize: CGSize {
    let maxHeight: CGFloat = (maxMediaHeightScreenPercentage / 100) * (.screenH)
    let sourceWidth = size.width
    let sourceHeight = size.height
    let propHeight = sourceWidth > 0 && sourceHeight > 0 && contentWidth > 0 ? (contentWidth * sourceHeight) / sourceWidth : contentWidth * 9 / 16
    let finalHeight = maxMediaHeightScreenPercentage != 110 ? Double(min(maxHeight, propHeight)) : Double(propHeight)
    return CGSize(
      width: compact ? scaledCompactModeThumbSize(compact: compact) : contentWidth,
      height: compact ? scaledCompactModeThumbSize(compact: compact) : CGFloat(finalHeight)
    )
  }
  
  
  var body: some View {
    let _ = ScrollPerfProbe.shared.bump("videoBody")
    
    if let sharedVideo = sharedVideo {
      let videoSize = renderedVideoSize
      if let controller = controller {
        ZStack {
          inlineVideoPlaceholder()
          inlineVideoLayer(sharedVideo: sharedVideo, videoSize: videoSize)
            .id(inlineVideoRefreshID)
          videoPoster(sharedVideo: sharedVideo, size: videoSize)
          playOverlay()
        }
        .frame(width: videoSize.width, height: videoSize.height)
        .mask(RR(12, Color.black))
        .contentShape(Rectangle())
        .matchedTransitionSource(id: "video", in: videoNS)
        .onTapGesture {
          openFullscreen(sharedVideo, branch: "controller")
        }
        .fullScreenCover(isPresented: $fullscreen) {
          FullScreenVP(sharedVideo: sharedVideo)
            .navigationTransition(.zoom(sourceID: "video", in: videoNS))
        }
        .onAppear {
          recordVideoEvent(.debug, message: "VideoPlayerPost appeared", sharedVideo: sharedVideo, extra: ["branch": "controller", "videoSize": "\(videoSize.width)x\(videoSize.height)"])
          prepareForInlineDisplay(sharedVideo)
        }
        .onChange(of: scenePhase) { newPhase in
          recordVideoEvent(.debug, message: "VideoPlayerPost scene phase changed", sharedVideo: sharedVideo, extra: ["newPhase": scenePhaseDescription(newPhase), "branch": "controller"])
          if newPhase == .active {
            prepareForInlineDisplay(sharedVideo)
          }
        }
        .background(InlineVideoCoordinatorObserver { syncInlineState(sharedVideo) })
        .onDisappear() {
          recordVideoEvent(.debug, message: "VideoPlayerPost disappeared", sharedVideo: sharedVideo, extra: ["branch": "controller"])
          handleInlineDisappear(sharedVideo)
        }
        .onChange(of: fullscreen) { val in
          handleFullscreenChange(val, sharedVideo: sharedVideo)
          syncInlineState(sharedVideo)
        }
      } else {
        ZStack {
          inlineVideoPlaceholder()

          inlineVideoLayer(sharedVideo: sharedVideo, videoSize: videoSize)
            .id(inlineVideoRefreshID)

          videoPoster(sharedVideo: sharedVideo, size: videoSize)
          playOverlay()
        }
        .contentShape(Rectangle())
        .matchedTransitionSource(id: "video", in: videoNS)
        .onTapGesture {
          openFullscreen(sharedVideo, branch: "swiftuiVideoPlayer")
        }
        .fullScreenCover(isPresented: $fullscreen) {
          FullScreenVP(sharedVideo: sharedVideo)
            .navigationTransition(.zoom(sourceID: "video", in: videoNS))
        }
        .onAppear {
          recordVideoEvent(.debug, message: "VideoPlayerPost appeared", sharedVideo: sharedVideo, extra: ["branch": "swiftuiVideoPlayer", "videoSize": "\(videoSize.width)x\(videoSize.height)"])
          prepareForInlineDisplay(sharedVideo)
        }
        .onChange(of: scenePhase) { newPhase in
          recordVideoEvent(.debug, message: "VideoPlayerPost scene phase changed", sharedVideo: sharedVideo, extra: ["newPhase": scenePhaseDescription(newPhase), "branch": "swiftuiVideoPlayer"])
          if newPhase == .active {
            prepareForInlineDisplay(sharedVideo)
          }
        }
        .background(InlineVideoCoordinatorObserver { syncInlineState(sharedVideo) })
        .onDisappear() {
          recordVideoEvent(.debug, message: "VideoPlayerPost disappeared", sharedVideo: sharedVideo, extra: ["branch": "swiftuiVideoPlayer"])
          handleInlineDisappear(sharedVideo)
        }
        .onChange(of: fullscreen) { val in
          handleFullscreenChange(val, sharedVideo: sharedVideo)
          syncInlineState(sharedVideo)
        }
      }
    }
  }

  /// Recompute this cell's mount state from the coordinator and apply playback. Called from
  /// the `InlineVideoCoordinatorObserver` child (one call per coordinator change, replacing
  /// the four per-property `onChange` handlers that each re-ran the body) and on fullscreen
  /// changes. Assigning `mountPlayer` is a no-op when unchanged, so the heavy body only
  /// re-evaluates on a real mount transition.
  private func syncInlineState(_ sharedVideo: SharedVideo) {
    let desiredMount = shouldMountPlayer
    if mountPlayer != desiredMount { mountPlayer = desiredMount }
    applyInlinePlaybackState(sharedVideo)
  }

  private func openFullscreen(_ sharedVideo: SharedVideo, branch: String) {
    recordVideoEvent(.debug, message: "Inline video tapped", sharedVideo: sharedVideo, extra: ["branch": branch])
    if markAsSeen != nil { Task(priority: .background) { await markAsSeen?() } }
    withAnimation { fullscreen = true }
  }

  /// Inline player layer bound to the shared `AVPlayer`. The fullscreen viewer renders its
  /// own layer on the *same* player, so opening fullscreen never reloads the video — both
  /// layers display one `AVPlayer`. Mounts only when the feed-gating allows it and we're not
  /// already fullscreen (the cover owns the live layer then).
  @ViewBuilder
  func inlineVideoLayer(sharedVideo: SharedVideo, videoSize: CGSize) -> some View {
    Group {
      if mountPlayer && !fullscreen {
        InlineAVPlayerLayerRepresentable(
          player: sharedVideo.player,
          videoGravity: .resizeAspectFill,
          onReadyForDisplay: { handlePlayerReadyForDisplay(sharedVideo) }
        )
      } else {
        Color.clear
      }
    }
    .frame(width: videoSize.width, height: videoSize.height)
    .clipped()
    .fixedSize()
    .mask(RR(12, Color.black))
    .allowsHitTesting(false)
  }

  /// Neutral backdrop shown until the live layer has a real frame. It sits at the BACK of the
  /// ZStack, so the poster (when present) and the video cover it — it only shows through while
  /// there are genuinely no pixels yet (off-center, or a posterless video still warming up).
  /// Gating on `playerReadyForDisplay` (not `mountPlayer`) is what removes the grey flash: the
  /// grey can never appear on TOP of a hiding poster, only behind it.
  @ViewBuilder
  func inlineVideoPlaceholder() -> some View {
    if !playerReadyForDisplay {
      RR(12, Color.primary.opacity(0.06))
        .overlay(
          Image(systemName: "play.circle.fill")
            .fontSize(30)
            .foregroundStyle(.white.opacity(0.45))
        )
        .allowsHitTesting(false)
        .transition(.opacity)
    }
  }

  /// The live layer composited its first frame. Drop the poster now (real pixels are on
  /// screen, so there's no gap) and clear the grey backdrop.
  private func handlePlayerReadyForDisplay(_ sharedVideo: SharedVideo) {
    guard self.sharedVideo == sharedVideo else { return }
    if !playerReadyForDisplay {
      withAnimation(.easeOut(duration: 0.2)) { playerReadyForDisplay = true }
    }
    guard !fullscreen, autoPlayVideos else { return }
    if shouldPlayInline {
      if showInlinePoster {
        scheduleInlinePosterHide(sharedVideo: sharedVideo, reason: "player-ready-active", playAfterHide: true)
      } else {
        startInlinePlaybackIfNeeded(sharedVideo, reason: "player-ready-poster-hidden")
      }
    } else if shouldMountPlayer, showInlinePoster {
      scheduleInlinePosterHide(sharedVideo: sharedVideo, reason: "player-ready-warm", playAfterHide: false)
    }
  }

  @ViewBuilder
  func videoPoster(sharedVideo: SharedVideo, size: CGSize) -> some View {
    if let posterURL = sharedVideo.posterURL, showInlinePoster, !posterUnavailable {
      let request = winstonImageRequest(
        url: posterURL,
        processors: [ImageProcessors.ScaleFixer()],
        priority: .high,
        thumbnail: nil
      )
      URLImage(
        url: posterURL,
        imgRequest: request,
        size: size,
        diagnosticContext: diagnosticContext.map { "\($0):videoPoster" } ?? "videoPoster:\(posterURL.host ?? "unknown")",
        onLoadSucceeded: { handlePosterLoaded(sharedVideo: sharedVideo) },
        onLoadFailed: { hideUnavailablePoster(reason: "failed", url: posterURL, sharedVideo: sharedVideo) },
        onLoadStalled: { hideUnavailablePoster(reason: "stalled", url: posterURL, sharedVideo: sharedVideo) },
        stallTimeout: 2,
        showPlaceholder: false,
        requestImageScaledToFill: true
      )
        .frame(width: size.width, height: size.height)
        .clipped()
        .opacity(showInlinePoster ? 1 : 0)
        .allowsHitTesting(false)
        .onAppear {
          recordVideoEvent(
            .debug,
            message: "Video poster appeared",
            sharedVideo: sharedVideo,
            category: "ui.videoPoster",
            extra: [
              "url": posterURL.absoluteString,
              "size": "\(size.width)x\(size.height)",
              "request": request.description
            ]
          )
        }
    } else {
      Color.clear
        .onAppear {
          recordVideoEvent(
            .debug,
            message: "Video poster not rendered",
            sharedVideo: sharedVideo,
            category: "ui.videoPoster",
            extra: ["reason": videoPosterNotRenderedReason(sharedVideo: sharedVideo)]
          )
        }
    }
  }

  func videoPosterNotRenderedReason(sharedVideo: SharedVideo) -> String {
    if sharedVideo.posterURL == nil { return "missing-poster-url" }
    if posterUnavailable { return "poster-unavailable" }
    if !showInlinePoster { return "poster-hidden" }
    return "unknown"
  }

  func playOverlay() -> some View {
    Image(systemName: "play.fill")
      .foregroundColor(.white.opacity(0.85))
      .fontSize(32)
      .shadow(color: .black.opacity(0.45), radius: 12, y: 8)
      .opacity(autoPlayVideos ? 0 : 1)
      .allowsHitTesting(false)
  }

  func prepareForInlineDisplay(_ sharedVideo: SharedVideo) {
    let cacheKey = SharedVideo.cacheKey(url: sharedVideo.url, size: sharedVideo.size, downloadURL: sharedVideo.downloadURL, posterURL: sharedVideo.posterURL)
    recordVideoEvent(.debug, message: "Preparing inline video", sharedVideo: sharedVideo, extra: ["cacheKeyHash": "\(cacheKey.hashValue)"])
    let identityChanged = activeInlineVideoKey != cacheKey
    if identityChanged {
      activeInlineVideoKey = cacheKey
      posterLoaded = false
      showInlinePoster = true
      posterUnavailable = false
      playerReadyForDisplay = false
      posterHideGeneration = UUID()
      recordVideoEvent(.debug, message: "Inline video identity changed", sharedVideo: sharedVideo, extra: ["cacheKeyHash": "\(cacheKey.hashValue)"])
    }

    // Seed the body's cached mount flag (off-center videos stay false → poster-only).
    let desiredMount = shouldMountPlayer
    if mountPlayer != desiredMount { mountPlayer = desiredMount }

    // Off-center feed videos are poster-only: do NOT touch sharedVideo.player here, since
    // accessing it would create an AVPlayer (and load its HLS asset). Only the mounted
    // video — active inline or fullscreen — sets up playback.
    guard shouldMountPlayer else { return }

    sharedVideo.player.isMuted = muteVideos
    if loopVideos {
      addObserver()
    }
    if (sharedVideo.player.status == .failed) {
      recordVideoEvent(.warning, message: "Inline video player failed before prepare", sharedVideo: sharedVideo)
      resetVideo?(sharedVideo)
    }
    // Cap forward buffering so the active video doesn't buffer aggressively.
    // NOTE: do NOT call AVPlayer.preroll(atRate:) here — it raises
    // NSInvalidArgumentException ("cannot service a preroll request") when the item
    // isn't ready. The active video's play() buffers itself.
    sharedVideo.player.currentItem?.preferredForwardBufferDuration = 2
    if shouldPlayInline {
      if inlineVideoIsRenderable(sharedVideo) {
        scheduleInlinePosterHide(sharedVideo: sharedVideo, reason: "prepare-active-renderable", playAfterHide: true)
      } else {
        sharedVideo.player.pause()
        recordVideoEvent(.debug, message: "Inline autoplay waiting for displayable frame", sharedVideo: sharedVideo)
      }
    } else {
      sharedVideo.player.pause()
      if inlineVideoIsRenderable(sharedVideo), showInlinePoster {
        scheduleInlinePosterHide(sharedVideo: sharedVideo, reason: "prepare-warm-renderable", playAfterHide: false)
      }
    }
  }

  /// Re-evaluate playback against the current coordinator state. Called when the
  /// active video or warm set changes. The poster only returns on disappear.
  func applyInlinePlaybackState(_ sharedVideo: SharedVideo) {
    guard !fullscreen else { return }
    guard shouldMountPlayer else {
      if sharedVideo.isPlayerLoaded {
        // Don't create a player just to pause it — only an already-mounted one needs pausing.
        sharedVideo.player.pause()
      }
      return
    }

    if shouldPlayInline {
      sharedVideo.player.isMuted = muteVideos
      sharedVideo.player.currentItem?.preferredForwardBufferDuration = 2
      if inlineVideoIsRenderable(sharedVideo) {
        if showInlinePoster {
          scheduleInlinePosterHide(sharedVideo: sharedVideo, reason: "play-state-active-renderable", playAfterHide: true)
        } else {
          startInlinePlaybackIfNeeded(sharedVideo, reason: "play-state-active-poster-hidden")
        }
      } else {
        sharedVideo.player.pause()
        recordVideoEvent(.debug, message: "Inline playback deferred until frame is displayable", sharedVideo: sharedVideo)
      }
    } else {
      sharedVideo.player.isMuted = muteVideos
      sharedVideo.player.currentItem?.preferredForwardBufferDuration = 1
      sharedVideo.player.pause()
      if inlineVideoIsRenderable(sharedVideo), showInlinePoster {
        scheduleInlinePosterHide(sharedVideo: sharedVideo, reason: "play-state-warm-renderable", playAfterHide: false)
      }
    }
  }

  func handlePosterLoaded(sharedVideo: SharedVideo) {
    let cacheKey = SharedVideo.cacheKey(url: sharedVideo.url, size: sharedVideo.size, downloadURL: sharedVideo.downloadURL, posterURL: sharedVideo.posterURL)
    guard self.sharedVideo == sharedVideo else {
      recordVideoEvent(.debug, message: "Poster load callback ignored for stale video", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["cacheKeyHash": "\(cacheKey.hashValue)"])
      return
    }
    activeInlineVideoKey = cacheKey
    posterLoaded = true
    recordVideoEvent(.debug, message: "Poster load callback accepted", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["cacheKeyHash": "\(cacheKey.hashValue)"])
    guard autoPlayVideos, shouldMountPlayer, sharedVideo.isPlayerLoaded, inlineVideoIsRenderable(sharedVideo), showInlinePoster else {
      return
    }
    scheduleInlinePosterHide(sharedVideo: sharedVideo, reason: "poster-loaded-renderable", playAfterHide: shouldPlayInline)
  }

  func startInlinePlaybackIfNeeded(_ sharedVideo: SharedVideo, reason: String) {
    guard !fullscreen, shouldPlayInline, sharedVideo.isPlayerLoaded else { return }
    sharedVideo.player.isMuted = muteVideos
    sharedVideo.player.play()
    recordVideoEvent(.debug, message: "Inline playback started", sharedVideo: sharedVideo, extra: ["reason": reason])
  }

  func scheduleInlinePosterHide(sharedVideo: SharedVideo, reason: String, playAfterHide: Bool, attempt: Int = 0) {
    guard shouldMountPlayer, sharedVideo.isPlayerLoaded else {
      recordVideoEvent(.debug, message: "Inline poster hide not scheduled", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["reason": reason, "skip": "player-not-mounted", "attempt": "\(attempt)"])
      return
    }
    let cacheKey = SharedVideo.cacheKey(url: sharedVideo.url, size: sharedVideo.size, downloadURL: sharedVideo.downloadURL, posterURL: sharedVideo.posterURL)
    let generation = UUID()
    posterHideGeneration = generation
    recordVideoEvent(.debug, message: "Scheduling inline poster hide", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["generation": generation.uuidString, "cacheKeyHash": "\(cacheKey.hashValue)", "attempt": "\(attempt)", "reason": reason, "playAfterHide": "\(playAfterHide)"])
    doThisAfter(attempt == 0 ? 0.6 : 0.25) {
      guard posterHideGeneration == generation else {
        recordVideoEvent(.debug, message: "Inline poster hide skipped", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["reason": reason, "skip": "generation-mismatch", "generation": generation.uuidString])
        return
      }
      guard self.sharedVideo == sharedVideo else {
        recordVideoEvent(.debug, message: "Inline poster hide skipped", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["reason": reason, "skip": "stale-video", "generation": generation.uuidString])
        return
      }
      guard activeInlineVideoKey == cacheKey else {
        recordVideoEvent(.debug, message: "Inline poster hide skipped", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["reason": reason, "skip": "active-key-mismatch", "generation": generation.uuidString, "expectedKeyHash": "\(cacheKey.hashValue)", "activeKeyHash": activeInlineVideoKey.map { "\($0.hashValue)" } ?? "nil"])
        return
      }
      guard autoPlayVideos else {
        recordVideoEvent(.debug, message: "Inline poster hide skipped", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["reason": reason, "skip": "autoplay-disabled", "generation": generation.uuidString])
        return
      }
      guard !fullscreen else {
        recordVideoEvent(.debug, message: "Inline poster hide skipped", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["reason": reason, "skip": "fullscreen", "generation": generation.uuidString])
        return
      }
      guard inlineVideoIsRenderable(sharedVideo) else {
        if attempt < 8 {
          recordVideoEvent(.debug, message: "Inline poster hide delayed", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["reason": reason, "skip": "video-not-renderable", "generation": generation.uuidString, "attempt": "\(attempt)", "playAfterHide": "\(playAfterHide)"])
          scheduleInlinePosterHide(sharedVideo: sharedVideo, reason: reason, playAfterHide: playAfterHide, attempt: attempt + 1)
        } else {
          recordVideoEvent(.warning, message: "Inline poster kept visible because video was not renderable", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["reason": reason, "generation": generation.uuidString, "attempt": "\(attempt)", "playAfterHide": "\(playAfterHide)"])
        }
        return
      }
      let hadPoster = showInlinePoster
      recordVideoEvent(.debug, message: "Inline poster hide executing", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["generation": generation.uuidString, "attempt": "\(attempt)", "reason": reason, "playAfterHide": "\(playAfterHide)", "hadPoster": "\(hadPoster)"])
      if hadPoster {
        withAnimation(.easeOut(duration: 0.08)) {
          showInlinePoster = false
        }
      }
      guard playAfterHide else { return }
      doThisAfter(hadPoster ? 0.07 : 0) {
        startInlinePlaybackIfNeeded(sharedVideo, reason: "poster-hidden:\(reason)")
      }
    }
  }

  func inlineVideoIsRenderable(_ sharedVideo: SharedVideo) -> Bool {
    // The layer must have composited a real frame, otherwise hiding the poster reveals an
    // empty/grey gap (the flash). isReadyForDisplay is the authoritative signal for this.
    guard sharedVideo.isPlayerLoaded, playerReadyForDisplay else { return false }
    let player = sharedVideo.player
    let currentTime = CMTimeGetSeconds(player.currentTime())
    let hasAdvanced = currentTime.isFinite && currentTime > 0.05
    let itemReady = player.currentItem?.status == .readyToPlay
    let isPlaying = player.timeControlStatus == .playing || player.rate > 0
    return itemReady && (isPlaying ? hasAdvanced : shouldMountPlayer)
  }

  func handleInlineDisappear(_ sharedVideo: SharedVideo) {
    posterHideGeneration = UUID()
    removeObserver()
    if sharedVideo.isPlayerLoaded {
      sharedVideo.player.pause()
    }
    // If the video that just scrolled off was the active one, drop it so a stale key
    // doesn't keep an off-screen player "active". The feed re-elects the centered video.
    if InlineVideoCoordinator.shared.isActive(feedItemKey) {
      InlineVideoCoordinator.shared.setActive(nil)
    }
  }

  func hideUnavailablePoster(reason: String, url: URL, sharedVideo: SharedVideo) {
    let cacheKey = SharedVideo.cacheKey(url: sharedVideo.url, size: sharedVideo.size, downloadURL: sharedVideo.downloadURL, posterURL: sharedVideo.posterURL)
    if feedItemKey != nil, FeedScrollWorkCoordinator.shared.shouldDeferWork {
      FeedScrollWorkCoordinator.shared.performWhenIdle(key: "video.posterUnavailable.\(cacheKey.hashValue)") {
        hideUnavailablePoster(reason: reason, url: url, sharedVideo: sharedVideo)
      }
      return
    }
    guard self.sharedVideo == sharedVideo else {
      recordVideoEvent(.debug, message: "Poster unavailable callback ignored", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["reason": "stale-video", "url": url.absoluteString])
      return
    }
    guard showInlinePoster, !posterUnavailable else {
      recordVideoEvent(.debug, message: "Poster unavailable callback ignored", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["reason": "poster-not-visible-or-already-unavailable", "url": url.absoluteString])
      return
    }
    guard playerReadyForDisplay else {
      recordVideoEvent(
        .warning,
        message: "Keeping unavailable video poster surface until player has a frame",
        sharedVideo: sharedVideo,
        category: "ui.videoPoster",
        extra: [
          "reason": reason,
          "url": url.absoluteString,
          "playerReadyForDisplay": "\(playerReadyForDisplay)"
        ]
      )
      refreshInlineVideoSurface(reason: "poster-\(reason)-needs-frame", sharedVideo: sharedVideo)
      return
    }
    posterUnavailable = true
    showInlinePoster = false
    posterHideGeneration = UUID()
    recordVideoEvent(
      .warning,
      message: "Hiding stalled video poster",
      sharedVideo: sharedVideo,
      category: "ui.videoPoster",
      extra: [
        "reason": reason,
        "url": url.absoluteString,
        "playerReadyForDisplay": "\(playerReadyForDisplay)"
      ]
    )
    // The poster is cosmetic. If the live AVPlayerLayer has already composited a real
    // frame, the video is on screen and dropping the poster needs no surface work —
    // refreshing here (which bumps inlineVideoRefreshID → tears down/rebuilds the layer)
    // just thrashes a playing player (playerLayerMake/Update hitches). Only kick the
    // surface when no real frame has shown yet, so a poster→grey gap can't persist.
    guard !playerReadyForDisplay else { return }
    refreshInlineVideoSurface(reason: "poster-\(reason)", sharedVideo: sharedVideo)
  }

  func refreshInlineVideoSurface(reason: String, sharedVideo: SharedVideo) {
    // Recreating the AVPlayerLayer view (via the .id change below) is expensive. Skip it
    // while scrolling; stalled posters on a fast media feed would otherwise thrash layer
    // teardown/recreation every frame.
    guard !InlineVideoCoordinator.shared.isScrolling else { return }
    // Off-center videos have no mounted player to refresh; touching it would create one.
    guard shouldMountPlayer else { return }
    inlineVideoRefreshID = UUID()
    if !autoPlayVideos && !fullscreen {
      sharedVideo.player.pause()
      sharedVideo.player.currentItem?.step(byCount: 1)
    }
    AppDiagnostics.asyncRecord(
      .info,
      category: "ui.video",
      message: "Refreshing inline video surface",
      metadata: [
        "reason": reason,
        "context": diagnosticContext ?? "nil",
        "playerStatus": videoStatus(sharedVideo.player.status),
        "itemStatus": itemStatus(sharedVideo.player.currentItem?.status),
        "posterUnavailable": "\(posterUnavailable)"
      ]
    )
  }

  func handleFullscreenChange(_ val: Bool, sharedVideo: SharedVideo) {
    // Player is mounted by the time fullscreen toggles, so this access is safe and cheap.
    let hasAudio = sharedVideo.player.currentItem?.tracks.contains(where: { $0.assetTrack?.mediaType == AVMediaType.audio })
    recordVideoEvent(.debug, message: "Fullscreen state changed", sharedVideo: sharedVideo, extra: ["fullscreen": "\(val)", "hasAudio": hasAudio.map { "\($0)" } ?? "nil"])
    if !firstFullscreen {
      firstFullscreen = true
      sharedVideo.player.isMuted = muteVideos
      sharedVideo.player.play()
      recordVideoEvent(.debug, message: "Fullscreen initial playback started", sharedVideo: sharedVideo)
    }
    if !val && !autoPlayVideos {
      sharedVideo.player.seek(to: .zero)
      sharedVideo.player.pause()
      firstFullscreen = false
      showInlinePoster = true
    }

    if pauseBackgroundAudioOnFullscreen && sharedVideo.player.isMuted == false && hasAudio == true {
      Task(priority: .background) {
        setAudioToMixWithOthers(val)
      }
    }

    sharedVideo.player.volume = val ? 1.0 : 0.0
  }
  
  func addObserver() {
    if let sharedVideo = sharedVideo {
      let cacheKey = SharedVideo.cacheKey(url: sharedVideo.url, size: sharedVideo.size, downloadURL: sharedVideo.downloadURL, posterURL: sharedVideo.posterURL)
      guard observedVideoKey != cacheKey else {
        recordVideoEvent(.debug, message: "Video observers already installed", sharedVideo: sharedVideo, extra: ["cacheKeyHash": "\(cacheKey.hashValue)"])
        return
      }
      observedVideoKey = cacheKey
      recordVideoEvent(.debug, message: "Installing video observers", sharedVideo: sharedVideo, extra: ["cacheKeyHash": "\(cacheKey.hashValue)"])

      let endObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime,
        object: sharedVideo.player.currentItem,
        queue: nil) { notif in
          if AppDiagnostics.isEnabled(.debug, category: "ui.video") {
            AppDiagnostics.asyncRecord(.debug, category: "ui.video", message: "AVPlayer item ended", metadata: ["cacheKeyHash": "\(cacheKey.hashValue)", "context": diagnosticContext ?? "nil"])
          }
          Task(priority: .background) {
            sharedVideo.player.seek(to: .zero)
            sharedVideo.player.play()
          }
        }
      
      let failedObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemFailedToPlayToEndTime,
        object: sharedVideo.player.currentItem,
        queue: nil) { notif in
          AppDiagnostics.asyncRecord(.warning, category: "ui.video", message: "AVPlayer item failed to play to end", metadata: ["cacheKeyHash": "\(cacheKey.hashValue)", "context": diagnosticContext ?? "nil"])
          Task(priority: .background) {
            resetVideo?(sharedVideo)
          }
        }
      
      let stalledObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemPlaybackStalled,
        object: sharedVideo.player.currentItem,
        queue: nil) { notif in
          AppDiagnostics.asyncRecord(.warning, category: "ui.video", message: "AVPlayer item playback stalled", metadata: ["cacheKeyHash": "\(cacheKey.hashValue)", "context": diagnosticContext ?? "nil"])
          Task(priority: .background) {
            resetVideo?(sharedVideo)
          }
        }
      videoObservers = [endObserver, failedObserver, stalledObserver]
    }
  }
  
  func videoStatus(_ status: AVPlayer.Status) -> String {
    switch status {
    case .unknown:
      return "unknown"
    case .readyToPlay:
      return "readyToPlay"
    case .failed:
      return "failed"
    @unknown default:
      return "unknown-default"
    }
  }

  func itemStatus(_ status: AVPlayerItem.Status?) -> String {
    switch status {
    case .unknown:
      return "unknown"
    case .readyToPlay:
      return "readyToPlay"
    case .failed:
      return "failed"
    case nil:
      return "nil"
    @unknown default:
      return "unknown-default"
    }
  }

  func removeObserver() {
    if let sharedVideo {
      recordVideoEvent(.debug, message: "Removing video observers", sharedVideo: sharedVideo, extra: ["observerCount": "\(videoObservers.count)"])
    }
    videoObservers.forEach { NotificationCenter.default.removeObserver($0) }
    videoObservers = []
    observedVideoKey = nil
  }

  func recordVideoEvent(
    _ level: DiagnosticLevel,
    message: @autoclosure () -> String,
    sharedVideo: SharedVideo,
    category: String = "ui.video",
    extra: @autoclosure () -> [String: String] = [:]
  ) {
    // Gate before building the (expensive) diagnostics metadata: during scroll these debug
    // events fire constantly and `asyncRecord` would discard them anyway in production.
    guard AppDiagnostics.isEnabled(level, category: category) else { return }
    AppDiagnostics.asyncRecord(
      level,
      category: category,
      message: message(),
      metadata: videoDiagnosticsMetadata(sharedVideo: sharedVideo).merging(extra()) { _, new in new }
    )
  }

  func videoDiagnosticsMetadata(sharedVideo: SharedVideo) -> [String: String] {
    let cacheKey = SharedVideo.cacheKey(url: sharedVideo.url, size: sharedVideo.size, downloadURL: sharedVideo.downloadURL, posterURL: sharedVideo.posterURL)
    let playerLoaded = sharedVideo.isPlayerLoaded
    let player = playerLoaded ? sharedVideo.player : nil
    let item = player?.currentItem
    let renderedSize = renderedVideoSize
    let coordinator = InlineVideoCoordinator.shared
    return [
      "context": diagnosticContext ?? "nil",
      "feedItemKey": feedItemKey ?? "nil",
      "compact": "\(compact)",
      "contentWidth": "\(contentWidth)",
      "sourceURL": sharedVideo.url.absoluteString,
      "downloadURL": sharedVideo.downloadURL?.absoluteString ?? "nil",
      "posterURL": sharedVideo.posterURL?.absoluteString ?? "nil",
      "videoSize": "\(sharedVideo.size.width)x\(sharedVideo.size.height)",
      "renderedVideoSize": "\(renderedSize.width)x\(renderedSize.height)",
      "cacheKeyHash": "\(cacheKey.hashValue)",
      "activeKeyHash": activeInlineVideoKey.map { "\($0.hashValue)" } ?? "nil",
      "preparedKeyHash": preparedInlineVideoKey.map { "\($0.hashValue)" } ?? "nil",
      "observedKeyHash": observedVideoKey.map { "\($0.hashValue)" } ?? "nil",
      "isActive": "\(coordinator.isActive(feedItemKey))",
      "isWarm": "\(coordinator.isWarm(feedItemKey))",
      "isScrolling": "\(coordinator.isScrolling)",
      "isFastScrolling": "\(coordinator.isFastScrolling)",
      "mountPlayer": "\(mountPlayer)",
      "shouldMountPlayer": "\(shouldMountPlayer)",
      "shouldPlayInline": "\(shouldPlayInline)",
      "playerLoaded": "\(playerLoaded)",
      "playerReadyForDisplay": "\(playerReadyForDisplay)",
      "showInlinePoster": "\(showInlinePoster)",
      "posterLoaded": "\(posterLoaded)",
      "posterUnavailable": "\(posterUnavailable)",
      "autoPlay": "\(autoPlayVideos)",
      "loop": "\(loopVideos)",
      "fullscreen": "\(fullscreen)",
      "scenePhase": scenePhaseDescription(scenePhase),
      "inlineVideoRefreshID": inlineVideoRefreshID.uuidString,
      "playerStatus": player.map { videoStatus($0.status) } ?? "notLoaded",
      "timeControlStatus": player.map { timeControlStatus($0.timeControlStatus) } ?? "notLoaded",
      "playerRate": player.map { "\($0.rate)" } ?? "notLoaded",
      "itemStatus": itemStatus(item?.status),
      "itemLikelyToKeepUp": item.map { "\($0.isPlaybackLikelyToKeepUp)" } ?? "nil",
      "itemBufferEmpty": item.map { "\($0.isPlaybackBufferEmpty)" } ?? "nil",
      "loadedTimeRanges": "\(item?.loadedTimeRanges.count ?? 0)",
      "currentTime": player.map { "\(CMTimeGetSeconds($0.currentTime()))" } ?? "notLoaded",
      "duration": item.map { "\(CMTimeGetSeconds($0.duration))" } ?? "nil"
    ]
  }

  func scenePhaseDescription(_ phase: ScenePhase) -> String {
    switch phase {
    case .active:
      return "active"
    case .inactive:
      return "inactive"
    case .background:
      return "background"
    @unknown default:
      return "unknown"
    }
  }

  func timeControlStatus(_ status: AVPlayer.TimeControlStatus) -> String {
    switch status {
    case .paused:
      return "paused"
    case .waitingToPlayAtSpecifiedRate:
      return "waitingToPlayAtSpecifiedRate"
    case .playing:
      return "playing"
    @unknown default:
      return "unknown"
    }
  }
}

struct InlineAVPlayerLayerRepresentable: UIViewRepresentable {
  let player: AVPlayer
  let videoGravity: AVLayerVideoGravity
  /// Fires (on the main actor) once the layer has actually composited its first frame.
  /// Used to hold the poster until real pixels are on screen, avoiding the grey/blank flash
  /// during the poster→video handoff.
  var onReadyForDisplay: (() -> Void)? = nil

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> PlayerLayerView {
    ScrollPerfProbe.shared.bump("playerLayerMake")
    let view = PlayerLayerView()
    view.backgroundColor = .clear
    view.playerLayer.player = player
    view.playerLayer.videoGravity = videoGravity
    context.coordinator.onReadyForDisplay = onReadyForDisplay
    context.coordinator.observe(view.playerLayer)
    return view
  }

  func updateUIView(_ uiView: PlayerLayerView, context: Context) {
    ScrollPerfProbe.shared.bump("playerLayerUpdate")
    context.coordinator.onReadyForDisplay = onReadyForDisplay
    if uiView.playerLayer.player !== player {
      uiView.playerLayer.player = player
    }
    if uiView.playerLayer.videoGravity != videoGravity {
      uiView.playerLayer.videoGravity = videoGravity
    }
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
    override class var layerClass: AnyClass {
      AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
      layer as! AVPlayerLayer
    }
  }
}

/// Tiny `Color.clear` view whose only job is to subscribe to the `InlineVideoCoordinator`'s
/// `@Observable` state. Because Observation tracking is per-view-body, keeping these
/// `onChange` handlers HERE (rather than on the heavy `VideoPlayerPost` body) means a global
/// coordinator tick (e.g. `warmVideoKeys` updating as scroll settles) re-evaluates
/// only this trivial view across every visible video cell — the expensive video body stays
/// put unless its own derived mount state actually changes.
private struct InlineVideoCoordinatorObserver: View {
  let onCoordinatorChange: () -> Void

  var body: some View {
    let coordinator = InlineVideoCoordinator.shared
    Color.clear
      .allowsHitTesting(false)
      .onChange(of: coordinator.activeVideoKey) { _, _ in onCoordinatorChange() }
      .onChange(of: coordinator.warmVideoKeys) { _, _ in onCoordinatorChange() }
  }
}

struct FullScreenVP: View {
  var sharedVideo: SharedVideo
  var closeAction: (() -> Void)? = nil
  @Environment(\.dismiss) private var dismiss
  @Default(.VideoDefSettings) private var videoDefSettings
  @State private var cancelDrag: Bool?
  @State private var dragAxis: Axis?
  @State private var dragOffset: CGSize?
  @State private var isPinching: Bool = false
  @State private var drag: CGSize = .zero
  @State private var scale: CGFloat = 1.0
  @State private var anchor: UnitPoint = .zero
  @State private var offset: CGSize = .zero
  @State private var altSize: CGSize = .zero
  @State private var videoProgress: Double = 0
  @State private var videoScrubStartProgress: Double?
  @State private var wasPlayingBeforeScrub = false
  @State private var timeObserver: Any?
  @State private var isPlaying = false
  @State private var isMuted = false

  private enum Axis {
    case horizontal
    case vertical
  }

  var body: some View {
    let interpolate = interpolatorBuilder([0, 100], value: abs(drag.height))
    ZStack {
      InlineAVPlayerLayerRepresentable(player: sharedVideo.player, videoGravity: .resizeAspect)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .contentShape(Rectangle())

      Color.clear
        .contentShape(Rectangle())
        .gesture(fullscreenDragGesture)

      VideoLiquidControls(
        progress: videoProgress,
        isPlaying: isPlaying,
        isMuted: isMuted,
        togglePlay: togglePlayback,
        toggleMute: toggleMute,
        scrub: scrubTimeline,
        finishScrub: finishVideoScrub
      )
    }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black)
      .background(
        sharedVideo.size != .zero
        ? nil
        : GeometryReader { geo in
          Color.clear
            .onAppear { altSize = geo.size }
            .onChange(of: geo.size) { _, newValue in altSize = newValue }
        }
      )
    //      .pinchToZoom(size: sharedVideo.size == .zero ? altSize : sharedVideo.size, isPinching: $isPinching, scale: $scale, anchor: $anchor, offset: $offset)
      .scaleEffect(interpolate([1, 0.9], true))
      .offset(cancelDrag ?? false ? .zero : drag)
      .onAppear {
        sharedVideo.player.isMuted = videoDefSettings.mute
        isMuted = sharedVideo.player.isMuted
        isPlaying = sharedVideo.player.rate != 0
        installVideoTimeObserver()
      }
      .onDisappear {
        removeVideoTimeObserver()
      }
  }

  private var fullscreenDragGesture: some Gesture {
    DragGesture(minimumDistance: 10)
      .onChanged { val in
        guard scale == 1.0 else { return }
        if dragAxis == nil || dragOffset == nil {
          dragOffset = val.translation
          if abs(val.translation.width) > abs(val.translation.height) {
            dragAxis = .horizontal
            cancelDrag = true
            startVideoScrub()
          } else if abs(val.translation.height) > abs(val.translation.width) {
            dragAxis = .vertical
            cancelDrag = false
          }
        }

        guard let dragAxis else { return }

        if dragAxis == .horizontal {
          updateVideoScrub(translationWidth: val.translation.width)
        } else {
          var transaction = Transaction()
          transaction.isContinuous = true
          transaction.animation = .interpolatingSpring(stiffness: 1000, damping: 100, initialVelocity: 0)

          let endPos = val.translation
          withTransaction(transaction) {
            drag = endPos
          }
        }
      }
      .onEnded { val in
        let prevCancelDrag = cancelDrag
        cancelDrag = nil
        dragAxis = nil
        dragOffset = nil

        if prevCancelDrag == true {
          finishVideoScrub()
          return
        }

        if prevCancelDrag == nil { return }
        let shouldClose = abs(val.translation.width) > 100 || abs(val.translation.height) > 100
        withAnimation(.interpolatingSpring(stiffness: 200, damping: 20, initialVelocity: 0)) {
          drag = .zero
          if shouldClose {
            closeViewer()
          }
        }
      }
  }

  private func closeViewer() {
    if let closeAction {
      closeAction()
    } else {
      dismiss()
    }
  }

  private var videoDuration: TimeInterval {
    guard let duration = sharedVideo.player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else {
      return 0
    }
    return duration
  }

  private var currentVideoProgress: Double {
    let duration = videoDuration
    guard duration > 0 else { return 0 }
    let currentTime = sharedVideo.player.currentTime().seconds
    guard currentTime.isFinite else { return 0 }
    return min(max(currentTime / duration, 0), 1)
  }

  private func startVideoScrub() {
    guard videoDuration > 0, videoScrubStartProgress == nil else { return }
    videoScrubStartProgress = currentVideoProgress
    videoProgress = videoScrubStartProgress ?? videoProgress
    wasPlayingBeforeScrub = sharedVideo.player.rate != 0
    sharedVideo.player.pause()
    isPlaying = false
  }

  private func updateVideoScrub(translationWidth: CGFloat) {
    guard videoDuration > 0 else { return }
    let startProgress = videoScrubStartProgress ?? currentVideoProgress
    videoScrubStartProgress = startProgress
    seekVideo(to: min(max(startProgress + Double(translationWidth / max(.screenW, 1)), 0), 1), interactive: true)
  }

  private func finishVideoScrub() {
    videoScrubStartProgress = nil
    if wasPlayingBeforeScrub {
      sharedVideo.player.play()
      isPlaying = true
    }
    wasPlayingBeforeScrub = false
  }

  private func scrubTimeline(_ progress: Double) {
    if videoScrubStartProgress == nil {
      startVideoScrub()
    }
    seekVideo(to: progress, interactive: true)
  }

  private func togglePlayback() {
    if sharedVideo.player.rate == 0 {
      sharedVideo.player.play()
      isPlaying = true
    } else {
      sharedVideo.player.pause()
      isPlaying = false
    }
  }

  private func toggleMute() {
    sharedVideo.player.isMuted.toggle()
    isMuted = sharedVideo.player.isMuted
  }

  private func seekVideo(to progress: Double, interactive: Bool = false) {
    let duration = videoDuration
    guard duration > 0 else { return }
    let clampedProgress = min(max(progress, 0), 1)
    videoProgress = clampedProgress
    let seconds = clampedProgress * duration
    let tolerance = interactive ? CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600) : CMTime.zero
    sharedVideo.player.currentItem?.cancelPendingSeeks()
    sharedVideo.player.seek(
      to: CMTime(seconds: seconds, preferredTimescale: 600),
      toleranceBefore: tolerance,
      toleranceAfter: tolerance
    )
  }

  private func installVideoTimeObserver() {
    removeVideoTimeObserver()
    videoProgress = currentVideoProgress
    timeObserver = sharedVideo.player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
      queue: .main
    ) { _ in
      if videoScrubStartProgress == nil {
        videoProgress = currentVideoProgress
      }
      isPlaying = sharedVideo.player.rate != 0
      isMuted = sharedVideo.player.isMuted
    }
  }

  private func removeVideoTimeObserver() {
    if let timeObserver {
      sharedVideo.player.removeTimeObserver(timeObserver)
      self.timeObserver = nil
    }
  }
}

private struct VideoLiquidControls: View {
  let progress: Double
  let isPlaying: Bool
  let isMuted: Bool
  let togglePlay: () -> Void
  let toggleMute: () -> Void
  let scrub: (Double) -> Void
  let finishScrub: () -> Void

  var body: some View {
    VStack {
      Spacer()

      HStack(spacing: 14) {
        VideoLiquidButton(icon: isPlaying ? "pause.fill" : "play.fill", accessibilityLabel: isPlaying ? "Pause video" : "Play video", action: togglePlay)

        VideoTimelineScrubber(progress: progress, scrub: scrub, finishScrub: finishScrub)
          .frame(height: 44)

        AirPlayRoutePicker()
          .frame(width: 44, height: 44)
          .background(Circle().fill(.ultraThinMaterial))
          .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))

        VideoLiquidButton(icon: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityLabel: isMuted ? "Unmute video" : "Mute video", action: toggleMute)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(
        Capsule(style: .continuous)
          .fill(.ultraThinMaterial)
          .overlay(Capsule(style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
          .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
      )
      .padding(.horizontal, 16)
      .padding(.bottom, 36)
    }
    .foregroundStyle(.white)
  }
}

private struct VideoLiquidButton: View {
  let icon: String
  let accessibilityLabel: LocalizedStringKey
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .fontSize(17, .semibold)
        .frame(width: 44, height: 44)
        .background(Circle().fill(.white.opacity(0.12)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
  }
}

private struct VideoTimelineScrubber: View {
  let progress: Double
  let scrub: (Double) -> Void
  let finishScrub: () -> Void

  var body: some View {
    GeometryReader { proxy in
      let clampedProgress = min(max(progress, 0), 1)
      ZStack(alignment: .leading) {
        Capsule(style: .continuous)
          .fill(.white.opacity(0.18))
          .frame(height: 6)
        Capsule(style: .continuous)
          .fill(.white.opacity(0.92))
          .frame(width: max(6, proxy.size.width * clampedProgress), height: 6)
        Circle()
          .fill(.white)
          .frame(width: 16, height: 16)
          .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
          .offset(x: min(max(proxy.size.width * clampedProgress - 8, 0), max(proxy.size.width - 16, 0)))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { val in
            scrub(min(max(Double(val.location.x / max(proxy.size.width, 1)), 0), 1))
          }
          .onEnded { _ in
            finishScrub()
          }
      )
    }
  }
}

private struct AirPlayRoutePicker: UIViewRepresentable {
  func makeUIView(context: Context) -> AVRoutePickerView {
    let routePicker = AVRoutePickerView()
    routePicker.prioritizesVideoDevices = true
    routePicker.tintColor = .white
    routePicker.activeTintColor = .white
    routePicker.backgroundColor = .clear
    return routePicker
  }

  func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
    uiView.tintColor = .white
    uiView.activeTintColor = .white
  }
}

struct AVPlayerRepresentable: UIViewRepresentable {
  @Binding var fullscreen: Bool
  var autoPlayVideos: Bool
  let player: AVPlayer
  let aspect: AVLayerVideoGravity
  var controller: UIViewController

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    let playerController = NiceAVPlayer(fullscreen: $fullscreen, autoPlayVideos: autoPlayVideos)
    playerController.allowsVideoFrameAnalysis = false
    playerController.player = player
    playerController.videoGravity = aspect

    context.coordinator.controller = playerController
    controller.addChild(playerController)
    playerController.view.frame = view.bounds
    view.addSubview(playerController.view)
    playerController.didMove(toParent: controller)
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    if AppDiagnostics.isEnabled(.debug, category: "ui.video.playerView") {
      AppDiagnostics.asyncRecord(
        .debug,
        category: "ui.video.playerView",
        message: "AVPlayerRepresentable makeUIView",
        metadata: AVPlayerRepresentable.playerViewMetadata(
          player: player,
          view: view,
          extra: [
            "autoPlay": autoPlayVideos ? "true" : "false",
            "aspect": aspect.rawValue
          ]
        )
      )
    }
    return view
  }

  func updateUIView(_ view: UIView, context: Context) {
    if AppDiagnostics.isEnabled(.debug, category: "ui.video.playerView") {
      AppDiagnostics.asyncRecord(
        .debug,
        category: "ui.video.playerView",
        message: "AVPlayerRepresentable updateUIView",
        metadata: AVPlayerRepresentable.playerViewMetadata(
          player: player,
          view: view,
          extra: [
            "autoPlay": autoPlayVideos ? "true" : "false",
            "fullscreen": fullscreen ? "true" : "false",
            "aspect": aspect.rawValue
          ]
        )
      )
    }
    if let playerController = context.coordinator.controller, playerController.autoPlayVideos != autoPlayVideos {
      playerController.autoPlayVideos = autoPlayVideos
    }
    if fullscreen {
      context.coordinator.controller?.enterFullScreen(animated: true)
    }
  }

  static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
    if AppDiagnostics.isEnabled(.debug, category: "ui.video.playerView") {
      AppDiagnostics.asyncRecord(
        .debug,
        category: "ui.video.playerView",
        message: "AVPlayerRepresentable dismantleUIView",
        metadata: playerViewMetadata(player: coordinator.controller?.player, view: uiView)
      )
    }
    coordinator.controller?.willMove(toParent: nil)
    coordinator.controller?.view.removeFromSuperview()
    coordinator.controller?.removeFromParent()
    coordinator.controller = nil
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  class Coordinator: NSObject {
    var controller: NiceAVPlayer? = nil
  }

  static func playerViewMetadata(player: AVPlayer?, view: UIView?, extra: [String: String] = [:]) -> [String: String] {
    let item = player?.currentItem
    let playerStatus = player.map { playerStatusDescription($0.status) } ?? "nil"
    let timeControlStatus = player.map { timeControlStatusDescription($0.timeControlStatus) } ?? "nil"
    let playerRate = player.map { "\($0.rate)" } ?? "nil"
    let itemStatus = item.map { itemStatusDescription($0.status) } ?? "nil"
    let itemLikelyToKeepUp = item.map { "\($0.isPlaybackLikelyToKeepUp)" } ?? "nil"
    let itemBufferEmpty = item.map { "\($0.isPlaybackBufferEmpty)" } ?? "nil"
    let loadedTimeRanges = "\(item?.loadedTimeRanges.count ?? 0)"
    let currentTime = player.map { "\(CMTimeGetSeconds($0.currentTime()))" } ?? "nil"
    let duration = item.map { "\(CMTimeGetSeconds($0.duration))" } ?? "nil"
    let viewBounds = view.map { "\($0.bounds.width)x\($0.bounds.height)" } ?? "nil"
    let viewFrame = view.map { "\($0.frame.width)x\($0.frame.height)" } ?? "nil"
    let viewWindow = view?.window == nil ? "nil" : "set"

    var metadata: [String: String] = [
      "playerStatus": playerStatus,
      "timeControlStatus": timeControlStatus,
      "playerRate": playerRate,
      "itemStatus": itemStatus,
      "itemLikelyToKeepUp": itemLikelyToKeepUp,
      "itemBufferEmpty": itemBufferEmpty,
      "loadedTimeRanges": loadedTimeRanges,
      "currentTime": currentTime,
      "duration": duration,
      "viewBounds": viewBounds,
      "viewFrame": viewFrame,
      "viewWindow": viewWindow
    ]
    metadata.merge(extra) { _, new in new }
    return metadata
  }

  static func playerStatusDescription(_ status: AVPlayer.Status) -> String {
    switch status {
    case .unknown:
      return "unknown"
    case .readyToPlay:
      return "readyToPlay"
    case .failed:
      return "failed"
    @unknown default:
      return "unknown"
    }
  }

  static func itemStatusDescription(_ status: AVPlayerItem.Status) -> String {
    switch status {
    case .unknown:
      return "unknown"
    case .readyToPlay:
      return "readyToPlay"
    case .failed:
      return "failed"
    @unknown default:
      return "unknown"
    }
  }

  static func timeControlStatusDescription(_ status: AVPlayer.TimeControlStatus) -> String {
    switch status {
    case .paused:
      return "paused"
    case .waitingToPlayAtSpecifiedRate:
      return "waitingToPlayAtSpecifiedRate"
    case .playing:
      return "playing"
    @unknown default:
      return "unknown"
    }
  }
}

class NiceAVPlayer: AVPlayerViewController, AVPlayerViewControllerDelegate {
  @Binding var fullscreen: Bool
  var autoPlayVideos: Bool
  var ida = UUID().uuidString
  var gone = true
  @Default(.VideoDefSettings) private var videoDefSettings
  override open var prefersStatusBarHidden: Bool {
    return true
  }

  init(fullscreen: Binding<Bool>, autoPlayVideos: Bool) {
    self._fullscreen = fullscreen
    self.autoPlayVideos = autoPlayVideos
    super.init(nibName: nil, bundle: nil)
    self.delegate = self
    showsPlaybackControls = false
  }

  required init?(coder aDecoder: NSCoder) {
    self.autoPlayVideos = false
    self._fullscreen = Binding(get: { true }, set: { _, _ in return })
    super.init(coder: aDecoder)
  }

  private func diagnosticsMetadata(extra: [String: String] = [:]) -> [String: String] {
    var metadata: [String: String] = [
      "autoPlay": autoPlayVideos ? "true" : "false",
      "gone": gone ? "true" : "false",
      "showsPlaybackControls": showsPlaybackControls ? "true" : "false"
    ]
    metadata.merge(extra) { _, new in new }
    return AVPlayerRepresentable.playerViewMetadata(player: player, view: view, extra: metadata)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if AppDiagnostics.isEnabled(.debug, category: "ui.video.playerView") {
      AppDiagnostics.asyncRecord(
        .debug,
        category: "ui.video.playerView",
        message: "NiceAVPlayer viewDidAppear",
        metadata: diagnosticsMetadata()
      )
    }
    if videoDefSettings.loop, let player = self.player {
      NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime,
        object: player.currentItem,
        queue: nil) { [weak self] notif in
          guard let _ = self else { return }
          player.seek(to: .zero)
          player.play()
        }
    }
    if autoPlayVideos && gone {
      self.player?.play()
      gone = false
      if AppDiagnostics.isEnabled(.debug, category: "ui.video.playerView") {
        AppDiagnostics.asyncRecord(
          .debug,
          category: "ui.video.playerView",
          message: "NiceAVPlayer autoplay started",
          metadata: diagnosticsMetadata()
        )
      }
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if AppDiagnostics.isEnabled(.debug, category: "ui.video.playerView") {
      AppDiagnostics.asyncRecord(
        .debug,
        category: "ui.video.playerView",
        message: "NiceAVPlayer viewDidDisappear",
        metadata: diagnosticsMetadata()
      )
    }
    if let player = self.player {
      NotificationCenter.default.removeObserver(
        self,
        name: .AVPlayerItemDidPlayToEndTime,
        object: player.currentItem)
    }
    if !showsPlaybackControls {
      player?.pause()
      gone = true
      if AppDiagnostics.isEnabled(.debug, category: "ui.video.playerView") {
        AppDiagnostics.asyncRecord(
          .debug,
          category: "ui.video.playerView",
          message: "NiceAVPlayer inline playback paused on disappear",
          metadata: diagnosticsMetadata()
        )
      }
    }
  }

  @objc private func didTapView() {
    enterFullScreen(animated: true)
    showsPlaybackControls = true
  }

  func enterFullScreen(animated: Bool) {
    let selector = NSSelectorFromString("enterFullScreenAnimated:completionHandler:")
    
    if self.responds(to: selector) {
      self.perform(selector, with: animated, with: nil)
    }
  }

  func exitFullScreen(animated: Bool) {
    let selector = NSSelectorFromString("exitFullScreenAnimated:completionHandler:")
    
    if self.responds(to: selector) {
      self.perform(selector, with: animated, with: nil)
    }
  }

  func playerViewController(
    _ playerViewController: AVPlayerViewController,
    willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
  ) {
    if AppDiagnostics.isEnabled(.debug, category: "ui.video.playerView") {
      AppDiagnostics.asyncRecord(
        .debug,
        category: "ui.video.playerView",
        message: "NiceAVPlayer will begin fullscreen",
        metadata: diagnosticsMetadata()
      )
    }
    coordinator.animate(alongsideTransition: nil) { [weak self] context in
      guard let self = self else { return }
      if context.isCancelled {
        // Still embedded inline
      } else {
        // Presented full screen
        // Take strong reference to playerViewController if needed
        self.player?.volume = 1.0
        self.player?.play()
        self.showsPlaybackControls = true
      }
    }
  }

  func playerViewController(
    _ playerViewController: AVPlayerViewController,
    willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
  ) {
    let isPlaying = self.player?.isPlaying ?? false
    if AppDiagnostics.isEnabled(.debug, category: "ui.video.playerView") {
      AppDiagnostics.asyncRecord(
        .debug,
        category: "ui.video.playerView",
        message: "NiceAVPlayer will end fullscreen",
        metadata: diagnosticsMetadata(extra: ["isPlaying": isPlaying ? "true" : "false"])
      )
    }
    coordinator.animate(alongsideTransition: nil) { [weak self] context in
      guard let self = self else { return }
      if context.isCancelled {
        // Still full screen
      } else {
        // Embedded inline
        // Remove strong reference to playerViewController if held
        self.fullscreen = false
        doThisAfter(0.0) {
          self.player?.volume = 0.0
        }
        self.showsPlaybackControls = false
        if !self.autoPlayVideos { self.player?.pause() } else if isPlaying { self.player?.play() }
      }
    }
  }
}

extension AVPlayer {
  var isVideoPlaying: Bool {
    return rate != 0 && error == nil
  }
}
