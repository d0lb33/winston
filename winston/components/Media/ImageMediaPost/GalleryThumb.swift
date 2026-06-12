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
    lhs.url == rhs.url && lhs.width == rhs.width && lhs.height == rhs.height && lhs.cornerRadius == rhs.cornerRadius && lhs.diagnosticContext == rhs.diagnosticContext
  }
  
  var cornerRadius: Double
  var width: CGFloat
  var height: CGFloat?
  var url: URL
  var imgRequest: ImageRequest? = nil
  var diagnosticContext: String? = nil

  private var resizeProcessors: [ImageProcessing] {
    guard let height, height > 0 else {
      return [.resize(width: width)]
    }
    return [.resize(size: CGSize(width: width, height: height))]
  }
  
//  @Environment(\.useTheme) private var selectedTheme
  
  var body: some View {
    URLImage(url: url, imgRequest: imgRequest, processors: resizeProcessors, size: CGSize(width: width, height: height ?? 0), diagnosticContext: diagnosticContext)
      .scaledToFill()
      .zIndex(1)
      .fixedSize(horizontal: false, vertical: height == nil)
      .allowsHitTesting(false)
      .frame(width: width, height: height)
      .clipped()
      .mask(RR(cornerRadius, Color.black).equatable())
      .contentShape(Rectangle())
  }
}
