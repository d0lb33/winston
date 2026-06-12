//
//  FloatingMainTrigger.swift
//  winston
//
//  Created by Igor Marcossi on 28/12/23.
//

import SwiftUI

struct FloatingMainTrigger: View, Equatable {
  static func == (lhs: FloatingMainTrigger, rhs: FloatingMainTrigger) -> Bool {
    lhs.menuOpen == rhs.menuOpen
  }
  
  @Binding var menuOpen: Bool
  @Binding var showingFilters: Bool
  let dismiss: ()->()
  let size: Double
  let actionsSize: Double

  private let longPressDuration: Double = 0.275

  private func openMenu() {
    Hap.shared.play(intensity: 0.75, sharpness: 0.4)
    withAnimation(.snappy(extraBounce: 0.3)) {
      menuOpen = true
    }
    withAnimation {
      showingFilters = true
    }
  }
  
  var body: some View {
    Button {
      if menuOpen {
        dismiss()
      } else {
        openMenu()
      }
    } label: {
      Image(systemName: menuOpen ? "xmark" : "slider.vertical.3")
        .contentTransition(.symbolEffect)
        .transaction { trans in
          trans.animation = .easeInOut(duration: longPressDuration)
        }
        .fontSize(22, .bold)
        .frame(width: size, height: size)
        .foregroundColor(menuOpen ? .pink : Color.accentColor)
        .brightness(menuOpen ? 0.35 : 0)
        .background(Circle().fill(.white.opacity(menuOpen ? 0.5 : 0)).blendMode(.overlay))
        .floating()
        .scaleEffect(menuOpen ? actionsSize / size : 1)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(menuOpen ? "Close feed tools" : "Open feed tools")
    .increaseHitboxOf(size, by: 1.125, shape: Circle(), disable: menuOpen)
    .shrinkOnTap()
  }
}
