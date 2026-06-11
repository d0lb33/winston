//
//  RedditGQLAdapters.swift
//  winston
//
//  Maps RedditPOC's typed GraphQL models into Winston's existing REST-shaped
//  models, so GraphQL content flows through the unchanged UI/models.
//
//  `SubredditPost` is shared across PostsByIds, PostComments, and feed
//  hydration. Media/preview/gallery extraction is still a later pass — text/
//  link posts and all metadata map cleanly today.
//

import Foundation
import RedditPOC

extension PostData {
  /// Build a `PostData` from a typed RedditPOC `SubredditPost`.
  init(graphQL p: SubredditPost) {
    let fullID = p.id // "t3_…"
    let bareID = fullID.hasPrefix("t3_") ? String(fullID.dropFirst(3)) : fullID
    let subName = p.subreddit?.name ?? ""
    let isSelf = p.isSelfPost ?? false
    let permalink = p.permalink ?? ""
    let resolvedURL = p.url ?? (permalink.isEmpty ? "" : "https://www.reddit.com\(permalink)")
    let createdEpoch = PostData.epoch(fromISO8601: p.createdAt)
    let likesVal: Bool? = p.voteState == .up ? true : (p.voteState == .down ? false : nil)
    let score = p.score ?? 0

    self.init(
      subreddit: subName,
      selftext: p.content?.markdown ?? "",
      author_fullname: p.authorInfo?.id,
      saved: p.isSaved ?? false,
      gilded: 0,
      clicked: false,
      title: p.postTitle ?? "",
      subreddit_name_prefixed: p.subreddit?.prefixedName ?? (subName.isEmpty ? "" : "r/\(subName)"),
      hidden: p.isHidden ?? false,
      ups: score,
      downs: 0,
      hide_score: false,
      name: fullID,
      quarantine: p.subreddit?.isQuarantined ?? false,
      upvote_ratio: p.upvoteRatio ?? 1,
      subreddit_type: (p.subreddit?.type ?? "public").lowercased(),
      total_awards_received: 0,
      is_self: isSelf,
      created: createdEpoch,
      domain: p.domain ?? (isSelf ? "self.\(subName)" : (URL(string: resolvedURL)?.host ?? "")),
      allow_live_comments: false,
      id: bareID,
      is_robot_indexable: true,
      author: p.authorInfo?.name ?? "[deleted]",
      num_comments: p.commentCount ?? 0,
      send_replies: false,
      contest_mode: p.isContestMode ?? false,
      permalink: permalink,
      url: resolvedURL,
      subreddit_subscribers: p.subreddit?.subscribersCount ?? 0,
      num_crossposts: 0
    )

    // Optional fields, set after memberwise init.
    created_utc = createdEpoch
    selftext_html = p.content?.html
    likes = likesVal
    over_18 = p.isNsfw
    stickied = p.isStickied
    locked = p.isLocked
    archived = p.isArchived
    is_crosspostable = p.isCrosspostable
    can_gild = p.isGildable
    link_flair_text = p.flair?.text
    link_flair_background_color = p.flair?.template?.backgroundColor
    thumbnail = p.thumbnail?.url
    subreddit_id = p.subreddit?.id
    is_gallery = p.gallery != nil
  }

  /// GraphQL timestamps are ISO8601 strings; Winston stores epoch seconds.
  /// Kept for comment mapping and for when SubredditPost.createdAt lands.
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
}

extension CommentData {
  /// Build a flat `CommentData` node from a typed RedditPOC `Comment` plus its
  /// position in `commentForest.trees`. `nestComments(_, parentID:)` assembles
  /// these into the reply tree via `name`/`parent_id`.
  ///
  /// TODO(typed): the library `Comment` has no `createdAt`, so `created` is 0.
  init(graphQL node: RedditPOC.Comment, depth: Int?, parentID: String?, postFullname: String) {
    let fullID = node.id ?? ""
    let bareID = fullID.hasPrefix("t1_") ? String(fullID.dropFirst(3)) : fullID
    self.init(id: bareID)
    name = fullID
    // Top-level comments report a nil parentId; root them at the post so
    // nestComments treats them as roots.
    parent_id = parentID ?? postFullname
    link_id = postFullname
    self.depth = depth
    body = node.content?.markdown
    body_html = node.content?.html
    author = node.authorInfo?.name
    author_fullname = node.authorInfo?.id
    ups = node.score
    score = node.score
    likes = node.voteState == .up ? true : (node.voteState == .down ? false : nil)
    saved = node.isSaved
    let createdEpoch = PostData.epoch(fromISO8601: node.createdAt)
    created = createdEpoch
    created_utc = createdEpoch
    collapsed = false
    permalink = node.permalink
  }
}

extension UserData {
  /// Build the signed-in user's `UserData` from a typed `GetAccountResponse`.
  /// Uses a JSON round-trip through UserData's own Codable decoder (the same
  /// one used for REST /api/v1/me) so we don't depend on its memberwise init.
  init?(graphQL a: GetAccountResponse) {
    guard let username = a.name, !username.isEmpty else { return nil }
    let bareID: String = {
      guard let id = a.id else { return username }
      return id.hasPrefix("t2_") ? String(id.dropFirst(3)) : id
    }()

    var dict: [String: Any] = ["id": bareID, "name": username]
    if let k = a.totalKarma { dict["total_karma"] = k }
    if let k = a.commentKarma { dict["comment_karma"] = k }
    if let k = a.postKarma { dict["link_karma"] = k }
    if let k = a.awardeeKarma { dict["awardee_karma"] = k }
    if let k = a.awarderKarma { dict["awarder_karma"] = k }
    if let avatar = a.avatarURL { dict["snoovatar_img"] = avatar; dict["icon_img"] = avatar }
    if let gold = a.isGold ?? a.isPremium { dict["is_gold"] = gold }
    let created = PostData.epoch(fromISO8601: a.createdAt)
    if created > 0 { dict["created_utc"] = created; dict["created"] = created }

    guard
      let data = try? JSONSerialization.data(withJSONObject: dict),
      let decoded = try? JSONDecoder().decode(UserData.self, from: data)
    else { return nil }
    self = decoded
  }
}

extension SubredditData {
  /// Build a `SubredditData` from a typed `SubredditSummary` (subscriptions list
  /// + feed hydration). Uses SubredditData.init(id:) then sets the var fields.
  init(graphQL s: SubredditSummary) {
    let fullID = s.id ?? ""
    let bareID = fullID.hasPrefix("t5_") ? String(fullID.dropFirst(3)) : fullID
    self.init(id: bareID)
    name = fullID.isEmpty ? "t5_\(bareID)" : fullID
    display_name = s.name
    display_name_prefixed = s.prefixedName ?? s.name.map { "r/\($0)" }
    title = s.title
    public_description = s.publicDescription ?? ""
    subscribers = s.subscribersCount
    let iconURL = s.icon?.url ?? s.iconURL
    community_icon = iconURL
    icon_img = iconURL
    primary_color = s.primaryColor
    key_color = s.primaryColor
    over18 = s.isNsfw
    user_is_subscriber = s.isSubscribed
    url = s.url ?? s.path ?? "/r/\(s.name ?? bareID)/"
  }
}
