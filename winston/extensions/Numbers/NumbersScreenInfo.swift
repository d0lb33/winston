//
//  screenSize.swift
//  winston
//
//  Created by Igor Marcossi on 07/12/23.
//

import Foundation
import UIKit

/// Live window metrics. These used to be `static let`s captured once from
/// `UIScreen.main.bounds` at launch (in portrait), which is why the whole app
/// stayed at portrait width after rotating / resizing (letterboxed on iPhone,
/// clipped on iPad). They're now cached `var`s refreshed on the main thread
/// whenever the window scene's geometry changes (rotation / Split View / Stage
/// Manager / fold) — see `ScreenMetrics.refresh()`, called from the scene delegate.
///
/// Reads stay cheap and thread-safe (just reading a cached value), so background
/// callers like `getPostDimensions` (which runs in `concurrentMap`) are fine —
/// only `refresh()` touches UIKit, and only on the main thread.
enum ScreenMetrics {
  static var bounds: CGRect = UIScreen.main.bounds
  static var scale: CGFloat = UIScreen.main.scale

  @MainActor
  static func refresh() {
    let scenes = UIApplication.shared.connectedScenes
    let scene = (scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)
      ?? (scenes.first { $0 is UIWindowScene } as? UIWindowScene)
    guard let scene else { return }
    let window = scene.keyWindow ?? scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
    if let b = window?.bounds, b.width > 0, b.height > 0 {
      bounds = b
    } else {
      bounds = scene.screen.bounds
    }
    scale = scene.screen.scale
  }
}

// NOTE: both extensions return CGFloat (matching the original inferred types, since
// `UIScreen.main.bounds.size.width` is a CGFloat). Keeping the `Double` namespace member
// CGFloat-typed preserves the original overload-resolution behavior — making it a genuine
// `Double` overload would make `CGSize(width: .screenW, height: .screenH)` ambiguous.
extension Double {
  static var screenW: CGFloat { ScreenMetrics.bounds.width }
  static var screenH: CGFloat { ScreenMetrics.bounds.height }
  static var screenScale: CGFloat { ScreenMetrics.scale }
}

extension CGFloat {
  static var screenW: CGFloat { ScreenMetrics.bounds.width }
  static var screenH: CGFloat { ScreenMetrics.bounds.height }
  static var screenScale: CGFloat { ScreenMetrics.scale }
}
