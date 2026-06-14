//
//  CommentThreadGutter.swift
//  winston
//
//  Thread rails for the native comments rebuild. One slim vertical rail per
//  ancestor depth, drawn as a leading background sized to the row's content so
//  it always spans the full row height. Rails are subtly depth-tinted (Apollo
//  style) for readable hierarchy without heavy chrome. Replaces the legacy
//  curved SVG `Arrows`.
//

import SwiftUI

struct ThreadRails: View {
  let depth: Int
  /// Width of one indentation level.
  static let step: CGFloat = 14

  /// Aurora-tinted depth rails: the palette is the active theme's `railColors`
  /// (accent-led), so the comment hierarchy reads in the same language as the rest
  /// of the app. Falls back to the default Midnight palette through the environment.
  @Environment(\.auroraTheme) private var theme

  static func color(_ level: Int, palette: [Color]) -> Color {
    palette[((level % palette.count) + palette.count) % palette.count]
  }

  var body: some View {
    if depth > 0 {
      let palette = theme.railColors
      HStack(spacing: 0) {
        ForEach(0..<depth, id: \.self) { level in
          Capsule()
            .fill(Self.color(level, palette: palette).opacity(0.55))
            .frame(width: 2)
            .frame(maxWidth: Self.step, alignment: .leading)
        }
      }
    }
  }
}
