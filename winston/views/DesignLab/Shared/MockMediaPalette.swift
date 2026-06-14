//
//  MockMediaPalette.swift
//  winston
//
//  Design Lab — deterministic procedural palette + SF Symbol derived from a seed
//  string. Used as the instant, offline fallback for `SeededRemoteImage`.
//

import SwiftUI

enum MockMediaPalette {

  /// Stable, platform-independent hash (FNV-1a) so colors never change between launches.
  static func hash(_ string: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for byte in string.utf8 {
      h ^= UInt64(byte)
      h = h &* 0x100000001b3
    }
    return h
  }

  static func colors(for seed: String) -> [Color] {
    let h = hash(seed)
    let hue1 = Double(h % 360) / 360.0
    let hue2 = Double((h / 7) % 360) / 360.0
    return [
      Color(hue: hue1, saturation: 0.55, brightness: 0.88),
      Color(hue: hue2, saturation: 0.72, brightness: 0.52),
    ]
  }

  static func gradient(for seed: String) -> LinearGradient {
    LinearGradient(colors: colors(for: seed), startPoint: .topLeading, endPoint: .bottomTrailing)
  }

  private static let symbols = [
    "photo.fill", "mountain.2.fill", "globe.americas.fill", "camera.macro",
    "sparkles", "leaf.fill", "bolt.fill", "moon.stars.fill", "flame.fill",
    "drop.fill", "cloud.sun.fill", "star.fill",
  ]

  static func symbol(for seed: String) -> String {
    symbols[Int(hash(seed) % UInt64(symbols.count))]
  }
}
