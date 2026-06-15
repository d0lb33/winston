//
//  openFromWebListener.swift
//  winston
//
//  Created by Igor Marcossi on 10/12/23.
//

import SwiftUI
import Defaults

@discardableResult
func openParsedRedditURL(_ parsed: RedditURLType) -> Bool {
  switch parsed {
  case .post(let postID, let subID):
    openRedditDestination(.reddit(.post(Post(id: postID, subID: subID))))
  case .postID(let postID):
    openRedditDestination(.reddit(.post(Post(id: postID))))
  case .comment(let commentID, let postID, let subID):
    openRedditDestination(.reddit(.postHighlighted(Post(id: postID, subID: subID), commentID)))
  case .commentID(let commentID, let postID):
    openRedditDestination(.reddit(.postHighlighted(Post(id: postID), commentID)))
  case .subreddit(let name):
    openRedditDestination(.reddit(.subFeed(Subreddit(id: name))))
  case .user(let username):
    openRedditDestination(.reddit(.user(User(id: username))))
  default:
    return false
  }
  return true
}

private func openRedditDestination(_ destination: Router.NavDest) {
  if Nav.shared.activeTab != .posts {
    Nav.shared.activeTab = .posts
  }
  Nav.shared[.posts].navigateContextually(to: destination)
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

    if isSupportedParsedRedditURL(candidate.parsed) {
      pendingAlert = .supported(url: candidate.url, parsed: candidate.parsed)
    } else if candidate.isRedditOwned {
      pendingAlert = .unsupported(url: candidate.url)
    }
  }

  private func isSupportedParsedRedditURL(_ parsed: RedditURLType) -> Bool {
    switch parsed {
    case .post, .postID, .comment, .commentID, .subreddit, .user:
      return true
    default:
      return false
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
    let isSupported: Bool
    switch parsed {
    case .post, .postID, .comment, .commentID, .subreddit, .user:
      isSupported = true
    default:
      isSupported = false
    }

    let isRedditOwned = isRedditOwnedURL(url)
    if isSupported || isRedditOwned {
      return ClipboardRedditLinkCandidate(url: url, parsed: parsed, isRedditOwned: isRedditOwned)
    }
  }

  return nil
}

private func isRedditOwnedURL(_ url: URL) -> Bool {
  guard let host = url.host?.lowercased() else { return false }
  return host == "reddit.com"
    || host.hasSuffix(".reddit.com")
    || host == "redd.it"
    || host.hasSuffix(".redd.it")
    || host == "reddit.app.link"
    || host.hasSuffix(".reddit.app.link")
}

private struct OpenFromWebListenerModifier: ViewModifier {
  @Environment(\.openURL) private var openURL
  @State private var externalImage: ExternalImagePresentation?

  func body(content: Content) -> some View {
    content
      .onOpenURL { url in
        let parsed = parseRedditURL(url.absoluteString)
        if !openParsedRedditURL(parsed) {
          let urlStringWithoutScheme = url.absoluteString.replacingOccurrences(of: "winstonapp://", with: "")

          if let safariURL = URL(string: "https://" + urlStringWithoutScheme) {
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
