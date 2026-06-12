//
//  ImageMediaPost.swift
//  winston
//
//  Created by Igor Marcossi on 04/07/23.
//

import SwiftUI
import Defaults
import NukeUI
import Nuke

struct ImageMediaPostCompactMoreImagesOverlay: View, Equatable {
  static func == (lhs: ImageMediaPostCompactMoreImagesOverlay, rhs: ImageMediaPostCompactMoreImagesOverlay) -> Bool {
    return lhs.count == rhs.count
  }
  var count: Int
  var body: some View {
    Text("\(count)+")
      .fontSize(12, .semibold)
      .padding(.all, 6)
      .background(Circle().fill(.bar))
      .padding(.all, 4)
      .allowsHitTesting(false)
  }
}

struct ImageMediaPost: View, Equatable {
  static let gallerySpacing: CGFloat = 8
  static func == (lhs: ImageMediaPost, rhs: ImageMediaPost) -> Bool {
    return lhs.postTitle == rhs.postTitle && lhs.compact == rhs.compact && lhs.contentWidth == rhs.contentWidth && lhs.badgeKit == rhs.badgeKit && lhs.cornerRadius == rhs.cornerRadius && lhs.images == rhs.images && lhs.diagnosticContext == rhs.diagnosticContext
  }
    
  @Binding var postDimensions: PostDimensions
  weak var controller: UIViewController?
  let postTitle: String
  let badgeKit: BadgeKit
  let avatarImageRequest: ImageRequest?
  let markAsSeen: (() async -> ())?
  var cornerRadius: Double
  var compact = false
  var images: [ImgExtracted]
  var contentWidth: CGFloat
  var maxMediaHeightScreenPercentage: CGFloat
  var diagnosticContext: String? = nil
//  @State var fullscreen = false
  @State var fullscreenIndex: Int?
  
  var body: some View {
    Group {
      if images.isEmpty {
        ImageMediaUnavailablePreview(cornerRadius: cornerRadius, compact: compact)
      } else if images.count == 1 || compact {
        ImageMediaSinglePreview(
          postDimensions: $postDimensions,
          cornerRadius: cornerRadius,
          compact: compact,
          image: images[0],
          imageCount: images.count,
          contentWidth: contentWidth,
          maxMediaHeightScreenPercentage: maxMediaHeightScreenPercentage,
          diagnosticContext: diagnosticContext,
          open: { fullscreenIndex = 0 }
        )
      } else {
        ImageMediaGalleryPreview(
          cornerRadius: cornerRadius,
          images: images,
          contentWidth: contentWidth,
          diagnosticContext: diagnosticContext,
          open: { fullscreenIndex = $0 }
        )
      }
    }
    .frame(maxWidth: compact ? nil : .infinity)
//    .customPresenter(parentController: controller, isPresented: Binding(get: {
//      fullscreenIndex != nil
//    }, set: { val in
//      if !val { fullscreenIndex = nil }
//    }), content: {
//      LightBoxImage(postTitle: postTitle, badgeKit: badgeKit, markAsSeen: markAsSeen, i: fullscreenIndex ?? 0, imagesArr: images)
//    })
    .fullScreenCover(item: $fullscreenIndex) { i in
      LightBoxImage(postTitle: postTitle, badgeKit: badgeKit, avatarImageRequest: avatarImageRequest, markAsSeen: markAsSeen, i: min(max(i, 0), max(images.count - 1, 0)), imagesArr: images, doLiveText: Defaults[.BehaviorDefSettings].doLiveText)
    }
  }
}

private struct ImageMediaSinglePreview: View {
  @Binding var postDimensions: PostDimensions
  let cornerRadius: Double
  let compact: Bool
  let image: ImgExtracted
  let imageCount: Int
  let contentWidth: CGFloat
  let maxMediaHeightScreenPercentage: CGFloat
  let diagnosticContext: String?
  let open: () -> Void

  private var width: CGFloat {
    compact ? scaledCompactModeThumbSize() : max(contentWidth, 1)
  }

  private var height: CGFloat? {
    if compact { return scaledCompactModeThumbSize() }
    guard image.size.width > 0, image.size.height > 0 else { return nil }
    let proportionalHeight = (max(contentWidth, 1) * image.size.height) / image.size.width
    guard maxMediaHeightScreenPercentage != 110 else { return proportionalHeight }
    return min((maxMediaHeightScreenPercentage / 100) * .screenH, proportionalHeight)
  }

