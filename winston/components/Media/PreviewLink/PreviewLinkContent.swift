//
//  PreviewLinkContent.swift
//  winston
//
//  Created by Igor Marcossi on 30/07/23.
//

import Foundation
import SwiftUI
import UIKit
import NukeUI
import OpenGraph
import SkeletonUI
import YouTubePlayerKit
import Combine
import SafariServices

struct PreviewLinkContent: View {
  var compact: Bool
  @ObservedObject var viewModel: PreviewModel
  var url: URL
  var tapTarget: PreviewLinkTapTarget = .full
  static let height: CGFloat = 88
  @Environment(\.openURL) private var openURL
  var body: some View {
    let state = viewModel.state
    PreviewLinkContentRaw(
      compact: compact,
      image: state.image,
      title: state.title,
      description: state.description,
      loading: state.loading,
      url: url,
      displayURL: cleanURL(url: url),
      openURL: openURL,
      tapTarget: tapTarget
    )
  }
}

enum PreviewLinkTapTarget: Equatable {
  case full
  case sourceStrip
}

private struct PreviewLinkTapShape: Shape {
  let target: PreviewLinkTapTarget

  func path(in rect: CGRect) -> Path {
    switch target {
    case .full:
      return Rectangle().path(in: rect)
    case .sourceStrip:
      let height = min(CGFloat(34), rect.height)
      return Rectangle().path(in: CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height))
    }
  }
}


struct PreviewLinkContentRaw: View, Equatable {
  static func == (lhs: PreviewLinkContentRaw, rhs: PreviewLinkContentRaw) -> Bool {
    lhs.image == rhs.image && lhs.title == rhs.title && lhs.compact == rhs.compact && lhs.description == rhs.description && lhs.loading == rhs.loading && lhs.url == rhs.url && lhs.displayURL == rhs.displayURL && lhs.tapTarget == rhs.tapTarget
  }
  
  static let height: CGFloat = 88

  // MARK: - Non-compact "hero" card geometry
  //
  // The non-compact card is image-forward: a full-bleed banner (sized to the og:image 1.91:1
  // standard) above a self-sizing text strip (title + optional description + source domain).
  // The card renders inside a height-flexible VStack (Aurora card / MediaPresenter), so it sizes
  // to its content — `cardHeight(forWidth:)` is only the feed's pre-layout *estimate* (used for
  // postDimensions / scroll math), not a hard frame. The OpenGraph image loads async (see
  // PreviewModel); when there's none we still draw the banner (favicon placeholder) so an
  // image-less card doesn't collapse to a bare text row.
  static let bannerAspect: CGFloat = 1.91
  /// Pre-layout estimate of the text strip height (title + description + source). The card
  /// self-sizes, so a description-less card renders shorter than this — it's only an estimate.
  static let estimatedTextHeight: CGFloat = 116
  /// Decode target for the banner image — generous enough to stay crisp at @3x phone widths.
  static let bannerImagePixelSize = CGSize(width: 1080, height: 565)
  static func bannerHeight(forWidth width: CGFloat) -> CGFloat { (width / bannerAspect).rounded() }
  static func cardHeight(forWidth width: CGFloat) -> CGFloat { bannerHeight(forWidth: width) + estimatedTextHeight }

  var compact: Bool
  var image: String?
  var title: String?
  var description: String?
  var loading: Bool
  var url: URL
  var displayURL: String
  var openURL: OpenURLAction
  var tapTarget: PreviewLinkTapTarget = .full

  /// OpenGraph metadata isn't always reachable: paywalled / bot-hostile sites
  /// (e.g. wsj.com) reject the crawler with a 401/403, so `title`/`description`
  /// come back nil. Rather than surface "No title detected" placeholder text, fall
  /// back to the site host so the card stays meaningful — the same way the official
  /// client renders a link with no fetchable preview.
  private var displayTitle: String {
    guard let title, !title.isEmpty else { return cleanURL(url: url, showPath: false) }
    return title
  }

  private var hasDescription: Bool {
    guard let description else { return false }
    return !description.isEmpty
  }

  var body: some View {
    Group {
      if compact {
        compactThumbnail
      } else if image != nil || loading {
        // Has (or is still fetching) a preview image → image-forward hero. Default to hero while
        // loading since most links carry an og:image; the rare image-less link collapses below.
        heroCard
      } else {
        // No fetchable preview image (paywalled / bot-hostile sites that 401/403 the crawler) →
        // a hero banner would just show a lone favicon, so fall back to the compact text row.
        noPreviewCard
      }
    }
    .contextMenu {
      Button {
        UIPasteboard.general.string = url.absoluteString
      } label: {
        Label("Copy URL", systemImage: "link")
      }
    }
    .contentShape(PreviewLinkTapShape(target: tapTarget))
    .highPriorityGesture(TapGesture().onEnded {
      open()
    })
  }

  private func open() {
    if let newURL = URL(string: url.absoluteString.replacingOccurrences(of: "https://reddit.com/", with: "winstonapp://")) {
      openURL(newURL)
    }
  }

