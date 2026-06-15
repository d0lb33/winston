//
//  URLImage.swift
//  winston
//
//  Created by Igor Marcossi on 19/08/23.
//

import SwiftUI
import NukeUI
import Nuke
import NukeExtensions
import VisionKit

struct URLImage: View, Equatable {
  static func == (lhs: URLImage, rhs: URLImage) -> Bool {
    lhs.requestIdentity == rhs.requestIdentity
  }
  
  let url: URL
  @Environment(\.deferMediaWorkWhileScrolling) private var deferMediaWorkWhileScrolling
  var doLiveText: Bool = false
  var imgRequest: ImageRequest? = nil
  var pipeline: ImagePipeline? = nil
  var processors: [ImageProcessing]? = nil
  var size: CGSize?
  var diagnosticContext: String? = nil
  var onLoadSucceeded: (() -> Void)? = nil
  var onLoadFailed: (() -> Void)? = nil
  var onLoadStalled: (() -> Void)? = nil
  var stallTimeout: TimeInterval = 6
  var showPlaceholder: Bool = true
  var requestImageScaledToFill: Bool = false
  var liveTextActivationDelay: TimeInterval? = nil
  var liveTextActivationTrigger: Bool = true
  @State private var retryID = UUID()
  @State private var retryCount = 0
  @State private var loadGeneration = UUID()
  @State private var loadCompleted = false
  @State private var isVisible = false
  @State private var loadStartedAt: Date? = nil
  @State private var liveTextReady = false
  @State private var liveTextGeneration = UUID()
  @State private var liveTextActivationScheduled = false

  private var requestIdentity: String {
    [
      imgRequest?.description ?? url.absoluteString,
      processors?.map { $0.identifier }.joined(separator: "|") ?? "",
      "\(size?.width ?? 0)x\(size?.height ?? 0)",
      doLiveText ? "livetext" : "",
      liveTextActivationDelay.map { "livetext-delay:\($0)" } ?? "livetext-immediate",
      showPlaceholder ? "placeholder" : "clear-placeholder",
      requestImageScaledToFill ? "request-fill" : "request-intrinsic",
      diagnosticContext ?? ""
    ].joined(separator: "::")
  }

  private var shouldRenderLiveText: Bool {
    doLiveText && liveTextActivationTrigger && ImageAnalyzer.isSupported && (liveTextActivationDelay == nil || liveTextReady)
  }

  private var shouldDeferFeedWork: Bool {
    deferMediaWorkWhileScrolling && FeedScrollWorkCoordinator.shared.shouldDeferWork
  }

  private var requestWorkKey: String {
    "\(requestIdentity.hashValue)"
  }
  
