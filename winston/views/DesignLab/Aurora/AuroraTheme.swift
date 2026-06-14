//
//  AuroraTheme.swift
//  winston
//
//  Design Lab · Aurora family — the aesthetic the shared Aurora views are driven by.
//  Three presets share one UX (adaptive 3-pane glass split) but read as distinct designs:
//   • midnight  — the original Aurora: calm, glacial cyan, dark.
//   • dawn      — Solstice: warm light sunrise, rounded, airy.
//   • eclipse   — Halo: OLED black, electric violet, serif, high-contrast.
//

import SwiftUI

struct AuroraTheme: Equatable {
  var accent: Color
  var downvote: Color
  var cardFill: Color
  var chipFill: Color
  var hairline: Color
  var cornerRadius: CGFloat
  var fontDesign: Font.Design
  var colorScheme: ColorScheme
  var meshColors: [Color]
  var vignette: Color
  var vignetteStrength: Double

  var isDark: Bool { colorScheme == .dark }
  var mediaRadius: CGFloat { max(8, cornerRadius - 8) }
  var onGlass: Color { isDark ? .white : .black }

  /// Thread-rail palette: starts with the accent, then a stable spectrum.
  var railColors: [Color] { [accent, .teal, .green, .orange, .pink, .purple] }
}

extension AuroraTheme {
  static let midnight = AuroraTheme(
    accent: Color(red: 0.40, green: 0.80, blue: 0.99),
    downvote: Color(red: 0.62, green: 0.52, blue: 0.98),
    cardFill: .white.opacity(0.07),
    chipFill: .white.opacity(0.10),
    hairline: .white.opacity(0.12),
    cornerRadius: 22,
    fontDesign: .default,
    colorScheme: .dark,
    meshColors: [
      Color(red: 0.07, green: 0.09, blue: 0.22), Color(red: 0.10, green: 0.22, blue: 0.42), Color(red: 0.18, green: 0.13, blue: 0.38),
      Color(red: 0.12, green: 0.28, blue: 0.48), Color(red: 0.20, green: 0.46, blue: 0.60), Color(red: 0.28, green: 0.20, blue: 0.50),
      Color(red: 0.08, green: 0.16, blue: 0.34), Color(red: 0.16, green: 0.36, blue: 0.54), Color(red: 0.30, green: 0.24, blue: 0.55),
    ],
    vignette: .black,
    vignetteStrength: 0.22
  )

  static let dawn = AuroraTheme(
    accent: Color(red: 0.95, green: 0.40, blue: 0.24),       // warm tangerine
    downvote: Color(red: 0.42, green: 0.52, blue: 0.95),
    cardFill: .white.opacity(0.55),
    chipFill: .black.opacity(0.05),
    hairline: .black.opacity(0.08),
    cornerRadius: 26,
    fontDesign: .rounded,
    colorScheme: .light,
    meshColors: [
      Color(red: 1.00, green: 0.90, blue: 0.78), Color(red: 1.00, green: 0.82, blue: 0.66), Color(red: 0.99, green: 0.75, blue: 0.69),
      Color(red: 1.00, green: 0.86, blue: 0.66), Color(red: 0.98, green: 0.72, blue: 0.62), Color(red: 0.96, green: 0.79, blue: 0.87),
      Color(red: 1.00, green: 0.91, blue: 0.81), Color(red: 0.99, green: 0.84, blue: 0.70), Color(red: 0.97, green: 0.76, blue: 0.82),
    ],
    vignette: .white,
    vignetteStrength: 0.0
  )

  static let eclipse = AuroraTheme(
    accent: Color(red: 0.74, green: 0.38, blue: 1.00),       // electric violet
    downvote: Color(red: 0.30, green: 0.78, blue: 0.85),
    cardFill: .white.opacity(0.05),
    chipFill: .white.opacity(0.08),
    hairline: .white.opacity(0.10),
    cornerRadius: 14,
    fontDesign: .serif,
    colorScheme: .dark,
    meshColors: [
      Color(red: 0.03, green: 0.02, blue: 0.06), Color(red: 0.11, green: 0.04, blue: 0.20), Color(red: 0.17, green: 0.04, blue: 0.25),
      Color(red: 0.07, green: 0.04, blue: 0.22), Color(red: 0.23, green: 0.06, blue: 0.38), Color(red: 0.29, green: 0.06, blue: 0.30),
      Color(red: 0.04, green: 0.03, blue: 0.12), Color(red: 0.13, green: 0.05, blue: 0.24), Color(red: 0.20, green: 0.06, blue: 0.34),
    ],
    vignette: .black,
    vignetteStrength: 0.34
  )
}

// MARK: - Environment plumbing

private struct AuroraThemeKey: EnvironmentKey {
  static let defaultValue = AuroraTheme.midnight
}

extension EnvironmentValues {
  var auroraTheme: AuroraTheme {
    get { self[AuroraThemeKey.self] }
    set { self[AuroraThemeKey.self] = newValue }
  }
}