  // MARK: - Compact (dense feed): unchanged square thumbnail.
  private var compactThumbnail: some View {
    let imageSize = scaledCompactModeThumbSize(compact: true)
    return previewImage(targetSize: CGSize(width: imageSize, height: imageSize), faviconBox: imageSize)
      .frame(width: imageSize, height: imageSize)
      .clipped()
      .mask(RR(12, Color.black))
      .background(RR(12, Color.primary.opacity(0.1)))
  }

  // MARK: - Non-compact, no preview image: compact horizontal row (text + favicon thumbnail).
  private var noPreviewCard: some View {
    let imageSize: CGFloat = 76
    return HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 2) {
        VStack(alignment: .leading, spacing: 0) {
          Text(displayTitle)
            .fontSize(17, .medium)
            .lineLimit(1)
            .truncationMode(.tail)
          Text(displayURL)
            .fontSize(13)
            .opacity(0.5)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if hasDescription, let description {
          Text(description)
            .fontSize(14)
            .lineLimit(2)
            .opacity(0.75)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .multilineTextAlignment(.leading)

      LinkFaviconView(pageURL: url, boxSize: imageSize)
        .frame(width: imageSize, height: imageSize)
        .clipped()
        .mask(RR(12, Color.black))
        .background(RR(12, Color.primary.opacity(0.1)))
    }
    .padding(.vertical, 6)
    .padding(.leading, 10)
    .padding(.trailing, 6)
    .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
    .background(RR(16, Color.primary.opacity(0.1)))
  }

  // MARK: - Non-compact: image-forward "hero" card (full-bleed banner + title + source).
  private var heroCard: some View {
    VStack(spacing: 0) {
      banner
      heroTextStrip
    }
    .frame(maxWidth: .infinity)
    .background(RR(16, Color.primary.opacity(0.08)))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
    )
  }

  private var banner: some View {
    Rectangle()
      .fill(Color.primary.opacity(0.06))
      .aspectRatio(Self.bannerAspect, contentMode: .fit)
      .overlay {
        if let image, let imageURL = URL(string: image) {
          URLImage(
            url: imageURL,
            processors: [.resize(size: Self.bannerImagePixelSize)],
            size: Self.bannerImagePixelSize,
            diagnosticContext: "previewLink:\(url.host ?? "unknown")"
          )
          .scaledToFill()
        } else {
          // Still fetching the og:image. (A finished fetch with no image renders `noPreviewCard`
          // instead of the hero, so this branch only covers the in-flight state.)
          ProgressView()
        }
      }
      .clipped()
  }

  private var heroTextStrip: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(displayTitle)
        .fontSize(16, .semibold)
        .lineLimit(2)
        .truncationMode(.tail)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      if hasDescription, let description {
        Text(description)
          .fontSize(13)
          .opacity(0.7)
          .lineLimit(2)
          .truncationMode(.tail)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: 6) {
        LinkFaviconView(pageURL: url, boxSize: 16)
          .frame(width: 16, height: 16)
          .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        Text(displayURL)
          .fontSize(13)
          .opacity(0.5)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }

  /// Image / loader / favicon-fallback shared by the compact thumbnail.
  @ViewBuilder
  private func previewImage(targetSize: CGSize, faviconBox: CGFloat) -> some View {
    if let image, let imageURL = URL(string: image) {
      URLImage(
        url: imageURL,
        processors: [.resize(size: targetSize)],
        size: targetSize,
        diagnosticContext: "previewLink:\(url.host ?? "unknown")"
      )
      .scaledToFill()
    } else if loading {
      ProgressView()
    } else {
      LinkFaviconView(pageURL: url, boxSize: faviconBox)
    }
  }
}

/// Site badge for link cards with no fetchable preview image. Loads the source's
/// favicon and degrades to a generic link glyph if it can't be loaded.
///
/// The icon is resolved through DuckDuckGo's favicon service: it's served from a
/// CDN (so it's reachable even for paywalled / bot-hostile pages whose HTML 401s),
/// it does the icon discovery / sizing server-side, and it's the privacy-respecting
/// choice consistent with the rest of the client. Swap the host below for another
/// provider (e.g. Google's `s2/favicons`) if that ever changes.
struct LinkFaviconView: View {
  let pageURL: URL
  let boxSize: CGFloat

  private var faviconURL: URL? {
    guard let host = pageURL.host, !host.isEmpty else { return nil }
    return URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")
  }

  private var fallbackGlyph: some View {
    Image(systemName: "link").fontSize(20, .semibold)
  }

  var body: some View {
    if let faviconURL {
      LazyImage(url: faviconURL) { state in
        if let image = state.image {
          image
            .resizable()
            .scaledToFit()
            .padding(boxSize * 0.18)
        } else if state.error != nil {
          fallbackGlyph
        } else {
          // Loading: the box already shows a tinted background, so stay empty
          // rather than flashing the glyph and then swapping to the favicon.
          Color.clear
        }
      }
      .onDisappear(.cancel)
    } else {
      fallbackGlyph
    }
  }
}
