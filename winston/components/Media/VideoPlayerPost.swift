import SwiftUI
import Defaults
import CoreMedia
import AVKit
import AVFoundation
import Combine
import Nuke

struct SharedVideo: Equatable {
  static func == (lhs: SharedVideo, rhs: SharedVideo) -> Bool {
    lhs.url == rhs.url && lhs.downloadURL == rhs.downloadURL && lhs.posterURL == rhs.posterURL && lhs.size == rhs.size
  }
  
  var player: AVPlayer
  var url: URL
  var downloadURL: URL?
  var posterURL: URL?
  var size: CGSize
  
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
      AppDiagnostics.asyncRecord(
        .debug,
        category: "ui.video.cache",
        message: "SharedVideo cache hit",
        metadata: SharedVideo.cacheDiagnosticsMetadata(url: url, size: size, downloadURL: downloadURL, posterURL: posterURL, cacheKey: cacheKey)
      )
      return sharedVideo
    } else {
      let sharedVideo = SharedVideo(url: url, size: size, downloadURL: downloadURL, posterURL: posterURL)
      Caches.videos.addKeyValue(key: cacheKey, data: { sharedVideo }, expires: Date().dateByAdding(1, .day).date)
      AppDiagnostics.asyncRecord(
        .debug,
        category: "ui.video.cache",
        message: "SharedVideo cache miss",
        metadata: SharedVideo.cacheDiagnosticsMetadata(url: url, size: size, downloadURL: downloadURL, posterURL: posterURL, cacheKey: cacheKey)
      )
      
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
    let newPlayer = AVPlayer(url: url)
    newPlayer.volume = 0.0
    self.player = newPlayer
    AppDiagnostics.asyncRecord(
      .debug,
      category: "ui.video.cache",
      message: "SharedVideo initialized AVPlayer",
      metadata: SharedVideo.cacheDiagnosticsMetadata(url: url, size: size, downloadURL: downloadURL, posterURL: posterURL, cacheKey: SharedVideo.cacheKey(url: url, size: size, downloadURL: downloadURL, posterURL: posterURL))
    )
  }
}

