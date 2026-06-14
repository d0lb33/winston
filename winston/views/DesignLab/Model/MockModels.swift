//
//  MockModels.swift
//  winston
//
//  Design Lab — lightweight, self-contained mock models.
//
//  These intentionally do NOT reuse the production PostData / CommentData / Subreddit
//  models (which carry heavy initializers, ObservableObject companions and Nuke media
//  extraction). The Design Lab is a decoupled showcase: plain value types, no network,
//  no Combine, no production theming.
//

import SwiftUI

// MARK: - Tint

/// A small, self-contained palette. Deliberately independent of `WinstonTheme` so the
/// Design Lab stays fully decoupled from production theming.
enum MockTint: String, CaseIterable, Hashable {
  case indigo, teal, pink, amber, green, blue, purple, orange, mint, red

  var color: Color {
    switch self {
    case .indigo: Color.indigo
    case .teal:   Color.teal
    case .pink:   Color.pink
    case .amber:  Color(red: 1.0, green: 0.72, blue: 0.22)
    case .green:  Color.green
    case .blue:   Color.blue
    case .purple: Color.purple
    case .orange: Color.orange
    case .mint:   Color.mint
    case .red:    Color.red
    }
  }
}

// MARK: - Post kind

enum MockPostKind: String, Hashable {
  case text, image, link, gallery, video
}

// MARK: - Flair

struct MockFlair: Hashable {
  let text: String
  let tint: MockTint
}

// MARK: - Media seed

/// Drives deterministic placeholder media. `seed` is stable per post so the same
/// gradient / remote image appears on every launch.
struct MockMediaSeed: Hashable {
  let seed: String
  /// width / height. 1.0 square, >1 landscape, <1 portrait.
  let aspect: CGFloat
  /// > 1 => a gallery.
  let count: Int

  init(seed: String, aspect: CGFloat = 1.5, count: Int = 1) {
    self.seed = seed
    self.aspect = aspect
    self.count = count
  }
}

// MARK: - User

struct MockUser: Identifiable, Hashable {
  let id: String          // "u/winston"
  let username: String    // "winston"
  let avatarSeed: String
  let karma: Int
}

// MARK: - Subreddit

struct MockSubreddit: Identifiable, Hashable {
  let id: String          // "r/swift"
  let name: String        // "swift"
  let displayName: String // "r/swift"
  let about: String
  let members: Int
  let iconSeed: String
  let accent: MockTint
}

// MARK: - Post

struct MockPost: Identifiable, Hashable {
  let id: String
  let title: String
  let body: String?
  let author: MockUser
  let subreddit: MockSubreddit
  let kind: MockPostKind
  let media: MockMediaSeed?
  let linkDomain: String?
  let score: Int
  let upvoteRatio: Double
  let commentCount: Int
  /// Seconds in the past (positive number meaning "X seconds ago").
  let createdOffset: TimeInterval
  let flair: MockFlair?
  let isNSFW: Bool
  let isSpoiler: Bool
  let isPinned: Bool
}

// MARK: - Comment

struct MockComment: Identifiable, Hashable {
  let id: String
  let author: MockUser
  let body: String
  let score: Int
  let createdOffset: TimeInterval
  let isOP: Bool
  let replies: [MockComment]
}

extension MockComment {
  /// Flattens the recursive tree into stable (comment, depth) rows for list rendering.
  /// Mirrors the production `CommentTreeModel` flatten-and-diff approach, kept trivially
  /// simple because the mock dataset is small and immutable.
  static func flatten(_ comments: [MockComment], depth: Int = 0) -> [(comment: MockComment, depth: Int)] {
    var rows: [(MockComment, Int)] = []
    for comment in comments {
      rows.append((comment, depth))
      rows.append(contentsOf: flatten(comment.replies, depth: depth + 1))
    }
    return rows
  }

  /// Number of descendants — used for the "+N replies" badge when a thread is collapsed.
  var descendantCount: Int { replies.reduce(0) { $0 + 1 + $1.descendantCount } }

  /// Visible (comment, depth, isCollapsed) rows honouring a set of collapsed comment IDs.
  /// Children of a collapsed node are omitted — real threaded collapse, not just hiding a body.
  static func visibleRows(_ comments: [MockComment], collapsed: Set<String>, depth: Int = 0)
    -> [(comment: MockComment, depth: Int, isCollapsed: Bool)] {
    var rows: [(comment: MockComment, depth: Int, isCollapsed: Bool)] = []
    for c in comments {
      let isCollapsed = collapsed.contains(c.id)
      rows.append((c, depth, isCollapsed))
      if !isCollapsed {
        rows.append(contentsOf: visibleRows(c.replies, collapsed: collapsed, depth: depth + 1))
      }
    }
    return rows
  }
}