  var body: some View {
    let _ = ScrollPerfProbe.shared.bump("imageViewBody")
    if url.pathExtension.lowercased() == "gif" {
      LazyImage(url: url) { state in
        let phase = imagePhase(hasImage: state.imageContainer?.data != nil || state.image != nil, error: state.error)
        let _ = ScrollPerfProbe.shared.bump("imagePhase.\(phase)")
        Group {
          if let imageData = state.imageContainer?.data {
            ScrubbableGIFImage(
              data: imageData,
              url: url,
              contentMode: .scaleAspectFill,
              requestedProgress: nil,
              playbackState: .constant(nil),
              isScrubbing: .constant(false)
            )
              .scaledToFill()
          } else if let image = state.image {
            image
              .resizable()
              .scaledToFill()
          } else if state.error != nil {
            URLImageFailureView()
          } else {
            placeholderView()
          }
        }
        .onAppear {
          recordImageEvent(
            .debug,
            message: "Image phase appeared",
            source: "gif",
            phase: phase,
            error: state.error?.localizedDescription
          )
        }
      }
      .onDisappear(.cancel)
      .processors(processors)
      .onCompletion { result in
        loadCompleted = true
        recordCompletion(result, source: "gif")
        if case .failure(let error) = result {
          AppDiagnostics.asyncRecord(
            .warning,
            category: "ui.image",
            message: "Image load failed",
            metadata: imageDiagnosticsMetadata(source: "gif", error: error.localizedDescription)
          )
        }
        if case .failure = result, retryCount < 2 {
          retryImageLoad(source: "gif-failure")
        } else if case .failure = result {
          onLoadFailed?()
        }
        if case .success = result {
          onLoadSucceeded?()
        }
      }
      .onAppear { beginImageLoad(source: "gif") }
      .onDisappear { endImageLoad() }
      .id("\(requestIdentity)-\(retryID)")
      .diagnosticLayout("URLImage.gif", metadata: imageDiagnosticsMetadata(source: "gif-layout", error: nil))
//      GIFImage(url: url)
//        .scaledToFill()
//      AsyncGiffy(url: url) { phase in
//        switch phase {
//        case .loading:
//          ProgressView()
//        case .error:
//          Text("Failed to load GIF")
//        case .success(let giffy):
//          giffy.scaledToFit()
//        }
//      }
    } else {
      if let imgRequest = imgRequest {
        LazyImage(request: imgRequest) { state in
//          if case .success(let response) = state.result {
//            AltImage(image: response.image, size: size)
////            Image(uiImage: response.image).resizable()
//          }
          let phase = imagePhase(hasImage: state.image != nil, error: state.error)
          let _ = ScrollPerfProbe.shared.bump("imagePhase.\(phase)")
          Group {
            if let image = state.image {
              if shouldRenderLiveText {
                LiveTextInteraction(image: image)
                  .scaledToFill()
              } else if requestImageScaledToFill {
                image
                  .resizable()
                  .scaledToFill()
              } else {
                image
  //                .resizable()
  //                .scaledToFit()
              }
            } else if state.error != nil {
              URLImageFailureView()
            } else {
              placeholderView()
            }
          }
          .onAppear {
            recordImageEvent(
              .debug,
              message: "Image phase appeared",
              source: "request",
              phase: phase,
              error: state.error?.localizedDescription
            )
            if phase == "image" { scheduleLiveTextActivation(source: "request-phase") }
          }
        }
        .onCompletion { result in
          loadCompleted = true
          recordCompletion(result, source: "request")
          if case .failure(let error) = result {
            AppDiagnostics.asyncRecord(
              .warning,
              category: "ui.image",
              message: "Image load failed",
              metadata: imageDiagnosticsMetadata(source: "request", error: error.localizedDescription)
            )
          }
          if case .failure = result, retryCount < 2 {
            retryImageLoad(source: "request-failure")
          } else if case .failure = result {
            onLoadFailed?()
          }
          if case .success = result {
            onLoadSucceeded?()
            scheduleLiveTextActivation(source: "request-success")
          }
        }
        .onDisappear(.lowerPriority)
        .onAppear { beginImageLoad(source: "request") }
        .onDisappear { endImageLoad() }
        .id("\(requestIdentity)-\(retryID)")
        .onChange(of: requestIdentity) {
          recordImageEvent(.debug, message: "Image request identity changed", source: "request-change", phase: "identity-change")
          retryCount = 0
          loadCompleted = false
          resetLiveTextActivation()
          retryID = UUID()
          scheduleStallCheck(source: "request-change")
        }
        .onChange(of: liveTextActivationTrigger) { _, newValue in
          handleLiveTextTriggerChange(newValue)
        }
        .diagnosticLayout("URLImage.request", metadata: imageDiagnosticsMetadata(source: "request-layout", error: nil))
      } else {
        LazyImage(url: url) { state in
          let phase = imagePhase(hasImage: state.image != nil, error: state.error)
          let _ = ScrollPerfProbe.shared.bump("imagePhase.\(phase)")
          Group {
            if let image = state.image {
              if shouldRenderLiveText {
                LiveTextInteraction(image: image)
                  .scaledToFill()
              } else {
                image
                  .resizable()
                  .scaledToFit()
              }
            } else if state.error != nil {
              URLImageFailureView()
            } else {
              placeholderView()
            }
          }
          .onAppear {
            recordImageEvent(
              .debug,
              message: "Image phase appeared",
              source: "url",
              phase: phase,
              error: state.error?.localizedDescription
            )
            if phase == "image" { scheduleLiveTextActivation(source: "url-phase") }
          }
        }
        .processors(processors)
        .onCompletion { result in
          loadCompleted = true
          recordCompletion(result, source: "url")
          if case .failure(let error) = result {
            AppDiagnostics.asyncRecord(
              .warning,
              category: "ui.image",
              message: "Image load failed",
              metadata: imageDiagnosticsMetadata(source: "url", error: error.localizedDescription)
            )
          }
          if case .failure = result, retryCount < 2 {
            retryImageLoad(source: "url-failure")
          } else if case .failure = result {
            onLoadFailed?()
          }
          if case .success = result {
            onLoadSucceeded?()
            scheduleLiveTextActivation(source: "url-success")
          }
        }
        .onDisappear(.cancel)
        .onAppear { beginImageLoad(source: "url") }
        .onDisappear { endImageLoad() }
        .id("\(requestIdentity)-\(retryID)")
        .onChange(of: requestIdentity) {
          recordImageEvent(.debug, message: "Image request identity changed", source: "url-change", phase: "identity-change")
          retryCount = 0
          loadCompleted = false
          resetLiveTextActivation()
          retryID = UUID()
          scheduleStallCheck(source: "url-change")
        }
        .onChange(of: liveTextActivationTrigger) { _, newValue in
          handleLiveTextTriggerChange(newValue)
        }
        .diagnosticLayout("URLImage.url", metadata: imageDiagnosticsMetadata(source: "url-layout", error: nil))
      }
      
    }
  }

