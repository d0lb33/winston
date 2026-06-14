//
//  CGSizeScreenSize.swift
//  winston
//
//  Created by Igor Marcossi on 31/12/23.
//

import Foundation

extension CGSize {
  /// Live window size — recomputed from the current cached metrics on each access
  /// so it tracks rotation / resize / fold (was a frozen `static let`).
  static var screenSize: CGSize { CGSize(width: CGFloat.screenW, height: CGFloat.screenH) }
}
