//
//  DesignLabConcept.swift
//  winston
//
//  Design Lab — the Aurora family: one UX (adaptive 3-pane glass split), three moods.
//

import SwiftUI

enum DesignLabConcept: String, Identifiable, CaseIterable {
  case aurora, solstice, eclipse

  var id: String { rawValue }

  var title: String {
    switch self {
    case .aurora:   "Aurora"
    case .solstice: "Solstice"
    case .eclipse:  "Eclipse"
    }
  }

  var tagline: String {
    switch self {
    case .aurora:   "Midnight · glacial glass"
    case .solstice: "Daybreak · warm & light"
    case .eclipse:  "After dark · electric serif"
    }
  }

  var blurb: String {
    switch self {
    case .aurora:   "The original. A calm midnight gradient, glacial-cyan accents and translucent panes that float as the screen unfolds."
    case .solstice: "Aurora at sunrise. A warm peach-and-coral wash, soft rounded type and frosted glass — the same UX, lighter on its feet."
    case .eclipse:  "Aurora after dark. True-black canvas, electric-violet accents and a serif edge. Crisper corners, higher contrast, more drama."
    }
  }

  var symbol: String {
    switch self {
    case .aurora:   "sparkles.rectangle.stack.fill"
    case .solstice: "sun.horizon.fill"
    case .eclipse:  "moon.stars.fill"
    }
  }

  var auroraTheme: AuroraTheme {
    switch self {
    case .aurora:   .midnight
    case .solstice: .dawn
    case .eclipse:  .eclipse
    }
  }

  /// Light gallery card → dark text.
  var prefersDarkText: Bool { self == .solstice }

  var accent: Color { auroraTheme.accent }
  var fontDesign: Font.Design { auroraTheme.fontDesign }

  /// A representative gradient sampled from the theme's mesh for the gallery card.
  var galleryGradient: [Color] {
    let mesh = auroraTheme.meshColors
    return [mesh[0], mesh[4], mesh[8]]
  }
}