struct VideoPlayerPost: View, Equatable {
  static func == (lhs: VideoPlayerPost, rhs: VideoPlayerPost) -> Bool {
    lhs.url == rhs.url && lhs.sharedVideo == rhs.sharedVideo && lhs.diagnosticContext == rhs.diagnosticContext
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
  @Default(.VideoDefSettings) private var videoDefSettings
  @Environment(\.scenePhase) private var scenePhase
  
  private var autoPlayVideos: Bool { videoDefSettings.autoPlay }
  private var loopVideos: Bool { videoDefSettings.loop }
  private var muteVideos: Bool { videoDefSettings.mute }
  private var pauseBackgroundAudioOnFullscreen: Bool { videoDefSettings.pauseBGAudioOnFullscreen }
  
  init(controller: UIViewController?, cachedVideo: SharedVideo?, markAsSeen: (() async -> ())?, compact: Bool = false, contentWidth: CGFloat, url: URL, resetVideo: ((SharedVideo) -> ())?, maxMediaHeightScreenPercentage: CGFloat, diagnosticContext: String? = nil) {
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
  }
  
  var safe: Double { getSafeArea().top + getSafeArea().bottom }
  
  
  var body: some View {
    let maxHeight: CGFloat = (maxMediaHeightScreenPercentage / 100) * (.screenH)
    let sourceWidth = size.width
    let sourceHeight = size.height
    let propHeight = sourceWidth > 0 && sourceHeight > 0 && contentWidth > 0 ? (contentWidth * sourceHeight) / sourceWidth : contentWidth * 9 / 16
    let finalHeight = maxMediaHeightScreenPercentage != 110 ? Double(min(maxHeight, propHeight)) : Double(propHeight)
    
    if let sharedVideo = sharedVideo {
      let videoSize = CGSize(width: compact ? scaledCompactModeThumbSize() : contentWidth, height: compact ? scaledCompactModeThumbSize() : CGFloat(finalHeight))
      let hasAudio = sharedVideo.player.currentItem?.tracks.contains(where: { $0.assetTrack?.mediaType == AVMediaType.audio })
      if let controller = controller {
        ZStack {
          AVPlayerRepresentable(fullscreen: $fullscreen, autoPlayVideos: autoPlayVideos, player: sharedVideo.player, aspect: .resizeAspectFill, controller: controller)
            .allowsHitTesting(false)
            .id(inlineVideoRefreshID)
          videoPoster(sharedVideo: sharedVideo, size: videoSize)
          playOverlay()
        }
        .frame(width: videoSize.width, height: videoSize.height)
        .mask(RR(12, Color.black))
        .contentShape(Rectangle())
        .onTapGesture {
          recordVideoEvent(.debug, message: "Inline video tapped", sharedVideo: sharedVideo, extra: ["branch": "controller"])
          if markAsSeen != nil { Task(priority: .background) { await markAsSeen?() } }
          withAnimation {
            fullscreen = true
          }
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
        .onDisappear() {
          recordVideoEvent(.debug, message: "VideoPlayerPost disappeared", sharedVideo: sharedVideo, extra: ["branch": "controller"])
          removeObserver()
          Task(priority: .background) {
            sharedVideo.player.seek(to: .zero)
            sharedVideo.player.pause()
          }
        }
        .onChange(of: fullscreen) { val in
          handleFullscreenChange(val, sharedVideo: sharedVideo, hasAudio: hasAudio)
        }
        .fullScreenCover(isPresented: $fullscreen) {
          FullScreenVP(sharedVideo: sharedVideo)
        }
      } else {
        ZStack {
          
          Group {
            if !fullscreen {
              InlineAVPlayerLayerRepresentable(player: sharedVideo.player, videoGravity: .resizeAspectFill)
                .id(inlineVideoRefreshID)
            } else {
              Color.clear
            }
          }
          .frame(width: videoSize.width, height: videoSize.height)
          .clipped()
          .fixedSize()
          .mask(RR(12, Color.black))
          .allowsHitTesting(false)
          .contentShape(Rectangle())
          .highPriorityGesture(TapGesture().onEnded({ _ in
            recordVideoEvent(.debug, message: "Inline video tapped", sharedVideo: sharedVideo, extra: ["branch": "swiftuiVideoPlayer-highPriority"])
            if markAsSeen != nil { Task(priority: .background) { await markAsSeen?() } }
            withAnimation {
              fullscreen = true
            }
          }))
          .allowsHitTesting(false)
          .mask(RR(12, Color.black))
          .overlay(
            Color.clear
              .contentShape(Rectangle())
              .onTapGesture {
                recordVideoEvent(.debug, message: "Inline video tapped", sharedVideo: sharedVideo, extra: ["branch": "swiftuiVideoPlayer-overlay"])
                if markAsSeen != nil { Task(priority: .background) { await markAsSeen?() } }
                withAnimation {
                  fullscreen = true
                }
              }
          )
          
          videoPoster(sharedVideo: sharedVideo, size: videoSize)
          playOverlay()
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
        .onDisappear() {
          recordVideoEvent(.debug, message: "VideoPlayerPost disappeared", sharedVideo: sharedVideo, extra: ["branch": "swiftuiVideoPlayer"])
          removeObserver()
          Task(priority: .background) {
            sharedVideo.player.seek(to: .zero)
            sharedVideo.player.pause()
          }
        }
        .onChange(of: fullscreen) { val in
          handleFullscreenChange(val, sharedVideo: sharedVideo, hasAudio: hasAudio)
        }
        .fullScreenCover(isPresented: $fullscreen) {
          FullScreenVP(sharedVideo: sharedVideo)
        }
      }
    }
  }

  @ViewBuilder
  func videoPoster(sharedVideo: SharedVideo, size: CGSize) -> some View {
    if let posterURL = sharedVideo.posterURL, showInlinePoster, !posterUnavailable {
      let request = winstonImageRequest(
        url: posterURL,
        processors: [ImageProcessors.Resize(size: size, unit: .points, contentMode: .aspectFill, crop: false, upscale: true)],
        priority: .high,
        thumbnail: ImageRequest.ThumbnailOptions(size: size, unit: .points, contentMode: .aspectFill)
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
        showPlaceholder: false
      )
        .scaledToFill()
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
    if activeInlineVideoKey != cacheKey {
      activeInlineVideoKey = cacheKey
      posterLoaded = false
      posterHideGeneration = UUID()
      recordVideoEvent(.debug, message: "Inline video identity changed", sharedVideo: sharedVideo, extra: ["cacheKeyHash": "\(cacheKey.hashValue)"])
    }

    if loopVideos {
      addObserver()
    }

    if (sharedVideo.player.status == .failed) {
      recordVideoEvent(.warning, message: "Inline video player failed before prepare", sharedVideo: sharedVideo)
      resetVideo?(sharedVideo)
    }

    showInlinePoster = true
    posterUnavailable = false
    if autoPlayVideos {
      sharedVideo.player.play()
      recordVideoEvent(.debug, message: "Inline autoplay requested", sharedVideo: sharedVideo)
      if sharedVideo.posterURL == nil || posterLoaded {
        scheduleInlinePosterHide(sharedVideo: sharedVideo)
      } else {
        recordVideoEvent(.debug, message: "Inline poster kept mounted waiting for poster load", sharedVideo: sharedVideo)
      }
    } else {
      prepareInlinePlayback(sharedVideo)
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
    if autoPlayVideos {
      scheduleInlinePosterHide(sharedVideo: sharedVideo)
    }
  }

  func scheduleInlinePosterHide(sharedVideo: SharedVideo, attempt: Int = 0) {
    let cacheKey = SharedVideo.cacheKey(url: sharedVideo.url, size: sharedVideo.size, downloadURL: sharedVideo.downloadURL, posterURL: sharedVideo.posterURL)
    let generation = UUID()
    posterHideGeneration = generation
    recordVideoEvent(.debug, message: "Scheduling inline poster hide", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["generation": generation.uuidString, "cacheKeyHash": "\(cacheKey.hashValue)", "attempt": "\(attempt)"])
    doThisAfter(attempt == 0 ? 0.6 : 0.25) {
      guard posterHideGeneration == generation else {
        recordVideoEvent(.debug, message: "Inline poster hide skipped", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["reason": "generation-mismatch", "generation": generation.uuidString])
        return
      }
      guard self.sharedVideo == sharedVideo else {
        recordVideoEvent(.debug, message: "Inline poster hide skipped", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["reason": "stale-video", "generation": generation.uuidString])
        return
      }
      guard activeInlineVideoKey == cacheKey else {
        recordVideoEvent(.debug, message: "Inline poster hide skipped", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["reason": "active-key-mismatch", "generation": generation.uuidString, "expectedKeyHash": "\(cacheKey.hashValue)", "activeKeyHash": activeInlineVideoKey.map { "\($0.hashValue)" } ?? "nil"])
        return
      }
      guard autoPlayVideos else {
        recordVideoEvent(.debug, message: "Inline poster hide skipped", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["reason": "autoplay-disabled", "generation": generation.uuidString])
        return
      }
      guard !fullscreen else {
        recordVideoEvent(.debug, message: "Inline poster hide skipped", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["reason": "fullscreen", "generation": generation.uuidString])
        return
      }
      guard inlineVideoIsRenderable(sharedVideo) else {
        if attempt < 8 {
          recordVideoEvent(.debug, message: "Inline poster hide delayed", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["reason": "video-not-renderable", "generation": generation.uuidString, "attempt": "\(attempt)"])
          scheduleInlinePosterHide(sharedVideo: sharedVideo, attempt: attempt + 1)
        } else {
          recordVideoEvent(.warning, message: "Inline poster kept visible because video was not renderable", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["generation": generation.uuidString, "attempt": "\(attempt)"])
        }
        return
      }
      recordVideoEvent(.debug, message: "Inline poster hide executing", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["generation": generation.uuidString, "attempt": "\(attempt)"])
      withAnimation(.easeOut(duration: 0.2)) {
        showInlinePoster = false
      }
    }
  }

  func inlineVideoIsRenderable(_ sharedVideo: SharedVideo) -> Bool {
    let currentTime = CMTimeGetSeconds(sharedVideo.player.currentTime())
    let hasAdvanced = currentTime.isFinite && currentTime > 0.05
    let itemReady = sharedVideo.player.currentItem?.status == .readyToPlay
    let isPlaying = sharedVideo.player.timeControlStatus == .playing || sharedVideo.player.rate > 0
    return itemReady && isPlaying && hasAdvanced
  }

  func hideUnavailablePoster(reason: String, url: URL, sharedVideo: SharedVideo) {
    guard self.sharedVideo == sharedVideo else {
      recordVideoEvent(.debug, message: "Poster unavailable callback ignored", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["reason": "stale-video", "url": url.absoluteString])
      return
    }
    guard showInlinePoster, !posterUnavailable else {
      recordVideoEvent(.debug, message: "Poster unavailable callback ignored", sharedVideo: sharedVideo, category: "ui.videoPoster", extra: ["reason": "poster-not-visible-or-already-unavailable", "url": url.absoluteString])
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
        "url": url.absoluteString
      ]
    )
    refreshInlineVideoSurface(reason: "poster-\(reason)", sharedVideo: sharedVideo)
  }

  func refreshInlineVideoSurface(reason: String, sharedVideo: SharedVideo) {
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

  func handleFullscreenChange(_ val: Bool, sharedVideo: SharedVideo, hasAudio: Bool?) {
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
          AppDiagnostics.asyncRecord(.debug, category: "ui.video", message: "AVPlayer item ended", metadata: ["cacheKeyHash": "\(cacheKey.hashValue)", "context": diagnosticContext ?? "nil"])
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
  
  func prepareInlinePlayback(_ sharedVideo: SharedVideo) {
    let cacheKey = SharedVideo.cacheKey(url: sharedVideo.url, size: sharedVideo.size, downloadURL: sharedVideo.downloadURL, posterURL: sharedVideo.posterURL)
    guard preparedInlineVideoKey != cacheKey else {
      recordVideoEvent(.debug, message: "Inline playback already prepared", sharedVideo: sharedVideo, extra: ["cacheKeyHash": "\(cacheKey.hashValue)"])
      if posterUnavailable {
        refreshInlineVideoSurface(reason: "already-prepared", sharedVideo: sharedVideo)
      }
      return
    }
    preparedInlineVideoKey = cacheKey
    recordVideoEvent(.debug, message: "Preparing AVPlayer preroll", sharedVideo: sharedVideo, extra: ["cacheKeyHash": "\(cacheKey.hashValue)"])
    sharedVideo.player.isMuted = true
    sharedVideo.player.automaticallyWaitsToMinimizeStalling = true
    sharedVideo.player.currentItem?.preferredForwardBufferDuration = 2
    let shouldPauseAfterPreroll = !autoPlayVideos && !fullscreen
    sharedVideo.player.preroll(atRate: 1.0) { finished in
      DispatchQueue.main.async {
        recordVideoEvent(.debug, message: "AVPlayer preroll completed", sharedVideo: sharedVideo, extra: ["finished": "\(finished)", "shouldPauseAfterPreroll": "\(shouldPauseAfterPreroll)"])
        if finished && shouldPauseAfterPreroll {
          sharedVideo.player.pause()
        }
        if finished && posterUnavailable {
          refreshInlineVideoSurface(reason: "preroll-finished", sharedVideo: sharedVideo)
        }
      }
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
    message: String,
    sharedVideo: SharedVideo,
    category: String = "ui.video",
    extra: [String: String] = [:]
  ) {
    AppDiagnostics.asyncRecord(
      level,
      category: category,
      message: message,
      metadata: videoDiagnosticsMetadata(sharedVideo: sharedVideo).merging(extra) { _, new in new }
    )
  }

  func videoDiagnosticsMetadata(sharedVideo: SharedVideo) -> [String: String] {
    let cacheKey = SharedVideo.cacheKey(url: sharedVideo.url, size: sharedVideo.size, downloadURL: sharedVideo.downloadURL, posterURL: sharedVideo.posterURL)
    let item = sharedVideo.player.currentItem
    return [
      "context": diagnosticContext ?? "nil",
      "compact": "\(compact)",
      "contentWidth": "\(contentWidth)",
      "sourceURL": sharedVideo.url.absoluteString,
      "downloadURL": sharedVideo.downloadURL?.absoluteString ?? "nil",
      "posterURL": sharedVideo.posterURL?.absoluteString ?? "nil",
      "videoSize": "\(sharedVideo.size.width)x\(sharedVideo.size.height)",
      "cacheKeyHash": "\(cacheKey.hashValue)",
      "activeKeyHash": activeInlineVideoKey.map { "\($0.hashValue)" } ?? "nil",
      "preparedKeyHash": preparedInlineVideoKey.map { "\($0.hashValue)" } ?? "nil",
      "observedKeyHash": observedVideoKey.map { "\($0.hashValue)" } ?? "nil",
      "showInlinePoster": "\(showInlinePoster)",
      "posterLoaded": "\(posterLoaded)",
      "posterUnavailable": "\(posterUnavailable)",
      "autoPlay": "\(autoPlayVideos)",
      "loop": "\(loopVideos)",
      "fullscreen": "\(fullscreen)",
      "scenePhase": scenePhaseDescription(scenePhase),
      "inlineVideoRefreshID": inlineVideoRefreshID.uuidString,
      "playerStatus": videoStatus(sharedVideo.player.status),
      "timeControlStatus": timeControlStatus(sharedVideo.player.timeControlStatus),
      "playerRate": "\(sharedVideo.player.rate)",
      "itemStatus": itemStatus(item?.status),
      "itemLikelyToKeepUp": item.map { "\($0.isPlaybackLikelyToKeepUp)" } ?? "nil",
      "itemBufferEmpty": item.map { "\($0.isPlaybackBufferEmpty)" } ?? "nil",
      "loadedTimeRanges": "\(item?.loadedTimeRanges.count ?? 0)",
      "currentTime": "\(CMTimeGetSeconds(sharedVideo.player.currentTime()))",
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

  func makeUIView(context: Context) -> PlayerLayerView {
    let view = PlayerLayerView()
    view.backgroundColor = .clear
    view.playerLayer.player = player
    view.playerLayer.videoGravity = videoGravity
    return view
  }

  func updateUIView(_ uiView: PlayerLayerView, context: Context) {
    if uiView.playerLayer.player !== player {
      uiView.playerLayer.player = player
    }
    if uiView.playerLayer.videoGravity != videoGravity {
      uiView.playerLayer.videoGravity = videoGravity
    }
  }

  static func dismantleUIView(_ uiView: PlayerLayerView, coordinator: ()) {
    uiView.playerLayer.player = nil
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

struct FullScreenVP: View {
  var sharedVideo: SharedVideo
  @Environment(\.dismiss) private var dismiss
  @State private var cancelDrag: Bool?
  @State private var isPinching: Bool = false
  @State private var drag: CGSize = .zero
  @State private var scale: CGFloat = 1.0
  @State private var anchor: UnitPoint = .zero
  @State private var offset: CGSize = .zero
  @State private var altSize: CGSize = .zero
  var body: some View {
    let interpolate = interpolatorBuilder([0, 100], value: abs(drag.height))
    VideoPlayer(player: sharedVideo.player)
      .background(
        sharedVideo.size != .zero
        ? nil
        : GeometryReader { geo in
          Color.clear
            .onAppear { altSize = geo.size }
            .onChange(of: geo.size) { newValue in altSize = newValue }
        }
      )
    //      .pinchToZoom(size: sharedVideo.size == .zero ? altSize : sharedVideo.size, isPinching: $isPinching, scale: $scale, anchor: $anchor, offset: $offset)
      .scaleEffect(interpolate([1, 0.9], true))
      .offset(cancelDrag ?? false ? .zero : drag)
      .gesture(
        scale != 1.0
        ? nil
        : DragGesture(minimumDistance: 10)
          .onChanged { val in
            if cancelDrag == nil { cancelDrag = abs(val.translation.width) > abs(val.translation.height) }
            if cancelDrag == nil || cancelDrag! { return }
            var transaction = Transaction()
            transaction.isContinuous = true
            transaction.animation = .interpolatingSpring(stiffness: 1000, damping: 100, initialVelocity: 0)
            
            let endPos = val.translation
            withTransaction(transaction) {
              drag = endPos
            }
          }
          .onEnded { val in
            let prevCancelDrag = cancelDrag
            cancelDrag = nil
            if prevCancelDrag == nil || prevCancelDrag! { return }
            let shouldClose = abs(val.translation.width) > 100 || abs(val.translation.height) > 100
            withAnimation(.interpolatingSpring(stiffness: 200, damping: 20, initialVelocity: 0)) {
              drag = .zero
              if shouldClose {
                dismiss()
              }
            }
          }
      )
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
    AppDiagnostics.asyncRecord(
      .debug,
      category: "ui.video.playerView",
      message: "AVPlayerRepresentable makeUIView",
      metadata: AVPlayerRepresentable.playerViewMetadata(player: player, view: view, extra: ["autoPlay": "\(autoPlayVideos)", "aspect": aspect.rawValue])
    )
    return view
  }

  func updateUIView(_ view: UIView, context: Context) {
    AppDiagnostics.asyncRecord(
      .debug,
      category: "ui.video.playerView",
      message: "AVPlayerRepresentable updateUIView",
      metadata: AVPlayerRepresentable.playerViewMetadata(player: player, view: view, extra: ["autoPlay": "\(autoPlayVideos)", "fullscreen": "\(fullscreen)", "aspect": aspect.rawValue])
    )
    if let playerController = context.coordinator.controller, playerController.autoPlayVideos != autoPlayVideos {
      playerController.autoPlayVideos = autoPlayVideos
    }
    if fullscreen {
      context.coordinator.controller?.enterFullScreen(animated: true)
    }
  }

  static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
    AppDiagnostics.asyncRecord(
      .debug,
      category: "ui.video.playerView",
      message: "AVPlayerRepresentable dismantleUIView",
      metadata: playerViewMetadata(player: coordinator.controller?.player, view: uiView)
    )
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

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    AppDiagnostics.asyncRecord(
      .debug,
      category: "ui.video.playerView",
      message: "NiceAVPlayer viewDidAppear",
      metadata: AVPlayerRepresentable.playerViewMetadata(player: player, view: view, extra: ["autoPlay": "\(autoPlayVideos)", "gone": "\(gone)", "showsPlaybackControls": "\(showsPlaybackControls)"])
    )
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
      AppDiagnostics.asyncRecord(
        .debug,
        category: "ui.video.playerView",
        message: "NiceAVPlayer autoplay started",
        metadata: AVPlayerRepresentable.playerViewMetadata(player: player, view: view, extra: ["autoPlay": "\(autoPlayVideos)", "gone": "\(gone)", "showsPlaybackControls": "\(showsPlaybackControls)"])
      )
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    AppDiagnostics.asyncRecord(
      .debug,
      category: "ui.video.playerView",
      message: "NiceAVPlayer viewDidDisappear",
      metadata: AVPlayerRepresentable.playerViewMetadata(player: player, view: view, extra: ["autoPlay": "\(autoPlayVideos)", "gone": "\(gone)", "showsPlaybackControls": "\(showsPlaybackControls)"])
    )
    if let player = self.player {
      NotificationCenter.default.removeObserver(
        self,
        name: .AVPlayerItemDidPlayToEndTime,
        object: player.currentItem)
    }
    if !showsPlaybackControls {
      player?.pause()
      gone = true
      AppDiagnostics.asyncRecord(
        .debug,
        category: "ui.video.playerView",
        message: "NiceAVPlayer inline playback paused on disappear",
        metadata: AVPlayerRepresentable.playerViewMetadata(player: player, view: view, extra: ["autoPlay": "\(autoPlayVideos)", "gone": "\(gone)", "showsPlaybackControls": "\(showsPlaybackControls)"])
      )
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
    AppDiagnostics.asyncRecord(
      .debug,
      category: "ui.video.playerView",
      message: "NiceAVPlayer will begin fullscreen",
      metadata: AVPlayerRepresentable.playerViewMetadata(player: player, view: view, extra: ["autoPlay": "\(autoPlayVideos)", "gone": "\(gone)", "showsPlaybackControls": "\(showsPlaybackControls)"])
    )
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
    AppDiagnostics.asyncRecord(
      .debug,
      category: "ui.video.playerView",
      message: "NiceAVPlayer will end fullscreen",
      metadata: AVPlayerRepresentable.playerViewMetadata(player: player, view: view, extra: ["autoPlay": "\(autoPlayVideos)", "gone": "\(gone)", "showsPlaybackControls": "\(showsPlaybackControls)", "isPlaying": "\(isPlaying)"])
    )
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
