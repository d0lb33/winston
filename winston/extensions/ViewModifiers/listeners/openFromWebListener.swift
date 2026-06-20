//
//  openFromWebListener.swift
//  winston
//
//  Created by Igor Marcossi on 10/12/23.
//

import SwiftUI
import Defaults

@discardableResult
@MainActor
func openParsedRedditURL(_ parsed: RedditURLType) -> Bool {
  guard let destination = parsed.navDestination else { return false }
  AppNav.shared.navigateRedditURLDestination(destination)
  return true
}

extension RedditURLType {
  @MainActor
  var navDestination: NavDest? {
    switch self {
    case .post(let postID, let subID):
      return .reddit(.post(Post(id: postID, subID: subID)))
    case .postID(let postID):
      return .reddit(.post(Post(id: postID)))
    case .comment(let commentID, let postID, let subID):
      return .reddit(.postHighlighted(Post(id: postID, subID: subID), commentID))
    case .commentID(let commentID, let postID):
      return .reddit(.postHighlighted(Post(id: postID), commentID))
    case .subreddit(let name):
      return .reddit(.subFeed(Subreddit(id: name)))
    case .user(let username):
      return .reddit(.user(User(id: username)))
    default:
      return nil
    }
  }
}

private let redditClipboardURLDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

private struct ClipboardRedditLinkCandidate: Equatable {
  let url: URL
  let parsed: RedditURLType
  let isRedditOwned: Bool
}

private enum ClipboardRedditLinkAlert: Identifiable, Equatable {
  case supported(url: URL, parsed: RedditURLType)
  case unsupported(url: URL)

  var id: String {
    switch self {
    case .supported(let url, _):
      return "supported-\(url.absoluteString)"
    case .unsupported(let url):
      return "unsupported-\(url.absoluteString)"
    }
  }
}

private struct ExternalImagePresentation: Identifiable, Equatable {
  let url: URL
  var id: URL { url }
}

private struct ClipboardRedditLinkListenerModifier: ViewModifier {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL
  @Default(.BehaviorDefSettings) private var behaviorDefSettings

  @State private var lastHandledPasteboardChangeCount: Int?
  @State private var pendingAlert: ClipboardRedditLinkAlert?

  func body(content: Content) -> some View {
    content
      .onAppear {
        checkClipboardForRedditLink()
      }
      .onChange(of: scenePhase) { _, newPhase in
        if newPhase == .active {
          checkClipboardForRedditLink()
        }
      }
      .alert(item: $pendingAlert) { alert in
        switch alert {
        case .supported(let url, let parsed):
          return Alert(
            title: Text("Open Reddit link?"),
            message: Text(url.absoluteString),
            primaryButton: .default(Text("Open")) {
              _ = openParsedRedditURL(parsed)
            },
            secondaryButton: .cancel()
          )
        case .unsupported(let url):
          return Alert(
            title: Text("Unsupported Reddit link"),
            message: Text("Winston cannot open this link directly."),
            primaryButton: .default(Text("Open in Safari")) {
              openURL(url)
            },
            secondaryButton: .cancel()
          )
        }
      }
  }

  private func checkClipboardForRedditLink() {
    guard behaviorDefSettings.openRedditLinksFromClipboard else { return }
    let pasteboard = UIPasteboard.general
    let changeCount = pasteboard.changeCount
    guard lastHandledPasteboardChangeCount != changeCount else { return }
    guard pasteboard.hasStrings else {
      lastHandledPasteboardChangeCount = changeCount
      return
    }

    lastHandledPasteboardChangeCount = changeCount
    guard let string = pasteboard.string, let candidate = firstRedditLinkCandidate(in: string) else { return }

    if candidate.parsed.isSupportedRedditAppDestination {
      pendingAlert = .supported(url: candidate.url, parsed: candidate.parsed)
    } else if candidate.isRedditOwned {
      pendingAlert = .unsupported(url: candidate.url)
    }
  }
}

private func firstRedditLinkCandidate(in string: String) -> ClipboardRedditLinkCandidate? {
  guard let detector = redditClipboardURLDetector else { return nil }
  let range = NSRange(string.startIndex..<string.endIndex, in: string)
  let matches = detector.matches(in: string, options: [], range: range)

  for match in matches {
    guard let url = match.url else { continue }
    let parsed = parseRedditURL(url.absoluteString)
    let isSupported = parsed.isSupportedRedditAppDestination

    let isRedditOwned = isRedditOwnedURL(url)
    if isSupported || isRedditOwned {
      return ClipboardRedditLinkCandidate(url: url, parsed: parsed, isRedditOwned: isRedditOwned)
    }
  }

  return nil
}

private struct OpenFromWebListenerModifier: ViewModifier {
  @Environment(\.openURL) private var openURL
  @State private var externalImage: ExternalImagePresentation?

  func body(content: Content) -> some View {
    content
      .onOpenURL { url in
        let parsed = parseRedditURL(url.absoluteString)
        if !openParsedRedditURL(parsed) {
          if let safariURL = AppURLRouter.normalizedWebURL(from: url) {
            if isImageUrl(safariURL.absoluteString) {
              externalImage = ExternalImagePresentation(url: safariURL)
            } else {
              openURL(safariURL)
            }
          }
        }
      }
      .sheet(item: $externalImage) { item in
        ImageView(url: item.url)
          .preferredColorScheme(.dark)
      }
  }
}

extension View {
  func openFromWebListener() -> some View {
    modifier(OpenFromWebListenerModifier())
  }

  func clipboardRedditLinkListener() -> some View {
    modifier(ClipboardRedditLinkListenerModifier())
  }
}
