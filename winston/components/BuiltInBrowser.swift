//
//  BuiltInBrowser.swift
//  winston
//
//  Created by Igor Marcossi on 19/09/23.
//

import SwiftUI
import SafariServices
import Defaults

struct SafariWebView: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> SFSafariViewController {
    return SFSafariViewController(url: url)
  }

  func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {

  }
}

enum AppURLRoutingDecision: Equatable {
  case openInternalReddit(RedditURLType)
  case openInAppBrowser(URL)
  case openExternally(URL)
}

enum AppURLRouter {
  static func decision(for url: URL, openLinksInApp: Bool) -> AppURLRoutingDecision {
    if let parsed = supportedParsedRedditURL(from: url) {
      return .openInternalReddit(parsed)
    }

    guard let webURL = normalizedWebURL(from: url) else {
      return .openExternally(url)
    }

    if isRedditOwnedURL(webURL) {
      return .openExternally(webURL)
    }

    return openLinksInApp ? .openInAppBrowser(webURL) : .openExternally(webURL)
  }

  private static func supportedParsedRedditURL(from url: URL) -> RedditURLType? {
    let parsed = parseRedditURL(url.absoluteString)
    if parsed.isSupportedRedditAppDestination {
      return parsed
    }

    guard let webURL = normalizedWebURL(from: url) else { return nil }
    let normalizedParsed = parseRedditURL(webURL.absoluteString)
    return normalizedParsed.isSupportedRedditAppDestination ? normalizedParsed : nil
  }

  static func normalizedWebURL(from url: URL) -> URL? {
    guard let scheme = url.scheme?.lowercased() else { return nil }

    if scheme == "http" || scheme == "https" {
      return url
    }

    guard scheme == "winstonapp" else { return nil }
    let urlStringWithoutScheme = url.absoluteString.replacingOccurrences(of: "winstonapp://", with: "")
    return URL(string: "https://" + urlStringWithoutScheme)
  }
}

extension RedditURLType {
  var isSupportedRedditAppDestination: Bool {
    switch self {
    case .post, .postID, .comment, .commentID, .subreddit, .user:
      return true
    case .youtube, .other:
      return false
    }
  }
}

func isRedditOwnedURL(_ url: URL) -> Bool {
  guard let host = url.host?.lowercased() else { return false }
  return host == "reddit.com"
    || host.hasSuffix(".reddit.com")
    || host == "redd.it"
    || host.hasSuffix(".redd.it")
    || host == "reddit.app.link"
    || host.hasSuffix(".reddit.app.link")
}

private struct InAppBrowserPresentation: Identifiable, Equatable {
  let url: URL
  var id: URL { url }
}

private struct InAppBrowserURLRouterModifier: ViewModifier {
  @Default(.BehaviorDefSettings) private var behaviorDefSettings
  @State private var browserPresentation: InAppBrowserPresentation?

  func body(content: Content) -> some View {
    let openLinksInApp = behaviorDefSettings.openLinksInApp

    content
      .environment(\.openURL, OpenURLAction { url in
        switch AppURLRouter.decision(for: url, openLinksInApp: openLinksInApp) {
        case .openInternalReddit(let parsed):
          return openParsedRedditURL(parsed) ? .handled : .systemAction(url)
        case .openInAppBrowser(let url):
          browserPresentation = InAppBrowserPresentation(url: url)
          return .handled
        case .openExternally(let url):
          return .systemAction(url)
        }
      })
      .sheet(item: $browserPresentation) { item in
        SafariWebView(url: item.url)
          .ignoresSafeArea()
      }
  }
}

extension View {
  func inAppBrowserURLRouter() -> some View {
    modifier(InAppBrowserURLRouterModifier())
  }
}
