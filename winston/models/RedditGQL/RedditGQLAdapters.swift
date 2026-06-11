//
//  RedditGQLAdapters.swift
//  winston
//
//  Maps Reddit GraphQL response objects into Winston's existing REST-shaped
//  models, so GraphQL-hydrated content can flow through the unchanged UI.
//
//  v1 covers the scalar/metadata fields of a `postsInfoByIds` entry
//  (PostsByIds / HomeFeedPostsByIds). Media/preview/gallery extraction is left
//  for a later pass — text posts and all metadata map cleanly today.
//

import Foundation

extension PostData {
  /// Build a `PostData` from one GraphQL `postsInfoByIds[]` object.
  init?(graphQL p: [String: Any]) {
    guard let fullID = p["id"] as? String else { return nil } // e.g. "t3_1q8ju15"
    let bareID = fullID.hasPrefix("t3_") ? String(fullID.dropFirst(3)) : fullID

    let sub = p["subreddit"] as? [String: Any]
    let author = p["authorInfo"] as? [String: Any]
    let content = p["content"] as? [String: Any]
    let flair = p["flair"] as? [String: Any]

    let createdEpoch = PostData.epoch(fromISO8601: p["createdAt"] as? String)
    let vote = p["voteState"] as? String
    let likesVal: Bool? = vote == "UP" ? true : (vote == "DOWN" ? false : nil)
    let scoreVal = (p["score"] as? Int) ?? 0

    self.init(
      subreddit: (sub?["name"] as? String) ?? "",
      selftext: (content?["markdown"] as? String) ?? "",
      author_fullname: author?["id"] as? String,
      saved: (p["isSaved"] as? Bool) ?? false,
      gilded: 0,
      clicked: false,
      title: (p["postTitle"] as? String) ?? "",
      subreddit_name_prefixed: (sub?["prefixedName"] as? String) ?? "",
      hidden: (p["isHidden"] as? Bool) ?? false,
      ups: scoreVal,
      downs: 0,
      hide_score: (p["isScoreHidden"] as? Bool) ?? false,
      name: fullID,
      quarantine: (sub?["isQuarantined"] as? Bool) ?? false,
      upvote_ratio: (p["upvoteRatio"] as? Double) ?? 1,
      subreddit_type: ((sub?["type"] as? String) ?? "public").lowercased(),
      total_awards_received: (p["awardings"] as? [Any])?.count ?? 0,
      is_self: (p["isSelfPost"] as? Bool) ?? false,
      created: createdEpoch,
      domain: (p["domain"] as? String) ?? "",
      allow_live_comments: false,
      id: bareID,
      is_robot_indexable: true,
      author: (author?["name"] as? String) ?? "[deleted]",
      num_comments: (p["commentCount"] as? Int) ?? 0,
      send_replies: false,
      contest_mode: (p["isContestMode"] as? Bool) ?? false,
      permalink: (p["permalink"] as? String) ?? "",
      url: (p["url"] as? String) ?? "",
      subreddit_subscribers: (sub?["subscribersCount"] as? Int) ?? 0,
      num_crossposts: (p["crosspostCount"] as? Int) ?? 0
    )

    // Optional fields, set after memberwise init.
    created_utc = createdEpoch
    selftext_html = content?["html"] as? String
    likes = likesVal
    over_18 = p["isNsfw"] as? Bool
    spoiler = p["isSpoiler"] as? Bool
    stickied = p["isStickied"] as? Bool
    locked = p["isLocked"] as? Bool
    archived = p["isArchived"] as? Bool
    is_crosspostable = p["isCrosspostable"] as? Bool
    can_gild = p["isGildable"] as? Bool
    link_flair_text = flair?["text"] as? String
    link_flair_background_color = (flair?["template"] as? [String: Any])?["backgroundColor"] as? String
    post_hint = p["postHint"] as? String
    thumbnail = PostData.urlString(p["thumbnail"])
    subreddit_id = sub?["id"] as? String
    distinguished = p["distinguishedAs"] as? String
    removed_by_category = p["removedByCategory"] as? String
    is_gallery = (p["gallery"].map { !($0 is NSNull) }) ?? false
  }

  /// GraphQL timestamps are ISO8601 strings; Winston stores epoch seconds.
  static func epoch(fromISO8601 s: String?) -> Double {
    guard let s, !s.isEmpty else { return 0 }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: s) { return d.timeIntervalSince1970 }
    iso.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: s) { return d.timeIntervalSince1970 }
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone(identifier: "UTC")
    df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ"
    return df.date(from: s)?.timeIntervalSince1970 ?? 0
  }

  /// A thumbnail/media field may be a bare URL string or a `{ url, dimensions }` object.
  static func urlString(_ value: Any?) -> String? {
    if let s = value as? String { return s.isEmpty ? nil : s }
    if let dict = value as? [String: Any] { return dict["url"] as? String }
    return nil
  }
}