  var body: some View {
    GalleryThumb(cornerRadius: cornerRadius, width: width, height: height, url: image.url, imgRequest: image.request, diagnosticContext: diagnosticContext)
      .background(
        height == nil && !compact
        ? GeometryReader { geo in
          Color.clear
            .onAppear { postDimensions.mediaSize = geo.size }
            .onChange(of: geo.size) { postDimensions.mediaSize = $0 }
        }
        : nil
      )
      .onTapGesture { withAnimation(spring) { open() } }
      .overlay(alignment: .bottomTrailing) {
        if compact && imageCount > 1 {
          ImageMediaPostCompactMoreImagesOverlay(count: imageCount - 1).equatable()
        }
      }
  }
}

private struct ImageMediaGalleryPreview: View {
  let cornerRadius: Double
  let images: [ImgExtracted]
  let contentWidth: CGFloat
  let diagnosticContext: String?
  let open: (Int) -> Void

  private var tileWidth: CGFloat {
    max(1, (contentWidth - ImageMediaPost.gallerySpacing) / 2)
  }

  var body: some View {
    VStack(spacing: ImageMediaPost.gallerySpacing) {
      HStack(spacing: ImageMediaPost.gallerySpacing) {
        ImageMediaGalleryTile(cornerRadius: cornerRadius, image: images[0], width: tileWidth, height: tileWidth, diagnosticContext: diagnosticContext, open: { open(0) })
        ImageMediaGalleryTile(cornerRadius: cornerRadius, image: images[1], width: tileWidth, height: tileWidth, diagnosticContext: diagnosticContext, open: { open(1) })
      }

      if images.count > 2 {
        HStack(spacing: ImageMediaPost.gallerySpacing) {
          ImageMediaGalleryTile(cornerRadius: cornerRadius, image: images[2], width: images.count == 3 ? max(contentWidth, 1) : tileWidth, height: tileWidth, diagnosticContext: diagnosticContext, open: { open(2) })

          if images.count > 3 {
            ImageMediaGalleryTile(cornerRadius: cornerRadius, image: images[3], width: tileWidth, height: tileWidth, diagnosticContext: diagnosticContext, open: { open(3) })
              .overlay {
                if images.count > 4 {
                  ImageMediaMoreOverlay(count: images.count - 4)
                }
              }
          }
        }
      }
    }
  }
}

private struct ImageMediaGalleryTile: View {
  let cornerRadius: Double
  let image: ImgExtracted
  let width: CGFloat
  let height: CGFloat
  let diagnosticContext: String?
  let open: () -> Void

  var body: some View {
    GalleryThumb(cornerRadius: cornerRadius, width: width, height: height, url: image.url, imgRequest: image.request, diagnosticContext: diagnosticContext)
      .equatable()
      .onTapGesture { withAnimation(spring) { open() } }
  }
}

private struct ImageMediaMoreOverlay: View {
  let count: Int

  var body: some View {
    ZStack {
      Rectangle()
        .fill(.black.opacity(0.42))
      Text("+\(count)")
        .fontSize(28, .bold)
        .foregroundStyle(.white)
        .minimumScaleFactor(0.7)
    }
    .allowsHitTesting(false)
  }
}

private struct ImageMediaUnavailablePreview: View {
  let cornerRadius: Double
  let compact: Bool

  var body: some View {
    Rectangle()
      .fill(.regularMaterial)
      .overlay {
        Image(systemName: "photo")
          .fontSize(22, .semibold)
          .foregroundStyle(.secondary)
      }
      .frame(width: compact ? scaledCompactModeThumbSize() : nil, height: compact ? scaledCompactModeThumbSize() : 120)
      .mask(RR(cornerRadius, Color.black).equatable())
  }
}

/// Either returns the content width or, if compact mode is enabled, the modified content width depending on what setting the user chose
func scaledCompactModeThumbSize(compact: Bool = Defaults[.PostLinkDefSettings].compactMode.enabled, thumbnailSize: ThumbnailSizeModifier = Defaults[.PostLinkDefSettings].compactMode.thumbnailSize) -> CGFloat {
  
  if compact {
    return compactModeThumbSize * thumbnailSize.rawVal
  } else {
    return compactModeThumbSize
  }
}

extension Int: Identifiable {
    public var id: Int { self }
}