  private var loaderSize: Double {
    Double(min(max(size?.width ?? 50, 24), 50))
  }

  @ViewBuilder
  private func placeholderView() -> some View {
    if showPlaceholder {
      URLImagePlaceholderView(loaderSize: loaderSize).equatable()
    } else {
      Color.clear
    }
  }

  private func beginImageLoad(source: String) {
    ScrollPerfProbe.shared.bump("imageLoadAppear")
    isVisible = true
    loadStartedAt = Date()
    resetLiveTextActivation()
    recordImageEvent(.debug, message: "Image load appeared", source: source, phase: "appear")
    scheduleStallCheck(source: source)
    scheduleLiveTextActivation(source: "\(source)-appear")
  }

  private func endImageLoad() {
    ScrollPerfProbe.shared.bump("imageLoadDisappear")
    recordImageEvent(.debug, message: "Image load disappeared", source: "disappear", phase: "disappear")
    isVisible = false
    loadCompleted = true
    cancelLiveTextActivation()
  }

  private func resetLiveTextActivation() {
    liveTextGeneration = UUID()
    liveTextActivationScheduled = false
    liveTextReady = liveTextActivationDelay == nil
  }

  private func cancelLiveTextActivation() {
    liveTextGeneration = UUID()
    liveTextActivationScheduled = false
    if liveTextActivationDelay != nil {
      liveTextReady = false
    }
  }

  private func handleLiveTextTriggerChange(_ isTriggered: Bool) {
    if isTriggered {
      scheduleLiveTextActivation(source: "trigger-change")
    } else {
      cancelLiveTextActivation()
    }
  }

