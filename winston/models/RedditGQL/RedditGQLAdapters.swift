//
//  RedditGQLAdapters.swift
//  winston
//
//  Maps RedditPOC's typed GraphQL models into Winston's existing REST-shaped
//  models, so GraphQL content flows through the unchanged UI/models.
//
//  `SubredditPost` is shared across PostsByIds, PostComments, and feed
//  hydration. GraphQL media is adapted into the REST-shaped fields Winston's
//  existing media renderer already understands.
//

import Foundation
import RedditPOC

func redditLoadableAvatarURL(_ urlString: String?) -> String? {
  guard let urlString, !urlString.isEmpty else { return nil }
  guard var components = URLComponents(string: urlString) else { return urlString }
  
  if components.host == "preview.redd.it", components.path.hasPrefix("/snoovatar/avatars/") {
    components.host = "i.redd.it"
    components.query = nil
    components.fragment = nil
    return components.url?.absoluteString ?? urlString
  }
  
  return urlString
}

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
      num_crossposts: p.crossposts.count
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
    crosspost_parent_list = p.crossposts.map { PostData(graphQL: $0) }
    applyGraphQLMedia(from: p)
    AvatarRegistry.shared.register(
      fullname: p.authorInfo?.id,
      url: redditLoadableAvatarURL(p.authorInfo?.iconSmall?.url ?? p.authorInfo?.snoovatarIcon?.url)
    )
  }

  private mutating func applyGraphQLMedia(from p: SubredditPost) {
    if let still = p.media?.still {
      applyPreview(still: still)
      thumbnail = thumbnail ?? still.source?.absoluteURLString
      post_hint = post_hint ?? "image"
    }

    if let video = p.media?.video {
      is_video = true
      post_hint = "hosted:video"
      media = Media(
        type: nil,
        oembed: nil,
        reddit_video: RedditVideo(
          bitrate_kbps: video.bitrateKbps,
          fallback_url: video.fallbackUrl ?? video.downloadUrl ?? p.media?.download?.url,
          has_audio: video.hasAudio,
          height: video.height,
          width: video.width,
          scrubber_media_url: video.scrubberMediaUrl,
          dash_url: video.dashUrl,
          duration: video.duration,
          hls_url: video.hlsUrl ?? video.fallbackUrl ?? video.downloadUrl ?? p.media?.download?.url,
          is_gif: video.isGif,
          transcoding_status: video.transcodingStatus
        )
      )

      if preview == nil, let still = p.media?.still {
        applyPreview(still: still, video: video)
      } else if var existing = preview {
        preview = Preview(
          images: existing.images,
          reddit_video_preview: RedditVideoPreview(
            bitrate_kbps: video.bitrateKbps.map(Double.init),
            fallback_url: video.fallbackUrl ?? video.downloadUrl ?? p.media?.download?.url,
            height: video.height.map(Double.init),
            width: video.width.map(Double.init),
            scrubber_media_url: video.scrubberMediaUrl,
            dash_url: video.dashUrl,
            duration: video.duration.map(Double.init),
            hls_url: video.hlsUrl ?? video.fallbackUrl ?? video.downloadUrl ?? p.media?.download?.url,
            is_gif: video.isGif,
            transcoding_status: video.transcodingStatus
          ),
          enabled: existing.enabled
        )
      }
    }

    guard let gallery = p.gallery, !gallery.items.isEmpty else { return }
    is_gallery = true
    post_hint = "gallery"
    gallery_data = GalleryData(items: gallery.items.enumerated().map { index, item in
      GalleryDataItem(media_id: item.media?.id ?? item.id ?? "gallery_\(index)", id: Double(index))
    })
    media_metadata = Dictionary(uniqueKeysWithValues: gallery.items.enumerated().compactMap { index, item in
      let mediaID = item.media?.id ?? item.id ?? "gallery_\(index)"
      guard let source = item.media?.source else { return nil }
      let mime = item.media?.mimeType ?? PostData.mimeType(forMediaURL: source.absoluteURLString)
      let previewSizes = [item.media?.small, item.media?.medium, item.media?.large].compactMap { PostData.metadataSize(from: $0) }
      let sourceSize = PostData.metadataSize(from: source)
      return (
        mediaID,
        MediaMetadataItem(
          status: "valid",
          e: "Image",
          m: mime,
          p: previewSizes.isEmpty ? nil : previewSizes,
          s: sourceSize,
          id: mediaID
        ) as MediaMetadataItem?
      )
    })
  }

  private mutating func applyPreview(still: StillMedia, video: RedditHostedVideo? = nil) {
    guard let source = PostData.previewImg(still.source) else { return }
    let resolutions = [still.small, still.medium, still.large, still.xlarge, still.xxlarge, still.xxxlarge].compactMap(PostData.previewImg)
    preview = Preview(
      images: [PreviewImgCollection(source: source, resolutions: resolutions.isEmpty ? nil : resolutions, id: nil)],
      reddit_video_preview: video.map {
        RedditVideoPreview(
          bitrate_kbps: $0.bitrateKbps.map(Double.init),
          fallback_url: $0.fallbackUrl ?? $0.downloadUrl,
          height: $0.height.map(Double.init),
          width: $0.width.map(Double.init),
          scrubber_media_url: $0.scrubberMediaUrl,
          dash_url: $0.dashUrl,
          duration: $0.duration.map(Double.init),
          hls_url: $0.hlsUrl ?? $0.fallbackUrl ?? $0.downloadUrl,
          is_gif: $0.isGif,
          transcoding_status: $0.transcodingStatus
        )
      },
      enabled: true
    )
  }

  private static func previewImg(_ source: RedditPOC.MediaSource?) -> PreviewImg? {
    guard let url = source?.absoluteURLString else { return nil }
    return PreviewImg(url: url, width: source?.dimensions?.width, height: source?.dimensions?.height, id: nil)
  }

  private static func metadataSize(from source: RedditPOC.MediaSource?) -> MediaMetadataItemSize? {
    guard let source, let width = source.dimensions?.width, let height = source.dimensions?.height else { return nil }
    return MediaMetadataItemSize(x: width, y: height, u: source.absoluteURLString)
  }

  private static func mimeType(forMediaURL url: String?) -> String {
    guard let ext = url.flatMap({ URL(string: $0)?.pathExtension.lowercased() }), !ext.isEmpty else { return "image/jpeg" }
    switch ext {
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "heic": return "image/heic"
    case "heif": return "image/heif"
    default: return "image/jpeg"
    }
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
  init(graphQL node: RedditPOC.Comment, depth: Int?, parentID: String?, postFullname: String, authorName: String? = nil) {
    let fullID = node.id ?? ""
    let bareID = fullID.hasPrefix("t1_") ? String(fullID.dropFirst(3)) : fullID
    self.init(id: bareID)
    name = fullID
    // Top-level comments report a nil parentId; root them at the post so
    // nestComments treats them as roots.
    parent_id = parentID?.isEmpty == false ? parentID : postFullname
    link_id = postFullname
    self.depth = depth
    body = CommentData.body(from: node)
    body_html = node.content?.html
    author = node.authorInfo?.name ?? authorName ?? (node.isRemoved == true ? "[deleted]" : nil)
    author_fullname = node.authorInfo?.id
    ups = node.score
    score = node.score
    score_hidden = node.isScoreHidden
    likes = node.voteState == .up ? true : (node.voteState == .down ? false : nil)
    saved = node.isSaved
    let createdEpoch = PostData.epoch(fromISO8601: node.createdAt)
    created = createdEpoch
    created_utc = createdEpoch
    collapsed = false
    permalink = node.permalink
    if let post = node.postInfo {
      link_id = post.id
      link_title = post.postTitle
      subreddit = post.subreddit?.name ?? post.subreddit?.prefixedName?.replacingOccurrences(of: "r/", with: "")
      subreddit_name_prefixed = post.subreddit?.prefixedName
    }
    AvatarRegistry.shared.register(
      fullname: node.authorInfo?.id,
      url: redditLoadableAvatarURL(node.authorInfo?.iconSmall?.url ?? node.authorInfo?.snoovatarIcon?.url)
    )
  }

  private static func body(from node: RedditPOC.Comment) -> String? {
    let markdown = markdownBody(from: node.content)
    if markdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
      return markdown
    }
    return node.isRemoved == true ? "[removed]" : markdown
  }

  private static func markdownBody(from content: RedditContent?) -> String? {
    guard let content else { return nil }
    let media = content.richtextMedia ?? []
    var markdown = content.markdown ?? content.preview

    if var markdown, !media.isEmpty {
      for item in media {
        guard let id = item.id, let url = commentMediaURL(from: item) else { continue }
        markdown = markdown.replacingOccurrences(of: "](\(id))", with: "](\(url))")
      }
      return markdown
    }

    if markdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
      return markdown
    }

    let fallback = media.compactMap { item -> String? in
      guard let url = commentMediaURL(from: item) else { return nil }
      let alt = item.mimeType?.contains("gif") == true ? "gif" : "img"
      return "![\(alt)](\(url))"
    }
    if !fallback.isEmpty {
      return fallback.joined(separator: "\n\n")
    }

    return markdown ?? htmlTextFallback(content.html) ?? htmlTextFallback(content.rtJsonText)
  }

  private static func htmlTextFallback(_ html: String?) -> String? {
    guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    var text = html
      .replacingOccurrences(of: "<br>", with: "\n")
      .replacingOccurrences(of: "<br/>", with: "\n")
      .replacingOccurrences(of: "<br />", with: "\n")
      .replacingOccurrences(of: "</p>", with: "\n\n")
      .replacingOccurrences(of: "</div>", with: "\n")

    while let start = text.firstIndex(of: "<"), let end = text[start...].firstIndex(of: ">") {
      text.removeSubrange(start...end)
    }

    text = text.escape.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  private static func commentMediaURL(from item: RedditGalleryMedia) -> String? {
    item.source?.absoluteURLString ?? item.large?.absoluteURLString ?? item.medium?.absoluteURLString ?? item.small?.absoluteURLString
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
    if let avatar = redditLoadableAvatarURL(a.avatarURL) { dict["snoovatar_img"] = avatar; dict["icon_img"] = avatar }
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

extension UserData {
  init?(graphQL profile: RedditorProfileDetails) {
    guard let username = profile.name, !username.isEmpty else { return nil }
    let bareID: String = {
      guard let id = profile.id else { return username }
      return id.hasPrefix("t2_") ? String(id.dropFirst(3)) : id
    }()

    var dict: [String: Any] = ["id": bareID, "name": username]
    if let k = profile.karma?.total { dict["total_karma"] = k }
    if let k = profile.karma?.fromComments { dict["comment_karma"] = k }
    if let k = profile.karma?.fromPosts { dict["link_karma"] = k }
    if let k = profile.karma?.awardee { dict["awardee_karma"] = k }
    if let k = profile.karma?.awarder { dict["awarder_karma"] = k }
    if let avatar = redditLoadableAvatarURL(profile.snoovatarIcon?.url ?? profile.icon?.url) {
      dict["snoovatar_img"] = avatar
      dict["icon_img"] = avatar
    }
    if let gold = profile.isGilded { dict["is_gold"] = gold }

    let created = PostData.epoch(fromISO8601: profile.profileInfo?.createdAt)
    if created > 0 {
      dict["created_utc"] = created
      dict["created"] = created
    }

    if let info = profile.profileInfo {
      var subreddit: [String: Any] = [
        "display_name": username,
        "display_name_prefixed": "u/\(username)",
        "name": info.id ?? "",
        "title": info.title ?? "",
        "public_description": info.publicDescriptionText ?? "",
        "subscribers": info.subscribersCount ?? 0,
        "over_18": info.isNsfw ?? false,
        "user_is_subscriber": info.isSubscribed ?? false,
        "url": "/user/\(username)/",
      ]
      if let banner = info.styles?.profileBanner?.url { subreddit["banner_img"] = banner }
      if let icon = redditLoadableAvatarURL(profile.icon?.url ?? profile.snoovatarIcon?.url) { subreddit["icon_img"] = icon }
      dict["subreddit"] = subreddit
    }

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
    user_has_favorited = s.isFavorite
    url = s.url ?? s.path ?? "/r/\(s.name ?? bareID)/"
  }
}

extension SubredditData {
  init?(graphQLTypeaheadSuggestion object: [String: JSONValue]) {
    guard object["__typename"]?.stringValue == "TypeaheadSuggestion" else { return nil }

    let behavior = object["behaviors"]?.objectValue?["default"]?.objectValue
    let presentation = object["presentation"]?.objectValue
    guard behavior?["__typename"]?.stringValue == "SearchCommunityNavigationBehavior" else { return nil }

    let rawName = behavior?.string(for: ["name"])
      ?? presentation?.string(for: ["name"])?.replacingOccurrences(of: "r/", with: "")
    guard let resolvedName = rawName, !resolvedName.isEmpty else { return nil }

    let fullID = behavior?.string(for: ["id"]) ?? object.string(for: ["id"])
    let bareID = fullID.flatMap { $0.hasPrefix("t5_") ? String($0.dropFirst(3)) : $0 } ?? resolvedName

    self.init(id: bareID)
    self.name = fullID ?? (bareID.hasPrefix("t5_") ? bareID : "t5_\(bareID)")
    self.display_name = resolvedName
    self.display_name_prefixed = presentation?.string(for: ["name"]) ?? "r/\(resolvedName)"
    self.title = resolvedName
    self.public_description = presentation?.string(for: ["description"]) ?? ""
    let iconURL = presentation?.string(for: ["icon"])
    self.community_icon = iconURL
    self.icon_img = iconURL
    self.over18 = behavior?
      .object(at: ["telemetry", "trackingContext", "subreddit"])?
      .bool(for: ["isNsfw"])
    self.quarantine = behavior?
      .object(at: ["telemetry", "trackingContext", "subreddit"])?
      .bool(for: ["isQuarantined"])
    self.url = behavior?.string(for: ["url"]) ?? "/r/\(resolvedName)/"
  }

  init?(graphQLSearchObject object: [String: JSONValue]) {
    let typeName = object["__typename"]?.stringValue?.lowercased() ?? ""
    let name = object.string(for: ["name", "displayName", "display_name", "subredditName"])
      ?? object.string(for: ["prefixedName", "displayNamePrefixed", "display_name_prefixed"])?.replacingOccurrences(of: "r/", with: "")
    let fullID = object.string(for: ["id", "subredditId", "subredditID"])
    guard
      typeName.contains("subreddit") || object["subreddit"] != nil || object["subredditInfo"] != nil || object["subscribersCount"] != nil || object["prefixedName"] != nil,
      let resolvedName = name,
      !resolvedName.isEmpty
    else { return nil }

    let bareID = fullID.flatMap { $0.hasPrefix("t5_") ? String($0.dropFirst(3)) : $0 } ?? resolvedName
    self.init(id: bareID)
    self.name = fullID ?? (bareID.hasPrefix("t5_") ? bareID : "t5_\(bareID)")
    self.display_name = resolvedName
    self.display_name_prefixed = object.string(for: ["prefixedName", "displayNamePrefixed", "display_name_prefixed"]) ?? "r/\(resolvedName)"
    self.title = object.string(for: ["title", "displayText"]) ?? resolvedName
    self.public_description = object.string(for: ["publicDescription", "public_description", "description"]) ?? ""
    self.subscribers = object.int(for: ["subscribersCount", "subscribers", "membersCount"])
    let iconURL = object.mediaURL(for: ["icon", "iconSmall", "communityIcon", "iconURL", "iconUrl", "iconPath"])
    self.community_icon = iconURL
    self.icon_img = iconURL
    self.primary_color = object.string(for: ["primaryColor", "keyColor"])
    self.key_color = self.primary_color
    self.over18 = object.bool(for: ["isNsfw", "over18"])
    self.user_is_subscriber = object.bool(for: ["isSubscribed", "userIsSubscriber"])
    self.url = object.string(for: ["url", "path"]) ?? "/r/\(resolvedName)/"
  }
}

extension UserData {
  init?(graphQLSearchObject object: [String: JSONValue]) {
    let typeName = object["__typename"]?.stringValue?.lowercased() ?? ""
    let username = object.string(for: ["name", "username", "displayName"])
    guard
      typeName.contains("redditor") || typeName.contains("user") || object["redditor"] != nil || object["profile"] != nil,
      let username,
      !username.isEmpty,
      !username.hasPrefix("r/"),
      username != "[deleted]"
    else { return nil }

    let fullID = object.string(for: ["id", "accountId", "userId"])
    let bareID = fullID.flatMap { $0.hasPrefix("t2_") ? String($0.dropFirst(3)) : $0 } ?? username
    var dict: [String: Any] = ["id": bareID, "name": username]
    if let avatar = object.mediaURL(for: ["avatarURL", "avatarUrl", "icon", "iconSmall", "snoovatarIcon"]) {
      dict["icon_img"] = avatar
      dict["snoovatar_img"] = avatar
    }
    if let karma = object.int(for: ["totalKarma", "karma"]) { dict["total_karma"] = karma }
    if let karma = object.int(for: ["commentKarma"]) { dict["comment_karma"] = karma }
    if let karma = object.int(for: ["postKarma", "linkKarma"]) { dict["link_karma"] = karma }
    if let gold = object.bool(for: ["isGold", "isPremium"]) { dict["is_gold"] = gold }

    guard
      let data = try? JSONSerialization.data(withJSONObject: dict),
      let decoded = try? JSONDecoder().decode(UserData.self, from: data)
    else { return nil }
    self = decoded
  }
}

private extension RedditPOC.MediaSource {
  var absoluteURLString: String? {
    if let url, !url.isEmpty { return url }
    guard let path, !path.isEmpty else { return nil }
    if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
    if path.hasPrefix("//") { return "https:\(path)" }
    if path.hasPrefix("/") { return "https://www.reddit.com\(path)" }
    return path
  }
}

extension JSONValue {
  var searchPosts: [SubredditPost] {
    searchPostObjects.compactMap { JSONValue.object($0).decodeObject(SubredditPost.self) }
  }

  var searchComments: [RedditPOC.Comment] {
    searchCommentObjects.compactMap { JSONValue.object($0).decodeObject(RedditPOC.Comment.self) }
  }

  var searchPostObjects: [[String: JSONValue]] {
    var result: [[String: JSONValue]] = []
    collectObjects(named: "post", typeName: "SubredditPost", into: &result)
    return result
  }

  var searchSubredditObjects: [[String: JSONValue]] {
    var result: [[String: JSONValue]] = []
    collectObjects(named: "subreddit", typeName: "Subreddit", into: &result)
    collectObjects(named: "community", typeName: "Subreddit", into: &result)
    return result
  }

  var searchTypeaheadSubredditObjects: [[String: JSONValue]] {
    var result: [[String: JSONValue]] = []
    collectTypeaheadSubredditSuggestions(into: &result)
    return result
  }

  var searchCommentObjects: [[String: JSONValue]] {
    var result: [[String: JSONValue]] = []
    collectSearchCommentObjects(into: &result)
    return result
  }

  var searchUserObjects: [[String: JSONValue]] {
    var result: [[String: JSONValue]] = []
    collectObjects(named: "authorInfo", typeName: nil, into: &result)
    collectObjects(named: "profile", typeName: nil, into: &result)
    collectObjects(named: "redditor", typeName: nil, into: &result)
    return result
  }

  var searchObjects: [[String: JSONValue]] {
    var result: [[String: JSONValue]] = []
    collectSearchObjects(into: &result)
    return result
  }

  func collectObjects(named key: String, typeName: String?, into result: inout [[String: JSONValue]]) {
    switch self {
    case .object(let object):
      if let nested = object[key]?.objectValue {
        if typeName == nil || nested["__typename"]?.stringValue == typeName {
          result.append(nested)
        }
      }
      if typeName != nil, object["__typename"]?.stringValue == typeName {
        result.append(object)
      }
      for value in object.values {
        value.collectObjects(named: key, typeName: typeName, into: &result)
      }
    case .array(let array):
      for value in array {
        value.collectObjects(named: key, typeName: typeName, into: &result)
      }
    case .null, .bool, .number, .string:
      break
    }
  }

  func collectSearchObjects(into result: inout [[String: JSONValue]]) {
    switch self {
    case .object(let object):
      if object.isSearchCandidate {
        result.append(object)
      }
      for value in object.values {
        value.collectSearchObjects(into: &result)
      }
    case .array(let array):
      for value in array {
        value.collectSearchObjects(into: &result)
      }
    case .null, .bool, .number, .string:
      break
    }
  }

  func collectTypeaheadSubredditSuggestions(into result: inout [[String: JSONValue]]) {
    switch self {
    case .object(let object):
      if
        object["__typename"]?.stringValue == "TypeaheadSuggestion",
        object["behaviors"]?.objectValue?["default"]?.objectValue?["__typename"]?.stringValue == "SearchCommunityNavigationBehavior"
      {
        result.append(object)
        return
      }
      for value in object.values {
        value.collectTypeaheadSubredditSuggestions(into: &result)
      }
    case .array(let array):
      for value in array {
        value.collectTypeaheadSubredditSuggestions(into: &result)
      }
    case .null, .bool, .number, .string:
      break
    }
  }

  func collectSearchCommentObjects(into result: inout [[String: JSONValue]]) {
    switch self {
    case .object(let object):
      if
        object["__typename"]?.stringValue == "SearchComment",
        let comment = object["comment"]?.objectValue,
        comment["content"] != nil || comment["authorInfo"] != nil || comment["postInfo"] != nil
      {
        result.append(comment)
        return
      }
      for value in object.values {
        value.collectSearchCommentObjects(into: &result)
      }
    case .array(let array):
      for value in array {
        value.collectSearchCommentObjects(into: &result)
      }
    case .null, .bool, .number, .string:
      break
    }
  }
}

private extension JSONValue {
  func decodeObject<T: Decodable>(_ type: T.Type) -> T? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }
}

private extension Dictionary where Key == String, Value == JSONValue {
  var isSearchCandidate: Bool {
    let typeName = self["__typename"]?.stringValue?.lowercased() ?? ""
    return typeName.contains("subreddit")
      || typeName.contains("redditor")
      || typeName.contains("user")
      || self["prefixedName"] != nil
      || self["subscribersCount"] != nil
      || self["snoovatarIcon"] != nil
      || self["iconSmall"] != nil
  }

  func string(for keys: [String]) -> String? {
    for key in keys {
      if let value = self[key]?.stringValue, !value.isEmpty { return value }
      if let object = self[key]?.objectValue, let value = object.string(for: keys) { return value }
    }
    return nil
  }

  func int(for keys: [String]) -> Int? {
    for key in keys {
      if let value = self[key]?.intValue { return value }
      if let string = self[key]?.stringValue, let value = Int(string) { return value }
      if let object = self[key]?.objectValue, let value = object.int(for: keys) { return value }
    }
    return nil
  }

  func bool(for keys: [String]) -> Bool? {
    for key in keys {
      if let value = self[key]?.boolValue { return value }
      if let string = self[key]?.stringValue {
        switch string.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: break
        }
      }
      if let object = self[key]?.objectValue, let value = object.bool(for: keys) { return value }
    }
    return nil
  }

  func mediaURL(for keys: [String]) -> String? {
    for key in keys {
      guard let value = self[key] else { continue }
      if let string = value.stringValue, !string.isEmpty { return string }
      if let object = value.objectValue {
        if let url = object.string(for: ["url", "path"]) { return url }
        if let nested = object.mediaURL(for: keys) { return nested }
      }
    }
    return nil
  }

  func object(at path: [String]) -> [String: JSONValue]? {
    var current: [String: JSONValue]? = self
    for key in path {
      current = current?[key]?.objectValue
      if current == nil { return nil }
    }
    return current
  }
}

extension Array {
  func deduped<ID: Hashable>(by id: (Element) -> ID) -> [Element] {
    var seen = Set<ID>()
    return filter { seen.insert(id($0)).inserted }
  }
}
