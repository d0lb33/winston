//
//  NavDest.swift
//  winston
//
//  The app's navigation vocabulary, lifted to a top-level type so it survives the
//  deletion of the legacy `Router`. Every navigation surface (PostsNav / ColumnNav /
//  StackNav / SettingsNav) and the destination host route on these values.
//

import Foundation

enum NavDest: Hashable, Codable, Identifiable {
  @MainActor
  var id: String {
    switch self {
    case .reddit(let reddit): return reddit.id
    case .setting(let setting): return setting.id
    }
  }
  case reddit(Reddit)
  case setting(Setting)

  enum Reddit: Hashable, Codable, Identifiable {
    @MainActor
    var id: String {
      switch self {
      case .post(let post): return post.id
      case .postHighlighted(let post, _): return post.id
      case .subFeed(let subreddit): return subreddit.id
      case .subInfo(let subreddit): return subreddit.id
      case .multiFeed(let multi): return multi.id
      case .multiInfo(let multi): return multi.id
      case .user(let user): return user.id
      }
    }
    case post(Post)
    case postHighlighted(Post, String)
    case subFeed(Subreddit)
    case subInfo(Subreddit)
    case multiFeed(Multi)
    case multiInfo(Multi)
    case user(User)
  }

  enum Setting: String, Hashable, Codable, Identifiable {
    var id: String { self.rawValue }
    case behavior, appearance, accounts, diagnostics, about, commentSwipe, postSwipe, accessibility, faq, general, filteredSubreddits, appIcon, designLab
  }
}

extension NavDest {
  @MainActor
  var diagnosticsName: String {
    switch self {
    case .setting(let setting):
      return "setting.\(setting.rawValue)"
    case .reddit(let reddit):
      return reddit.diagnosticsName
    }
  }
}

extension NavDest.Reddit {
  @MainActor
  var diagnosticsName: String {
    switch self {
    case .post(let post): return "reddit.post.\(post.id)"
    case .postHighlighted(let post, let highlightID): return "reddit.postHighlighted.\(post.id).\(highlightID)"
    case .subFeed(let subreddit): return "reddit.subFeed.\(subreddit.id)"
    case .subInfo(let subreddit): return "reddit.subInfo.\(subreddit.id)"
    case .multiFeed(let multi): return "reddit.multiFeed.\(multi.id)"
    case .multiInfo(let multi): return "reddit.multiInfo.\(multi.id)"
    case .user(let user): return "reddit.user.\(user.id)"
    }
  }
}
