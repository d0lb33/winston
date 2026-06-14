//
//  MockFormatting.swift
//  winston
//
//  Design Lab — local formatting helpers. Intentionally NOT the app's production
//  formatters, to keep the module self-contained.
//

import Foundation

enum MockFormatting {
  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
  }()

  /// `secondsAgo` is a positive number of seconds in the past → "3h ago", "2d ago".
  static func relativeTime(_ secondsAgo: TimeInterval) -> String {
    relativeFormatter.localizedString(fromTimeInterval: -secondsAgo)
  }

  /// Compact score formatting → "1.2k", "18.4k", "1.1M".
  static func compactNumber(_ value: Int) -> String {
    let magnitude = abs(value)
    let sign = value < 0 ? "-" : ""
    switch magnitude {
    case 1_000_000...:
      return sign + trimmed(Double(magnitude) / 1_000_000) + "M"
    case 10_000...:
      return sign + String(Int((Double(magnitude) / 1_000).rounded())) + "k"
    case 1_000...:
      return sign + trimmed(Double(magnitude) / 1_000) + "k"
    default:
      return "\(value)"
    }
  }

  private static func trimmed(_ value: Double) -> String {
    value.rounded() == value
      ? String(format: "%.0f", value)
      : String(format: "%.1f", value)
  }
}
