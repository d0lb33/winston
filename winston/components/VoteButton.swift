//
//  VoteButton.swift
//  winston
//
//  Created by Daniel Inama on 12/08/23.
//

import SwiftUI

enum LiquidGlassActionSurfaceShape {
  case capsule
  case circle
}

private struct LiquidGlassActionSurfaceModifier: ViewModifier {
  let shape: LiquidGlassActionSurfaceShape

  @ViewBuilder
  func body(content: Content) -> some View {
    switch shape {
    case .capsule:
      if #available(iOS 26.0, *) {
        content
          .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
          .contentShape(Capsule(style: .continuous))
      } else {
        content
          .background(.ultraThinMaterial, in: Capsule(style: .continuous))
          .contentShape(Capsule(style: .continuous))
      }
    case .circle:
      if #available(iOS 26.0, *) {
        content
          .glassEffect(.regular.interactive(), in: Circle())
          .contentShape(Circle())
      } else {
        content
          .background(.ultraThinMaterial, in: Circle())
          .contentShape(Circle())
      }
    }
  }
}

extension View {
  func liquidGlassActionSurface(_ shape: LiquidGlassActionSurfaceShape = .capsule) -> some View {
    modifier(LiquidGlassActionSurfaceModifier(shape: shape))
  }
}

struct LiquidGlassIconButton: View {
  var icon: String
  var accessibilityLabel: LocalizedStringKey
  var color: Color = .secondary
  var font: Font = .body
  var size: CGFloat = 44
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(font)
        .foregroundStyle(color)
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .liquidGlassActionSurface(.circle)
    .accessibilityLabel(accessibilityLabel)
  }
}

@available(iOS 17.0, *)
struct VoteButton: View, Equatable {
  static func == (lhs: VoteButton, rhs: VoteButton) -> Bool {
    return lhs.active == rhs.active
  }
  
  var active: Bool
  var color: Color
  var image: String
  var accessibilityLabel: LocalizedStringKey
  var accessibilityValue: LocalizedStringKey
  var action: () -> Void
  
  var body: some View {
    Button(action: action) {
      Image(systemName: image)
        .symbolEffect(active ? .bounce.up : .bounce.down, options: .speed(2.75), value: active)
        .font(.system(size: 17, weight: .semibold))
        .frame(width: 34, height: 34)
        .contentShape(Rectangle())
        .foregroundStyle(active ? color : .gray)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(accessibilityValue)
  }
}

@available(iOS, deprecated: 17.0)
struct VoteButtonFallback: View, Equatable {
  static func == (lhs: VoteButtonFallback, rhs: VoteButtonFallback) -> Bool {
    return lhs.color == rhs.color && lhs.image == rhs.image
  }
  
  var color: Color
  var voteAction: () -> ()
  var image: String
  @State private var animate = true
  
  func action() {
    animate = false
    withAnimation(.spring(response: 0.3, dampingFraction: 0.5)){
      animate = true
    }
    voteAction()
  }
  
  var body: some View {
    Image(systemName: image)
      .frame(21)
      .background(Color.clear)
      .contentShape(Circle())
      .highPriorityGesture(TapGesture().onEnded(action))
      .foregroundColor(color)
      .scaleEffect(animate ? 1 : 1.3)
  }
}
