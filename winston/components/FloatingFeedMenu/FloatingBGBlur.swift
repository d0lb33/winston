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
    GeometryReader { proxy in
      let viewportSize = CGSize(width: max(proxy.size.width, 1), height: max(proxy.size.height, 1))

      Group {
        if active {
          Rectangle()
            .fill(.bar)
            .frame(width: viewportSize.width * 5, height: (viewportSize.width < 700 ? viewportSize.width * 1.65 : viewportSize.height * 0.75), alignment: .bottomTrailing)
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
}
