//
//  GIFViewer.swift
//  winston
//
//  Created by Igor Marcossi on 29/10/23.
//

import SwiftUI
import NukeUI
import Nuke
import Gifu
import ImageIO

struct GIFPlaybackState: Equatable {
  var url: URL
  var progress: Double
  var isScrubbing: Bool
}

/// An image view for displaying animated images.
public struct GIFImage: UIViewRepresentable {
  private enum Source {
    case data(Data)
    case url(URL)
    case imageName(String)
  }
  
  private let source: Source
  private var loopCount = 0
  private var size: CGSize = .zero
  
  /// Initializes the view with the given GIF image data.
  public init(data: Data, size: CGSize? = nil) {
    self.source = .data(data)
    if let size = size { self.size = size }
  }
  
  /// Initialzies the view with the given GIF image url.
  public init(url: URL, size: CGSize? = nil) {
    self.source = .url(url)
    if let size = size { self.size = size }
  }
  
  /// Initialzies the view with the given GIF image name.
  public init(imageName: String, size: CGSize? = nil) {
    self.source = .imageName(imageName)
    if let size = size { self.size = size }
  }
  
  /// Sets the desired number of loops. By default, the number of loops infinite.
  public func loopCount(_ value: Int) -> GIFImage {
    var copy = self
    copy.loopCount = value
    return copy
  }
  
  public func makeUIView(context: Context) -> GIFImageView {
    let view = GIFImageView(frame: .init(origin: .zero, size: self.size))
    view.contentMode = .scaleAspectFill
    view.frame.size = self.size
    view.clipsToBounds = true
    view.translatesAutoresizingMaskIntoConstraints = false
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.setContentHuggingPriority(.required, for: .horizontal)
    view.setContentHuggingPriority(.required, for: .vertical)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    return view
  }
  
  public func updateUIView(_ view: GIFImageView, context: Context) {
    switch source {
    case .data(let data):
      view.animate(withGIFData: data, loopCount: loopCount)
    case .url(let url):
      view.animate(withGIFURL: url, loopCount: loopCount)
    case .imageName(let imageName):
      view.animate(withGIFNamed: imageName, loopCount: loopCount)
    }
    view.contentMode = .scaleAspectFill
    view.clipsToBounds = true
    view.frame.size = self.size
    view.translatesAutoresizingMaskIntoConstraints = false
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.setContentHuggingPriority(.required, for: .horizontal)
    view.setContentHuggingPriority(.required, for: .vertical)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
  }
  
  public static func dismantleUIView(
      _ uiView: GIFImageView,
      coordinator: Coordinator
  ) {
    uiView.prepareForReuse()
  }
}

