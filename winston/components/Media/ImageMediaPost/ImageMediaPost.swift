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

  @State private var fullscreenSelection: ImageMediaFullscreenSelection?
  @Namespace private var mediaNS

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
          namespace: mediaNS,
          open: { fullscreenSelection = ImageMediaFullscreenSelection(index: 0) }
        )
      } else {
        ImageMediaGalleryPreview(
          cornerRadius: cornerRadius,
          images: images,
          contentWidth: contentWidth,
          diagnosticContext: diagnosticContext,
          namespace: mediaNS,
          open: { fullscreenSelection = ImageMediaFullscreenSelection(index: $0) }
        )
      }
    }
    .frame(maxWidth: compact ? nil : .infinity)
    .fullScreenCover(item: $fullscreenSelection) { selection in
      let index = min(max(selection.index, 0), max(images.count - 1, 0))
      Group {
        if Defaults[.BetaFeaturesDefSettings].newMediaViewer {
          AuroraMediaViewer(
            pages: images.map { .image($0) },
            startIndex: index,
            postTitle: postTitle,
            doLiveText: Defaults[.BehaviorDefSettings].doLiveText,
            markAsSeen: markAsSeen,
            returnTransitionSourceID: "image-\(images[index].id)"
          )
        } else {
          LightBoxImage(
            postTitle: postTitle,
            badgeKit: badgeKit,
            avatarImageRequest: avatarImageRequest,
            markAsSeen: markAsSeen,
            i: index,
            imagesArr: images,
            doLiveText: Defaults[.BehaviorDefSettings].doLiveText
          )
        }
      }
      .navigationTransition(.zoom(sourceID: selection.index, in: mediaNS))
    }
  }
}

private struct ImageMediaFullscreenSelection: Identifiable {
  let index: Int
  var id: Int { index }
}

private struct ImageMediaSinglePreview: View {
  @Environment(\.deferMediaWorkWhileScrolling) private var deferMediaWorkWhileScrolling
  @Binding var postDimensions: PostDimensions
  let cornerRadius: Double
  let compact: Bool
  let image: ImgExtracted
  let imageCount: Int
  let contentWidth: CGFloat
  let maxMediaHeightScreenPercentage: CGFloat
  let diagnosticContext: String?
  let namespace: Namespace.ID
  let open: () -> Void

  /// The inline media frame. For images that fit, width fills the column and height is the
  /// proportional height. For images taller than the screen-height cap, the WIDTH shrinks to keep
  /// the aspect ratio intact — so the whole image stays visible (no crop, readable inline) while
  /// never growing past the available screen space. The parent centers any narrower result.
  private var displaySize: CGSize {
    if compact {
      let side = scaledCompactModeThumbSize(compact: compact)
      return CGSize(width: side, height: side)
    }
    let availableWidth = max(contentWidth, 1)
    // Unknown source dimensions: height -1 signals "self-size to the loaded aspect ratio" so a
    // tall image isn't forced into a square that center-crops it (cutting off the text).
    guard image.size.width > 0, image.size.height > 0 else {
      return CGSize(width: availableWidth, height: -1)
    }
    let proportionalHeight = (availableWidth * image.size.height) / image.size.width
    // 110 is the "Original" sentinel: no cap, show the full proportional height.
    guard maxMediaHeightScreenPercentage != 110 else {
      return CGSize(width: availableWidth, height: proportionalHeight)
    }
    let maxHeight = (maxMediaHeightScreenPercentage / 100) * max(ScreenMetrics.bounds.height, availableWidth)
    guard proportionalHeight > maxHeight else {
      return CGSize(width: availableWidth, height: proportionalHeight)
    }
    // Too tall: cap the height and narrow the width to preserve the aspect ratio (fit, not crop).
    let cappedWidth = maxHeight * image.size.width / image.size.height
    return CGSize(width: max(1, cappedWidth), height: maxHeight)
  }

