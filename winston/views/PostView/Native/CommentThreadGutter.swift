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

  private static let palette: [Color] = [.blue, .teal, .green, .orange, .pink, .purple]

  static func color(_ level: Int) -> Color {
    palette[((level % palette.count) + palette.count) % palette.count]
  }

  var body: some View {
    if depth > 0 {
      HStack(spacing: 0) {
        ForEach(0..<depth, id: \.self) { level in
          Capsule()
            .fill(Self.color(level).opacity(0.5))
            .frame(width: 2)
            .frame(maxWidth: Self.step, alignment: .leading)
        }
      }
    }
  }
}
