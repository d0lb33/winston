//
//  DesignLabClose.swift
//  winston
//
//  Design Lab — shared glass close affordance. Each design root presents itself in a
//  fullScreenCover (so it owns its entire nav chrome) and overlays this to dismiss.
//

import SwiftUI

struct DesignLabClose: View {
  var tint: Color = .primary
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(tint)
        .frame(width: 38, height: 38)
        .glassEffect(.regular.interactive(), in: .circle)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Close Design Lab preview")
  }
}