  private var width: CGFloat { displaySize.width }

  private var height: CGFloat? {
    let value = displaySize.height
    return value < 0 ? nil : value
  }

  private var mediaSizeWorkKey: String {
    "imageMediaSize.\((diagnosticContext ?? image.url.absoluteString).hashValue)"
  }

  private func sizesMatch(_ lhs: CGSize?, _ rhs: CGSize) -> Bool {
    guard let lhs else { return false }
    return abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
  }

  private func writeMediaSize(_ newSize: CGSize) {
    guard !sizesMatch(postDimensions.mediaSize, newSize) else { return }

    let apply = {
      guard !sizesMatch(postDimensions.mediaSize, newSize) else { return }
      ScrollPerfProbe.shared.bump("imageMediaSizeWrite")
      postDimensions.mediaSize = newSize
    }

    if deferMediaWorkWhileScrolling && FeedScrollWorkCoordinator.shared.shouldDeferWork {
      FeedScrollWorkCoordinator.shared.performWhenIdle(key: mediaSizeWorkKey) {
        apply()
      }
    } else {
      apply()
    }
  }

  var body: some View {
    GalleryThumb(
      cornerRadius: cornerRadius,
      width: width,
      height: height,
      image: image,
      index: 0,
      namespace: namespace,
      diagnosticContext: diagnosticContext,
      open: open
    )
      .background(
        !compact
        ? GeometryReader { geo in
          Color.clear
            // Measurement-only: must not be a tap target. `Color.clear` is hit-testable by
            // default and spans the GalleryThumb frame, so without this it steals taps around
            // the visible image and opens fullscreen (e.g. a header tap landing here).
            .allowsHitTesting(false)
            .onAppear {
              writeMediaSize(geo.size)
            }
            .onChange(of: geo.size) { _, newSize in
              writeMediaSize(newSize)
            }
        }
        : nil
      )
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
  let namespace: Namespace.ID
  let open: (Int) -> Void

  private var tileWidth: CGFloat {
    max(1, (contentWidth - ImageMediaPost.gallerySpacing) / 2)
  }

  var body: some View {
    VStack(spacing: ImageMediaPost.gallerySpacing) {
      HStack(spacing: ImageMediaPost.gallerySpacing) {
        ImageMediaGalleryTile(cornerRadius: cornerRadius, image: images[0], index: 0, namespace: namespace, width: tileWidth, height: tileWidth, diagnosticContext: diagnosticContext, open: open)
        ImageMediaGalleryTile(cornerRadius: cornerRadius, image: images[1], index: 1, namespace: namespace, width: tileWidth, height: tileWidth, diagnosticContext: diagnosticContext, open: open)
      }

      if images.count > 2 {
        HStack(spacing: ImageMediaPost.gallerySpacing) {
          ImageMediaGalleryTile(cornerRadius: cornerRadius, image: images[2], index: 2, namespace: namespace, width: images.count == 3 ? max(contentWidth, 1) : tileWidth, height: tileWidth, diagnosticContext: diagnosticContext, open: open)

          if images.count > 3 {
            ImageMediaGalleryTile(cornerRadius: cornerRadius, image: images[3], index: 3, namespace: namespace, width: tileWidth, height: tileWidth, diagnosticContext: diagnosticContext, open: open)
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
  let index: Int
  let namespace: Namespace.ID
  let width: CGFloat
  let height: CGFloat
  let diagnosticContext: String?
  let open: (Int) -> Void

  var body: some View {
    GalleryThumb(
      cornerRadius: cornerRadius,
      width: width,
      height: height,
      image: image,
      index: index,
      namespace: namespace,
      diagnosticContext: diagnosticContext,
      open: { open(index) }
    )
      .equatable()
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
      .frame(width: compact ? scaledCompactModeThumbSize(compact: compact) : nil, height: compact ? scaledCompactModeThumbSize(compact: compact) : 120)
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
