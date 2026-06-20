//
//  LightboxButton.swift
//  winston
//
//  Created by Igor Marcossi on 07/08/23.
//

import SwiftUI

struct LightBoxButton: View {
  var icon: String
  var accessibilityLabel: LocalizedStringKey = "Media action"
  var action: (()->())?
  var disabled = false
  var usesGlassSurface = true

  init(
    icon: String,
    accessibilityLabel: LocalizedStringKey = "Media action",
    disabled: Bool = false,
    usesGlassSurface: Bool = true,
    action: (() -> ())? = nil
  ) {
    self.icon = icon
    self.accessibilityLabel = accessibilityLabel
    self.disabled = disabled
    self.usesGlassSurface = usesGlassSurface
    self.action = action
  }

  @ViewBuilder var body: some View {
    if usesGlassSurface {
      button
        .liquidGlassActionSurface(.circle)
    } else {
      button
    }
  }

  private var button: some View {
    Button {
      guard !disabled else { return }
      action?()
    } label: {
      Image(systemName: icon)
        .font(.system(size: 20, weight: .semibold))
        .frame(width: 56, height: 56)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .opacity(disabled ? 0.55 : 1)
    .accessibilityLabel(accessibilityLabel)
    .transition(.scaleAndBlur)
    .id(icon)
  }
}
