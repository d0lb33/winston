//
//  BGBlur.swift
//  winston
//
//  Created by Igor Marcossi on 28/12/23.
//

import SwiftUI

struct FloatingBGBlur: View, Equatable {
  static func == (lhs: FloatingBGBlur, rhs: FloatingBGBlur) -> Bool {
    lhs.active == rhs.active
  }
  
  @Environment(\.contentWidth) var contentWidth
  
  let active: Bool
  let dismiss: ()->()
  var body: some View {
    Group {
      if active {
        Rectangle()
          .fill(.bar)
          .frame(width: .screenW * 5, height: (!IPAD ? .screenW * 1.65 : .screenH * 0.75), alignment: .bottomTrailing)
          .mask(
            EllipticalGradient(
              gradient: .smooth(from: .black, to: .black.opacity(0), curve: .easeIn),
              center: .bottomTrailing,
              startRadiusFraction: 0.5,
              endRadiusFraction: 1
            )
          )
          .contentShape(Rectangle())
          .frame(width: contentWidth)
          .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in dismiss() } )
          .clipped()
          .allowsHitTesting(true)
          .transition(.opacity)
      }
    }
    .animation(.smooth, value: active)
  }
}
