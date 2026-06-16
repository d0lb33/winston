//
//  swiftEnvValues.swift
//  winston
//
//  Created by Igor Marcossi on 08/12/23.
//

import Foundation
import SwiftUI
import CoreData

private struct SheetHeightKey: EnvironmentKey {
  static let defaultValue: Double = 0
}

private struct BrighterBGKey: EnvironmentKey {
  static let defaultValue = false
}

private struct PrimaryBGContextKey: EnvironmentKey {
  static let defaultValue: NSManagedObjectContext = PersistenceController.shared.primaryBGContext
}

private struct CurrentThemeKey: EnvironmentKey {
  static let defaultValue = defaultTheme
}

private struct ContentWidthKey: EnvironmentKey {
  static let defaultValue: Double = Double(defaultContentWidth)
}

private struct DeferMediaWorkWhileScrollingKey: EnvironmentKey {
  static let defaultValue = false
}

@MainActor
@Observable
final class TabBarMetrics {
  var height: Double?

  func setHeight(_ height: Double) {
    self.height = height
  }
}

extension EnvironmentValues {
  var sheetHeight: Double {
    get { self[SheetHeightKey.self] }
    set { self[SheetHeightKey.self] = newValue }
  }
  var brighterBG: Bool {
    get { self[BrighterBGKey.self] }
    set { self[BrighterBGKey.self] = newValue }
  }
  var primaryBGContext: NSManagedObjectContext {
    get { self[PrimaryBGContextKey.self] }
    set { self[PrimaryBGContextKey.self] = newValue }
  }
  var contentWidth: Double {
    get { self[ContentWidthKey.self] }
    set { self[ContentWidthKey.self] = newValue }
  }
  var useTheme: WinstonTheme {
    get { self[CurrentThemeKey.self] }
    set { self[CurrentThemeKey.self] = newValue }
  }
  var deferMediaWorkWhileScrolling: Bool {
    get { self[DeferMediaWorkWhileScrollingKey.self] }
    set { self[DeferMediaWorkWhileScrollingKey.self] = newValue }
  }
}
