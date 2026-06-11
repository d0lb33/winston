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
  @State private var retryID = UUID()
  @State private var retryCount = 0

  private var requestIdentity: String {
    [
      imgRequest?.description ?? url.absoluteString,
      processors?.map { $0.identifier }.joined(separator: "|") ?? "",
      "\(size?.width ?? 0)x\(size?.height ?? 0)",
      doLiveText ? "livetext" : ""
    ].joined(separator: "::")
  }
  
  var body: some View {
    if url.absoluteString.hasSuffix(".gif") {
      LazyImage(url: url) { state in
        if let imageData = state.imageContainer?.data {
          GIFImage(data: imageData, size: size)
            .scaledToFill()
        } else if state.error != nil {
          Color.red.opacity(0.1)
            .overlay(Image(systemName: "xmark.circle.fill").foregroundColor(.red))
        } else {
          URLImageLoader(size: 50).equatable()
        }
      }
      .onDisappear(.cancel)
      .processors(processors)
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
            Color.acceptablePrimary.opacity(0.08)
              .overlay(URLImageLoader(size: loaderSize).equatable())
          } else {
            Color.acceptablePrimary.opacity(0.08)
              .overlay(URLImageLoader(size: loaderSize).equatable())
          }
        }
        .onDisappear(.lowerPriority)
        .onCompletion { result in
          if case .failure = result, retryCount < 2 {
            retryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
              retryID = UUID()
            }
          }
        }
        .id("\(requestIdentity)-\(retryID)")
        .onChange(of: requestIdentity) { _ in
          retryCount = 0
          retryID = UUID()
        }
      } else {
        LazyImage(url: url) { state in
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
            Color.red.opacity(0.1)
              .overlay(Image(systemName: "xmark.circle.fill").foregroundColor(.red))
          } else {
            URLImageLoader(size: 50).equatable()
          }
        }
        .onDisappear(.cancel)
        .processors(processors)
      }
      
    }
  }

  private var loaderSize: Double {
    Double(min(max(size?.width ?? 50, 24), 50))
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