class LoadingImgView: UIImageView {
  init() {
    let loadingImg = UIImage(named: "loader")
    super.init(image: loadingImg)
    self.frame = .init(origin: .zero, size: CGSize(width: 75, height: 75))
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

struct ScrubbableGIFImage: UIViewRepresentable {
  let data: Data
  let url: URL
  var contentMode: UIView.ContentMode = .scaleAspectFit
  var requestedProgress: Double?
  @Binding var playbackState: GIFPlaybackState?
  @Binding var isScrubbing: Bool

  final class Coordinator {
    var appliedURL: URL?
    var appliedDataCount: Int?
    var appliedProgress: Double?
    var appliedScrubbing: Bool?
    var hasApplied = false
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> ScrubbableGIFImageView {
    let view = ScrubbableGIFImageView(frame: .zero)
    view.clipsToBounds = true
    view.contentMode = contentMode
    view.onPlaybackChanged = { state in
      playbackState = state
      isScrubbing = state.isScrubbing
    }
    return view
  }

  func updateUIView(_ view: ScrubbableGIFImageView, context: Context) {
    view.contentMode = contentMode
    view.onPlaybackChanged = { state in
      playbackState = state
      isScrubbing = state.isScrubbing
    }
    view.configure(data: data, url: url)

    // Only push scrub state into the view when something actually changed. Re-pushing on every
    // render is a trap: setScrubProgress force-reports playback, which writes @State during the
    // SwiftUI update, which schedules another render → an unbounded scrub feedback loop (it froze
    // the BETA viewer once scrubbing drove it). Deduping breaks the loop and is a no-op improvement
    // for normal playback (the CADisplayLink still drives frame reporting).
    let coordinator = context.coordinator
    if coordinator.appliedURL != url || coordinator.appliedDataCount != data.count {
      coordinator.appliedURL = url
      coordinator.appliedDataCount = data.count
      coordinator.hasApplied = false
    }
    if !coordinator.hasApplied
        || coordinator.appliedProgress != requestedProgress
        || coordinator.appliedScrubbing != isScrubbing {
      coordinator.hasApplied = true
      coordinator.appliedProgress = requestedProgress
      coordinator.appliedScrubbing = isScrubbing
      view.setScrubProgress(requestedProgress, isScrubbing: isScrubbing)
    }
  }

  static func dismantleUIView(_ uiView: ScrubbableGIFImageView, coordinator: Coordinator) {
    uiView.prepareForReuse()
  }
}

final class ScrubbableGIFImageView: UIImageView {
  var onPlaybackChanged: ((GIFPlaybackState) -> Void)?

  private struct Frame {
    let image: UIImage
    let duration: TimeInterval
    let startTime: TimeInterval
  }

  private var frames: [Frame] = []
  private var loopDuration: TimeInterval = 0
  private var elapsedTime: TimeInterval = 0
  private var currentFrameIndex = 0
  private var configuredDataCount: Int?
  private var configuredURL: URL?
  private var isScrubbingGIF = false
  private var lastProgressReport: GIFPlaybackState?
  private lazy var displayLink: CADisplayLink = {
    let link = CADisplayLink(target: self, selector: #selector(displayLinkDidTick(_:)))
    link.add(to: .main, forMode: .common)
    return link
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    displayLink.invalidate()
  }

  func configure(data: Data, url: URL) {
    guard configuredDataCount != data.count || configuredURL != url else { return }
    configuredDataCount = data.count
    configuredURL = url
    frames = Self.decodeFrames(from: data)
    loopDuration = frames.last.map { $0.startTime + $0.duration } ?? 0
    elapsedTime = 0
    currentFrameIndex = 0
    image = frames.first?.image ?? UIImage(data: data)
    displayLink.isPaused = frames.count <= 1
    reportPlayback(force: true)
  }

  func setScrubProgress(_ progress: Double?, isScrubbing: Bool) {
    guard frames.count > 1, loopDuration > 0 else { return }

    if isScrubbingGIF != isScrubbing {
      isScrubbingGIF = isScrubbing
      displayLink.isPaused = isScrubbing
    }

    guard let progress else {
      if !isScrubbing {
        displayLink.isPaused = false
        reportPlayback(force: true)
      }
      return
    }

    seek(toProgress: progress)
  }

  func prepareForReuse() {
    displayLink.isPaused = true
    frames = []
    loopDuration = 0
    elapsedTime = 0
    currentFrameIndex = 0
    configuredDataCount = nil
    configuredURL = nil
    image = nil
    isScrubbingGIF = false
    lastProgressReport = nil
  }

  @objc private func displayLinkDidTick(_ link: CADisplayLink) {
    guard !isScrubbingGIF, frames.count > 1, loopDuration > 0 else { return }
    elapsedTime = (elapsedTime + link.duration).truncatingRemainder(dividingBy: loopDuration)
    updateFrameForElapsedTime()
    reportPlayback()
  }

  private func seek(toProgress progress: Double) {
    let clampedProgress = min(max(progress, 0), 1)
    elapsedTime = clampedProgress * loopDuration
    updateFrameForElapsedTime()
    reportPlayback(force: true)
  }

  private func updateFrameForElapsedTime() {
    guard !frames.isEmpty else { return }
    let frameIndex = elapsedTime >= loopDuration ? 0 : frames.lastIndex { elapsedTime >= $0.startTime } ?? 0
    guard frameIndex != currentFrameIndex || image == nil else { return }
    currentFrameIndex = frameIndex
    image = frames[frameIndex].image
  }

  private func reportPlayback(force: Bool = false) {
    guard let configuredURL, loopDuration > 0 else { return }
    let progress = min(max(elapsedTime / loopDuration, 0), 1)
    let state = GIFPlaybackState(
      url: configuredURL,
      progress: progress,
      isScrubbing: isScrubbingGIF
    )

    guard force || shouldReport(state) else { return }
    lastProgressReport = state
    onPlaybackChanged?(state)
  }

  private func shouldReport(_ state: GIFPlaybackState) -> Bool {
    guard let previous = lastProgressReport else { return true }
    return previous.url != state.url
      || previous.isScrubbing != state.isScrubbing
      || abs(previous.progress - state.progress) >= 0.004
  }

  private static func decodeFrames(from data: Data) -> [Frame] {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
    let frameCount = CGImageSourceGetCount(source)
    var frames: [Frame] = []
    frames.reserveCapacity(frameCount)

    var elapsed: TimeInterval = 0
    for index in 0..<frameCount {
      guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
      let duration = frameDuration(source: source, index: index)
      frames.append(Frame(image: UIImage(cgImage: cgImage), duration: duration, startTime: elapsed))
      elapsed += duration
    }

    return frames
  }

  private static func frameDuration(source: CGImageSource, index: Int) -> TimeInterval {
    let defaultDuration = 0.1
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
      let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    else {
      return defaultDuration
    }

    let unclampedDelay = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? TimeInterval
    let delay = unclampedDelay ?? gifProperties[kCGImagePropertyGIFDelayTime] as? TimeInterval
    return max(delay ?? defaultDuration, 0.02)
  }
}
