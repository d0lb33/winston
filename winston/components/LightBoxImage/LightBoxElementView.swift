//
//  LightBoxElementView.swift
//  winston
//
//  Created by Igor Marcossi on 07/08/23.
//

import SwiftUI
import NukeUI

struct LightBoxElement: Identifiable, Equatable {
  var url: String
  var size: CGSize
  var id: String { self.url }
}

struct LightBoxElementView: View {
  var el: ImgExtracted
  var onTap: (()->())?
  var doLiveText: Bool
  var isActive: Bool
  @Binding var isPinching: Bool
  @State private var altSize: CGSize = .zero
  @Binding var isZoomed: Bool
  @Binding var zoomScale: CGFloat
  @Binding var gifPlaybackState: GIFPlaybackState?
  @Binding var isGifScrubbing: Bool
  var gifScrubProgressRequest: Double?

  private var isGIF: Bool {
    el.url.pathExtension.lowercased() == "gif"
  }

  var body: some View {
    ZoomableScrollView(onTap: onTap, isZoomed: $isZoomed, zoomScale: $zoomScale){
      if isGIF {
        LazyImage(url: el.url) { state in
          Group {
            if let imageData = state.imageContainer?.data {
              ScrubbableGIFImage(
                data: imageData,
                url: el.url,
                requestedProgress: isActive ? gifScrubProgressRequest : nil,
                playbackState: isActive ? $gifPlaybackState : .constant(nil),
                isScrubbing: isActive ? $isGifScrubbing : .constant(false)
              )
            } else if let image = state.image {
              image
                .resizable()
                .scaledToFit()
            } else if state.error != nil {
              URLImageFailureView()
            } else {
              ProgressView()
                .progressViewStyle(.circular)
            }
          }
        }
        .onDisappear(.cancel)
        .scaledToFit()
      } else {
        URLImage(
          url: el.url,
          doLiveText: doLiveText,
          liveTextActivationDelay: 0.8,
          liveTextActivationTrigger: isActive
        )
          .scaledToFit()
      }
    }
    .id("\(el.id)\(altSize.width + altSize.height)")
    .frame(width: .screenW)
    .preferredColorScheme(.dark)
    .edgesIgnoringSafeArea(.all)
    .statusBar(hidden: true)
  }
}
