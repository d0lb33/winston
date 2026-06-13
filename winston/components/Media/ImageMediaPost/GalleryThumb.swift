//
//  GalleryThumb.swift
//  winston
//
//  Created by Igor Marcossi on 22/08/23.
//

import SwiftUI
import Defaults
import Nuke

struct GalleryThumb: View, Equatable {
  static func == (lhs: GalleryThumb, rhs: GalleryThumb) -> Bool {
    lhs.image == rhs.image && lhs.width == rhs.width && lhs.height == rhs.height && lhs.cornerRadius == rhs.cornerRadius && lhs.index == rhs.index && lhs.diagnosticContext == rhs.diagnosticContext
  }

  var cornerRadius: Double
  var width: CGFloat
  var height: CGFloat?
  var image: ImgExtracted
  /// Stable identity for the zoom transition, shared with the presented viewer's
  /// `navigationTransition(.zoom(sourceID:in:))`.
  var index: Int
  var namespace: Namespace.ID
  var diagnosticContext: String? = nil
  var open: () -> Void

  private var resizeProcessors: [ImageProcessing] {
    if image.url.pathExtension.lowercased() == "gif" {
      return []
    }
    guard let height, height > 0 else {
      return [.resize(width: width)]
    }
    return [.resize(size: CGSize(width: width, height: height))]
  }

  var body: some View {
    URLImage(url: image.url, imgRequest: image.request, processors: resizeProcessors, size: CGSize(width: width, height: height ?? 0), diagnosticContext: diagnosticContext)
      .scaledToFill()
      .zIndex(1)
      .fixedSize(horizontal: false, vertical: height == nil)
      .allowsHitTesting(false)
      .frame(width: width, height: height)
      .clipped()
      .mask(RR(cornerRadius, Color.black).equatable())
      .contentShape(Rectangle())
      .matchedTransitionSource(id: index, in: namespace)
      .onTapGesture { open() }
  }
}