  private func scheduleLiveTextActivation(source: String) {
    guard doLiveText, liveTextActivationTrigger, ImageAnalyzer.isSupported else { return }
    guard let liveTextActivationDelay else {
      liveTextReady = true
      return
    }
    guard isVisible, !liveTextReady, !liveTextActivationScheduled else { return }
    liveTextActivationScheduled = true
    let generation = liveTextGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + liveTextActivationDelay) {
      guard isVisible, liveTextGeneration == generation, liveTextActivationTrigger else { return }
      ScrollPerfProbe.shared.bump("liveTextActivated")
      liveTextReady = true
      recordImageEvent(.debug, message: "Live Text activated", source: source, phase: "live-text-ready")
    }
  }

  private func scheduleStallCheck(source: String) {
    let generation = UUID()
    loadGeneration = generation
    loadCompleted = false
    DispatchQueue.main.asyncAfter(deadline: .now() + stallTimeout) {
      runStallCheck(source: source, generation: generation)
    }
  }

  private func runStallCheck(source: String, generation: UUID) {
    guard isVisible && loadGeneration == generation && !loadCompleted else { return }
    if shouldDeferFeedWork {
      FeedScrollWorkCoordinator.shared.performWhenIdle(key: "image.stall.\(requestWorkKey)") {
        runStallCheck(source: source, generation: generation)
      }
      return
    }
    ScrollPerfProbe.shared.bump("imageLoadStalled")
    AppDiagnostics.asyncRecord(
      .warning,
      category: "ui.image",
      message: "Image still loading after \(stallTimeout)s",
      metadata: imageDiagnosticsMetadata(source: source, error: nil)
    )
    guard retryCount >= 2 else {
      retryImageLoad(source: source)
      return
    }
    onLoadStalled?()
    retryImageLoad(source: source)
  }

  private func retryImageLoad(source: String) {
    guard isVisible && retryCount < 2 else {
      recordImageEvent(.debug, message: "Image retry skipped", source: source, phase: "retry-skipped")
      return
    }
    if shouldDeferFeedWork {
      FeedScrollWorkCoordinator.shared.performWhenIdle(key: "image.retry.\(requestWorkKey)") {
        retryImageLoad(source: source)
      }
      return
    }
    ScrollPerfProbe.shared.bump("imageRetry")
    retryCount += 1
    AppDiagnostics.asyncRecord(
      .info,
      category: "ui.image",
      message: "Retrying stalled image load",
      metadata: imageDiagnosticsMetadata(source: "\(source)-retry", error: nil)
    )
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      refreshRetryImageLoad(source: source)
    }
  }

  private func refreshRetryImageLoad(source: String) {
    guard isVisible else {
      recordImageEvent(.debug, message: "Image retry aborted before refresh", source: source, phase: "retry-aborted")
      return
    }
    if shouldDeferFeedWork {
      FeedScrollWorkCoordinator.shared.performWhenIdle(key: "image.retryRefresh.\(requestWorkKey)") {
        refreshRetryImageLoad(source: source)
      }
      return
    }
    loadCompleted = false
    recordImageEvent(.debug, message: "Image retry refreshing request", source: source, phase: "retry-refresh")
    retryID = UUID()
    scheduleStallCheck(source: "\(source)-retry")
  }

  private func recordCompletion<Failure: Error>(_ result: Result<ImageResponse, Failure>, source: String) {
    switch result {
    case .success:
      ScrollPerfProbe.shared.bump("imageLoadSuccess")
      recordImageEvent(.debug, message: "Image load completed", source: source, phase: "success")
    case .failure(let error):
      ScrollPerfProbe.shared.bump("imageLoadFailure")
      recordImageEvent(.warning, message: "Image load completed", source: source, phase: "failure", error: error.localizedDescription)
    }
  }

  private func imagePhase(hasImage: Bool, error: Error?) -> String {
    if hasImage { return "image" }
    if error != nil { return "error" }
    return "placeholder"
  }

  private func recordImageEvent(
    _ level: DiagnosticLevel,
    message: String,
    source: String,
    phase: String,
    error: String? = nil
  ) {
    AppDiagnostics.asyncRecord(
      level,
      category: "ui.image",
      message: message,
      metadata: imageDiagnosticsMetadata(source: source, phase: phase, error: error)
    )
  }

  private func imageDiagnosticsMetadata(source: String, error: String?) -> [String: String] {
    imageDiagnosticsMetadata(source: source, phase: "unspecified", error: error)
  }

  private func imageDiagnosticsMetadata(source: String, phase: String, error: String?) -> [String: String] {
    [
      "source": source,
      "phase": phase,
      "url": url.absoluteString,
      "request": imgRequest?.description ?? "nil",
      "processors": processors?.map { $0.identifier }.joined(separator: "|") ?? "nil",
      "size": "\(size?.width ?? 0)x\(size?.height ?? 0)",
      "context": diagnosticContext ?? "nil",
      "retryCount": "\(retryCount)",
      "retryID": retryID.uuidString,
      "requestIdentityHash": "\(requestIdentity.hashValue)",
      "stallTimeout": "\(stallTimeout)",
      "showPlaceholder": "\(showPlaceholder)",
      "requestImageScaledToFill": "\(requestImageScaledToFill)",
      "isVisible": "\(isVisible)",
      "loadCompleted": "\(loadCompleted)",
      "elapsedMs": elapsedMsString(),
      "error": error ?? "nil"
    ]
  }

  private func elapsedMsString() -> String {
    guard let loadStartedAt else { return "nil" }
    return "\(Int(Date().timeIntervalSince(loadStartedAt) * 1000))"
  }
}

