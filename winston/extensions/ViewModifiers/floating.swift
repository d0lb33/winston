//
//  floating.swift
//  winston
//
//  Created by Igor Marcossi on 11/07/23.
//

import Foundation
import SwiftUI
import Defaults

struct FloatingModifier: ViewModifier {
  @Environment(\.useTheme) private var selectedTheme
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content
        .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
        .overlay {
          Capsule(style: .continuous)
            .stroke(.white.opacity(0.18), lineWidth: 0.7)
            .padding(.all, 0.5)
        }
    } else {
      content
        .background(ThemedForegroundRawBG(shape: Capsule(style: .continuous), theme: selectedTheme.general.floatingPanelsBG, shadowStyle: .drop(color: .black.opacity(0.33), radius: 16, x: 0, y: 12)))
        .overlay {
          Capsule(style: .continuous)
            .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
            .padding(.all, 0.5)
        }
    }
  }
}

extension View {
  func floating() -> some View {
    self.modifier(FloatingModifier())
  }
}
