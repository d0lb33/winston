//
//  LinkImageCardNative.swift
//  winston
//
//  Native-only "fuller" rendering for external LINK posts that carry a Reddit
//  preview image: instead of the small 88pt link card, show the preview image at
//  full column width (sized by the source aspect ratio, capped by the media-height
//  setting) with the destination domain as a chip. Tapping opens the link.
//
//  This is deliberately a separate, native-path view — the global mediaExtractor is
//  left untouched (it still classifies these as `.link` so the legacy feed and the
//  rest of the app are unaffected).
//

import SwiftUI
import NukeUI

struct LinkImageCardNative: View, Equatable {
  static func == (lhs: LinkImageCardNative, rhs: LinkImageCardNative) -> Bool {
    lhs.imageURL == rhs.imageURL && lhs.displayURL == rhs.displayURL && lhs.widthBucket == rhs.widthBucket
  }

  let imageURL: URL
  /// Source pixel size from the Reddit preview (for the aspect ratio).
  let sourceSize: CGSize
  /// The link to open on tap.
  let displayURL: URL
  /// Live, measured content width.
  let columnWidth: CGFloat
  /// Pre-decoded once upstream.
  let maxMediaHeightPct: CGFloat
  let cornerRadius: CGFloat

  private var widthBucket: Int { Int((columnWidth / 2).rounded()) }

  private var height: CGFloat {
    let w = max(columnWidth, 1)
    let cap = maxMediaHeightPct == 110 ? .greatestFiniteMagnitude : (maxMediaHeightPct / 100) * .screenH
    guard sourceSize.width > 0, sourceSize.height > 0 else { return min(w, cap) }
    let proportional = (w * sourceSize.height) / sourceSize.width
    return min(cap, proportional)
  }

  var body: some View {
    let w = max(columnWidth, 1)
    let h = height
    ZStack(alignment: .bottomLeading) {
      URLImage(
        url: imageURL,
        processors: [.resize(size: CGSize(width: w, height: h))],
        size: CGSize(width: w, height: h),
        diagnosticContext: "linkImageNative:\(displayURL.host ?? "unknown")"
      )
      .scaledToFill()
      .frame(width: w, height: h)
      .clipped()

      HStack(spacing: 4) {
        Image(systemName: "link")
        Text(cleanURL(url: displayURL, showPath: false))
          .lineLimit(1)
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.primary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(.ultraThinMaterial, in: Capsule())
      .padding(10)
    }
    .frame(width: w, height: h)
    .mask(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .contentShape(Rectangle())
    .highPriorityGesture(TapGesture().onEnded {
      if let newURL = URL(string: displayURL.absoluteString.replacingOccurrences(of: "https://reddit.com/", with: "winstonapp://")) {
        Nav.openURL(newURL)
      } else {
        Nav.openURL(displayURL)
      }
    })
  }
}