struct URLImagePlaceholderView: View, Equatable {
  static func == (lhs: URLImagePlaceholderView, rhs: URLImagePlaceholderView) -> Bool {
    lhs.loaderSize == rhs.loaderSize
  }

  let loaderSize: Double

  var body: some View {
    Rectangle()
      .fill(Color.primary.opacity(0.06))
      .overlay {
        ProgressView()
          .controlSize(loaderSize < 32 ? .small : .regular)
      }
  }
}

struct URLImageFailureView: View {
  var body: some View {
    Rectangle()
      .fill(.regularMaterial)
      .overlay {
        Image(systemName: "exclamationmark.triangle.fill")
          .fontSize(20, .semibold)
          .foregroundStyle(.secondary)
      }
  }
}

struct ThumbReqImage: View, Equatable {
  static func == (lhs: ThumbReqImage, rhs: ThumbReqImage) -> Bool {
    lhs.imgRequest.url == rhs.imgRequest.url
  }
  
  var imgRequest: ImageRequest
  var size: CGSize?
  
  var body: some View {
    LazyImage(request: imgRequest) { state in
//                if case .success(let response) = state.result {
////                  Image(uiImage: response.image).resizable()
//                  AltImage(image: response.image, size: size)
//                }
      if let image = state.image {
        image
      } else {
        Color.acceptablePrimary
      }
//      } else if state.error != nil {
//        Color.red.opacity(0.1)
//          .overlay(Image(systemName: "xmark.circle.fill").foregroundColor(.red))
//      } else {
//        URLImageLoader(size: 50).equatable()
//      }
    }
    .onDisappear(.cancel)
    //        .id("\(imgRequest.url?.absoluteString ?? "")-nuke")
  }
}


struct URLImageLoader: View, Equatable {
  static func == (lhs: URLImageLoader, rhs: URLImageLoader) -> Bool {
    lhs.size == rhs.size
  }
  
  let size: Double
  
  var body: some View {
    Image(.loader)
      .resizable()
      .scaledToFill()
      .mask(Circle())
      .opacity(0.5)
      .frame(maxWidth: size, maxHeight: size)
  }
}

//extension ImageRequest: Equatable {
//  public static func == (lhs: Nuke.ImageRequest, rhs: Nuke.ImageRequest) -> Bool {
//    lhs.imageId == rhs.imageId
//  }
//}

//extension FetchImage: Equatable {
//  public static func == (lhs: FetchImage, rhs: FetchImage) -> Bool {
//    lhs.id == rhs.id
//  }
//}
