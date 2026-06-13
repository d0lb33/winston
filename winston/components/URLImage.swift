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
  @State private var retryID = UUID()
  @State private var retryCount = 0
  @State private var loadGeneration = UUID()
  @State private var loadCompleted = false
  @State private var isVisible = false
  @State private var loadStartedAt: Date? = nil

  private var requestIdentity: String {
    [
      imgRequest?.description ?? url.absoluteString,
      processors?.map { $0.identifier }.joined(separator: "|") ?? "",
      "\(size?.width ?? 0)x\(size?.height ?? 0)",
      doLiveText ? "livetext" : "",
      showPlaceholder ? "placeholder" : "clear-placeholder",
      diagnosticContext ?? ""
    ].joined(separator: "::")
  }
  
  var body: some View {
    if url.pathExtension.lowercased() == "gif" {
      LazyImage(url: url) { state in
        let phase = imagePhase(hasImage: state.imageContainer?.data != nil || state.image != nil, error: state.error)
        Group {
          if let imageData = state.imageContainer?.data {
            GIFImage(data: imageData, size: size)
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
          onLoadFailed?()
          AppDiagnostics.asyncRecord(
            .warning,
            category: "ui.image",
            message: "Image load failed",
            metadata: imageDiagnosticsMetadata(source: "gif", error: error.localizedDescription)
          )
        }
        if case .failure = result, retryCount < 2 {
          retryImageLoad(source: "gif-failure")
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
          Group {
            if let image = state.image {
              if doLiveText && ImageAnalyzer.isSupported {
                LiveTextInteraction(image: image)
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
          }
        }
        .onCompletion { result in
          loadCompleted = true
          recordCompletion(result, source: "request")
          if case .failure(let error) = result {
            onLoadFailed?()
            AppDiagnostics.asyncRecord(
              .warning,
              category: "ui.image",
              message: "Image load failed",
              metadata: imageDiagnosticsMetadata(source: "request", error: error.localizedDescription)
            )
          }
          if case .failure = result, retryCount < 2 {
            retryImageLoad(source: "request-failure")
          }
          if case .success = result {
            onLoadSucceeded?()
          }
        }
        .onDisappear(.lowerPriority)
        .onAppear { beginImageLoad(source: "request") }
        .onDisappear { endImageLoad() }
        .id("\(requestIdentity)-\(retryID)")
        .onChange(of: requestIdentity) { _ in
          recordImageEvent(.debug, message: "Image request identity changed", source: "request-change", phase: "identity-change")
          retryCount = 0
          loadCompleted = false
          retryID = UUID()
          scheduleStallCheck(source: "request-change")
        }
        .diagnosticLayout("URLImage.request", metadata: imageDiagnosticsMetadata(source: "request-layout", error: nil))
      } else {
        LazyImage(url: url) { state in
          let phase = imagePhase(hasImage: state.image != nil, error: state.error)
          Group {
            if let image = state.image {
              if doLiveText && ImageAnalyzer.isSupported {
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
          }
        }
        .processors(processors)
        .onCompletion { result in
          loadCompleted = true
          recordCompletion(result, source: "url")
          if case .failure(let error) = result {
            onLoadFailed?()
            AppDiagnostics.asyncRecord(
              .warning,
              category: "ui.image",
              message: "Image load failed",
              metadata: imageDiagnosticsMetadata(source: "url", error: error.localizedDescription)
            )
          }
          if case .failure = result, retryCount < 2 {
            retryImageLoad(source: "url-failure")
          }
          if case .success = result {
            onLoadSucceeded?()
          }
        }
        .onDisappear(.cancel)
        .onAppear { beginImageLoad(source: "url") }
        .onDisappear { endImageLoad() }
        .id("\(requestIdentity)-\(retryID)")
        .onChange(of: requestIdentity) { _ in
          recordImageEvent(.debug, message: "Image request identity changed", source: "url-change", phase: "identity-change")
          retryCount = 0
          loadCompleted = false
          retryID = UUID()
          scheduleStallCheck(source: "url-change")
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
    isVisible = true
    loadStartedAt = Date()
    recordImageEvent(.debug, message: "Image load appeared", source: source, phase: "appear")
    scheduleStallCheck(source: source)
  }

  private func endImageLoad() {
    recordImageEvent(.debug, message: "Image load disappeared", source: "disappear", phase: "disappear")
    isVisible = false
    loadCompleted = true
  }

  private func scheduleStallCheck(source: String) {
    let generation = UUID()
    loadGeneration = generation
    loadCompleted = false
    DispatchQueue.main.asyncAfter(deadline: .now() + stallTimeout) {
      guard isVisible && loadGeneration == generation && !loadCompleted else { return }
      AppDiagnostics.asyncRecord(
        .warning,
        category: "ui.image",
        message: "Image still loading after \(stallTimeout)s",
        metadata: imageDiagnosticsMetadata(source: source, error: nil)
      )
      onLoadStalled?()
      retryImageLoad(source: source)
    }
  }

  private func retryImageLoad(source: String) {
    guard isVisible && retryCount < 2 else {
      recordImageEvent(.debug, message: "Image retry skipped", source: source, phase: "retry-skipped")
      return
    }
    retryCount += 1
    AppDiagnostics.asyncRecord(
      .info,
      category: "ui.image",
      message: "Retrying stalled image load",
      metadata: imageDiagnosticsMetadata(source: "\(source)-retry", error: nil)
    )
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      guard isVisible else {
        recordImageEvent(.debug, message: "Image retry aborted before refresh", source: source, phase: "retry-aborted")
        return
      }
      loadCompleted = false
      recordImageEvent(.debug, message: "Image retry refreshing request", source: source, phase: "retry-refresh")
      retryID = UUID()
      scheduleStallCheck(source: "\(source)-retry")
    }
  }

  private func recordCompletion<Failure: Error>(_ result: Result<ImageResponse, Failure>, source: String) {
    switch result {
    case .success:
      recordImageEvent(.debug, message: "Image load completed", source: source, phase: "success")
    case .failure(let error):
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
      .fill(.regularMaterial)
      .overlay {
        URLImageLoader(size: loaderSize).equatable()
      }
      .overlay {
        LinearGradient(
          colors: [.clear, .white.opacity(0.08), .clear],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        .allowsHitTesting(false)
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
