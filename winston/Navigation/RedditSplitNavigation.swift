//
//  RedditSplitNavigation.swift
//  winston
//
//  Shared routing state for Reddit split-view surfaces. Content-column taps keep
//  browsing destinations in the content stack and send posts/comments to detail;
//  detail-column taps stay in the detail stack.
//

import SwiftUI

enum RedditNavigationOrigin: Equatable {
  case content
  case detail
}

extension RedditNavigationOrigin {
  var diagnosticsName: String {
    switch self {
    case .content: return "content"
    case .detail: return "detail"
    }
  }
}

extension NavigationSplitViewColumn {
  var diagnosticsName: String {
    switch self {
    case .sidebar: return "sidebar"
    case .content: return "content"
    case .detail: return "detail"
    default: return "unknown"
    }
  }
}

extension NavigationSplitViewVisibility {
  var diagnosticsName: String {
    switch self {
    case .automatic: return "automatic"
    case .all: return "all"
    case .doubleColumn: return "doubleColumn"
    case .detailOnly: return "detailOnly"
    default: return "unknown"
    }
  }
}

/// Abstraction over a surface's navigation sink. Link/card taps route destinations
/// through `navigateRedditDestination`, which calls into whichever navigator the surface
/// injected via `.redditNavigation(_:origin:)` (`PostsNav` / `ColumnNav` / `StackNav` /
/// `SettingsNav`). This keeps the link call sites decoupled from any concrete model.
@MainActor
protocol RedditNavigator: AnyObject {
  func navigate(_ destination: NavDest, from origin: RedditNavigationOrigin)
}

private struct RedditNavigationModelKey: EnvironmentKey {
  static let defaultValue: (any RedditNavigator)? = nil
}

private struct RedditNavigationOriginKey: EnvironmentKey {
  static let defaultValue: RedditNavigationOrigin = .detail
}

extension EnvironmentValues {
  var redditNavigationModel: (any RedditNavigator)? {
    get { self[RedditNavigationModelKey.self] }
    set { self[RedditNavigationModelKey.self] = newValue }
  }

  var redditNavigationOrigin: RedditNavigationOrigin {
    get { self[RedditNavigationOriginKey.self] }
    set { self[RedditNavigationOriginKey.self] = newValue }
  }
}

extension View {
  func redditNavigation(_ model: any RedditNavigator, origin: RedditNavigationOrigin) -> some View {
    self
      .environment(\.redditNavigationModel, model)
      .environment(\.redditNavigationOrigin, origin)
  }
}

@MainActor
func navigateRedditDestination(
  _ destination: NavDest,
  model: (any RedditNavigator)?,
  origin: RedditNavigationOrigin
) {
  AppDiagnostics.asyncBreadcrumb(
    "navigateRedditDestination",
    metadata: [
      "destination": destination.diagnosticsName,
      "origin": origin.diagnosticsName,
      "hasSplitModel": "\(model != nil)"
    ]
  )
  if let model {
    model.navigate(destination, from: origin)
  } else {
    Nav.to(destination)
  }
}
