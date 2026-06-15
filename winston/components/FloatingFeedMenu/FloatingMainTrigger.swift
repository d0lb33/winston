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
  let primaryAction: ()->()
  let size: Double
  let actionsSize: Double

  private let longPressDuration: Double = 0.275
  @State private var handledLongPress = false

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
      if handledLongPress {
        handledLongPress = false
      } else if menuOpen {
        dismiss()
      } else {
        Hap.shared.play(intensity: 0.75, sharpness: 0.9)
        primaryAction()
      }
    } label: {
      Image(systemName: menuOpen ? "xmark" : "eye.slash.fill")
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
    .accessibilityLabel(menuOpen ? "Close feed tools" : "Hide read posts")
    .accessibilityAction(named: Text("Open feed tools")) {
      if !menuOpen {
        openMenu()
      }
    }
    .onLongPressGesture(minimumDuration: longPressDuration, maximumDistance: 12) {
      guard !menuOpen else { return }
      handledLongPress = true
      openMenu()
    }
    .increaseHitboxOf(size, by: 1.125, shape: Circle(), disable: menuOpen)
    .shrinkOnTap()
  }
}

struct FeedFloatingToolbar: View, Equatable {
  static func == (lhs: FeedFloatingToolbar, rhs: FeedFloatingToolbar) -> Bool {
    lhs.size == rhs.size
  }

  let action: ()->()
  var size: Double = 64

  var body: some View {
    Button {
      Hap.shared.play(intensity: 0.75, sharpness: 0.9)
      action()
    } label: {
      Image(systemName: "eye.slash.fill")
        .fontSize(22, .bold)
        .frame(width: size, height: size)
        .foregroundColor(Color.accentColor)
        .floating()
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Hide read posts")
    .increaseHitboxOf(size, by: 1.125, shape: Circle())
    .shrinkOnTap()
  }
}
