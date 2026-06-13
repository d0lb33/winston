//
//  RedditWire+Actions.swift
//  winston
//
//  GraphQL ports of the remaining REST surface: replies, comment edit/delete,
//  hide, text-post submission, multireddits, the notification inbox, the
//  identity/subscription caches, and the author-avatar pipeline.
//

import Foundation
import RedditPOC
import Defaults
import SwiftUI
import CoreData
import Nuke
import NukeUI

// MARK: - Author avatars

/// GraphQL responses carry each author's icon inline (RedditAuthorInfo), so the
/// app no longer needs a REST batch user lookup. The adapters register icons
/// here while decoding; `RedditWire.update*WithAvatar` turns them into
/// prefetched ImageRequests on the entities' winstonData.
final class AvatarRegistry: @unchecked Sendable {
  static let shared = AvatarRegistry()
  private let lock = NSLock()
  private var urlByAuthorFullname: [String: String] = [:]

  func register(fullname: String?, url: String?) {
    guard let fullname, !fullname.isEmpty, let url, !url.isEmpty else { return }
    lock.lock(); urlByAuthorFullname[fullname] = url; lock.unlock()
  }

  func url(for fullname: String) -> String? {
    lock.lock(); defer { lock.unlock() }
    return urlByAuthorFullname[fullname]
  }
}

func getNamesFromComments(_ comments: [Comment]) -> [String] {
  var namesArr: [String] = []
  comments.forEach { comment in
    if let fullname = comment.data?.author_fullname {
      namesArr.append(fullname)
    }
    namesArr += getNamesFromComments(comment.childrenWinston.data)
  }
  return namesArr
}

extension RedditWire {
  static func avatarImageRequest(url urlStr: String, avatarSize: Double) -> ImageRequest? {
    guard let url = URL(string: String(urlStr.split(separator: "?")[0])) else { return nil }
    let thumbOpt = ImageRequest.ThumbnailOptions(size: .init(width: avatarSize, height: avatarSize), unit: .points, contentMode: .aspectFill)
    return winstonImageRequest(url: url, processors: [ImageProcessors.ScaleFixer()], priority: .veryHigh, thumbnail: thumbOpt)
  }

  /// Build the fullname→request dict from the registry (plus winston's sample
  /// author used by the fake onboarding post).
  private func avatarRequests(names: [String], avatarSize: Double) -> [String: ImageRequest] {
    var dict: [String: ImageRequest] = [:]
    dict[SAMPLE_USER_AVATAR] = ImageRequest(stringLiteral: "https://winston.cafe/icons/iconExplode.png")
    var reqs: [ImageRequest] = []
    for name in names where dict[name] == nil {
      if let url = AvatarRegistry.shared.url(for: name), let req = Self.avatarImageRequest(url: url, avatarSize: avatarSize) {
        dict[name] = req
        reqs.append(req)
      }
    }
    Post.prefetcher.startPrefetching(with: reqs)
    return dict
  }

  func updatePostsWithAvatar(posts: [Post], avatarSize: Double) async {
    let names = posts.compactMap { $0.data?.author_fullname }
    let dict = avatarRequests(names: names, avatarSize: avatarSize)
    for post in posts {
      if let author = post.data?.author_fullname, let req = dict[author] {
        post.winstonData?.avatarImageRequest = req
      }
    }
  }

  func updateCommentsWithAvatar(comments: [Comment], avatarSize: Double) async {
    let names = getNamesFromComments(comments)
    let dict = avatarRequests(names: names, avatarSize: avatarSize)
    applyAvatars(dict, to: comments)
  }

  private func applyAvatars(_ dict: [String: ImageRequest], to comments: [Comment]) {
    for comment in comments {
      if let author = comment.data?.author_fullname, let req = dict[author] {
        comment.winstonData?.avatarImageRequest = req
      }
      applyAvatars(dict, to: comment.childrenWinston.data)
    }
  }

  func updateOverviewSubjectsWithAvatar(subjects: [Either<Post, Comment>], avatarSize: Double) async {
    let names: [String] = subjects.compactMap { subject in
      switch subject {
      case .first(let post): return post.data?.author_fullname
      case .second(let comment): return comment.data?.author_fullname
      }
    }
    let dict = avatarRequests(names: names, avatarSize: avatarSize)
    for subject in subjects {
      switch subject {
      case .first(let post):
        if let author = post.data?.author_fullname, let req = dict[author] {
          post.winstonData?.avatarImageRequest = req
        }
      case .second(let comment):
        if let author = comment.data?.author_fullname, let req = dict[author] {
          comment.winstonData?.avatarImageRequest = req
        }
      }
    }
  }
}

// MARK: - Identity + subscription caches (ported from REST fetchMe/fetchSubs)

func cleanSubs(_ subs: [ListingChild<SubredditData>]) -> [ListingChild<SubredditData>] {
  return subs.compactMap({ y in
    var x = y
    x.data?.description = ""
    x.data?.description_html = ""
    x.data?.public_description = ""
    x.data?.public_description_html = ""
    x.data?.submit_text_html = ""
    x.data?.submit_text = ""
    return x
  })
}


extension RedditWire {
  /// Latest signed-in username, readable from any thread. Swipe-action
  /// `enabled` checks run synchronously in view code and can't hop to the
  /// main actor for `me`.
  nonisolated(unsafe) static var currentUserName: String?

  /// Refresh (or return the cached) signed-in user. Replaces REST `fetchMe`.
  @discardableResult
  func fetchMe(force: Bool = false) async -> UserData? {
    if !force, let data = me?.data { return data }
    guard let data = await accountProfile() else {
      if force { me = nil }
      return nil
    }
    me = User(data: data)
    Self.currentUserName = data.name
    return data
  }

  /// Sync the signed-in user's subscriptions into the CachedSub CoreData store,
  /// tagged by the selected account id. Replaces REST `fetchSubs`.
  func fetchSubs() async {
    guard let currentCredentialID = Defaults[.GeneralDefSettings].redditCredentialSelectedID else { return }
    let subs = await subscriptions()
    let finalSubs = subs
      .map { ListingChild<SubredditData>(kind: "t5", data: $0) }
      .filter { $0.data?.subreddit_type != "user" }
    let context = PersistenceController.shared.container.viewContext
    let fetchRequest = NSFetchRequest<CachedSub>(entityName: "CachedSub")
    fetchRequest.predicate = NSPredicate(format: "winstonCredentialID == %@", currentCredentialID as CVarArg)
    let results = (context.performAndWait { try? context.fetch(fetchRequest) }) ?? []
    results.forEach { cachedSub in
      context.performAndWait {
        if !finalSubs.contains(where: { cachedSub.uuid == $0.data?.name }) { context.delete(cachedSub) }
      }
    }
    await context.perform(schedule: .enqueued) {
      cleanSubs(finalSubs).compactMap { $0.data }.forEach { x in
        if let found = results.first(where: { $0.uuid == x.name }) {
          found.update(data: x, credentialID: currentCredentialID)
        } else {
          _ = CachedSub(data: x, context: context, credentialID: currentCredentialID)
        }
      }
    }
    await context.perform(schedule: .enqueued) { try? context.save() }
  }
}

// MARK: - Replies, edits, deletes

extension RedditWire {
  /// Reply to a post (`t3_`) or comment (`t1_`). The captured Reddit
  /// CreateComment shape requires exactly one of postId or parentId.
  func newReply(_ text: String, to fullname: String, postFullname _: String? = nil) async -> Bool {
    do {
      _ = try await client.createTextComment(
        targetID: fullname,
        markdown: text,
        postID: nil,
        allowSideEffects: true
      )
      status = "reply to \(fullname) ✅"
      return true
    } catch {
      status = "reply failed: \(describeError(error))"
      return false
    }
  }

  /// Edit a comment's body. Post bodies can't be edited over the GraphQL
  /// surface yet (no UpdatePost operation captured).
  func editComment(fullname: String, newText: String) async -> Bool {
    do {
      _ = try await client.updateComment(commentID: fullname, markdown: newText, allowSideEffects: true)
      status = "edit \(fullname) ✅"
      return true
    } catch {
      status = "edit failed: \(describeError(error))"
      return false
    }
  }

  /// Delete one of our comments. Post deletion has no captured GraphQL
  /// operation yet — callers must treat posts as undeletable for now.
  func deleteComment(fullname: String) async -> Bool {
    do {
      _ = try await client.deleteComment(commentID: fullname, allowSideEffects: true)
      status = "delete \(fullname) ✅"
      return true
    } catch {
      status = "delete failed: \(describeError(error))"
      return false
    }
  }

  /// Hide/unhide a post (`t3_`).
  func hidePost(_ hide: Bool, fullname: String) async -> Bool {
    do {
      _ = try await client.updatePostHideState(postID: fullname, hideState: hide ? .hidden : .none, allowSideEffects: true)
      status = "hide \(fullname) \(hide) ✅"
      return true
    } catch {
      status = "hide failed: \(describeError(error))"
      return false
    }
  }

  /// Submit a text post. Link/image/gallery submission isn't captured on the
  /// GraphQL surface yet.
  func submitTextPost(subreddit: String, title: String, markdown: String) async -> Bool {
    do {
      _ = try await client.createTextPost(subredditName: subreddit, title: title, markdown: markdown, allowSideEffects: true)
      status = "submit to r/\(subreddit) ✅"
      return true
    } catch {
      status = "submit failed: \(describeError(error))"
      return false
    }
  }
}

// MARK: - More-replies expansion, in-subreddit search, subreddit info

extension RedditWire {
  /// Expand a "load more comments" stub: re-fetch the subtree under the stub's
  /// parent and return the children that aren't already shown. `excluding`
  /// carries the ids of the siblings already loaded so we don't duplicate them.
  func moreReplies(stub: CommentData, postID: String, sort: CommentSortOption = .confidence, excluding: Set<String>) async -> [ListingChild<CommentData>]? {
    guard let parentID = stub.parent_id else { return nil }
    let gqlSort: RedditCommentSortType = {
      switch sort {
      case .new: return .newest
      case .qa: return .questionAnswer
      default: return .confidence
      }
    }()
    do {
      let consumedCursor = moreCursorByStubID[stub.id]
      let children: [ListingChild<CommentData>]
      if parentID.hasPrefix("t1_") {
        let resp = try await client.commentByIdWithChildrenResponse(commentID: parentID, sort: gqlSort, after: consumedCursor)
        guard let commentById = resp.data?.commentById else { return nil }
        let postFullname = commentById.postInfo?.id ?? (postID.hasPrefix("t3_") ? postID : "t3_\(postID)")
        children = adaptCommentTrees(commentById.children?.trees ?? [], postFullname: postFullname, repairOrphans: false)
      } else {
        // Root-level continuation: PostComments does not expose `after` as a
        // typed argument yet, but the builder merges `extra` into variables.
        var extra: [String: JSONValue] = [:]
        if let consumedCursor, !consumedCursor.isEmpty {
          extra["after"] = .string(consumedCursor)
        }
        let resp = try await client.postCommentsResponse(postID: postID, sort: gqlSort, extra: extra)
        guard let post = resp.data?.postInfoById else { return nil }
        children = adaptCommentTrees(post.commentForest?.trees ?? [], postFullname: post.id, repairOrphans: false)
      }
      moreCursorByStubID.removeValue(forKey: stub.id)
      let fresh = children.filter { child in
        guard let id = child.data?.id else { return false }
        if child.kind == "more" {
          // Keep fresh continuation stubs so pagination can keep going, but
          // drop one that would replay the cursor we just consumed — that
          // would loop forever returning the same page.
          if let consumedCursor, moreCursorByStubID[id] == consumedCursor {
            moreCursorByStubID.removeValue(forKey: id)
            AppDiagnostics.asyncRecord(
              .warning,
              category: "reddit.comment",
              message: "Dropped repeated load-more continuation",
              metadata: ["parentID": parentID, "stubID": id, "postID": postID]
            )
            return false
          }
          return id != stub.id
        }
        return !excluding.contains(id)
      }
      status = "moreReplies under \(parentID) → \(fresh.count) new"
      return fresh
    } catch {
      status = "moreReplies failed: \(describeError(error))"
      return nil
    }
  }

  /// Search posts inside one subreddit (DynamicSearch with a community filter).
  func searchInSubreddit(_ name: String, query: String) async -> [PostData]? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    do {
      let resp = try await client.dynamicSearchSubredditResponse(trimmed, subredditName: name, pane: .posts)
      let posts = (resp.data?.posts ?? []).map { PostData(graphQL: $0) }.deduped { $0.id }
      status = "search in r/\(name) '\(trimmed)' → \(posts.count)"
      return posts
    } catch {
      status = "search in subreddit failed: \(describeError(error))"
      return nil
    }
  }

  /// Full subreddit record (SubredditInfoByName → SubredditData). Replaces the
  /// REST /r/{name}/about.json fetch.
  func subredditData(name: String) async -> SubredditData? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    do {
      let resp = try await client.subredditInfoByNameResponse(trimmed)
      guard let raw = resp.data?.rawData else { return nil }
      var objects: [[String: JSONValue]] = []
      raw.collectObjects(named: "subredditInfoByName", typeName: nil, into: &objects)
      if objects.isEmpty { objects = raw.objectsContainingKeys(["subscribersCount"]) }
      let data = objects.lazy.compactMap(SubredditData.init(graphQLSearchObject:)).first
      status = "subredditInfo \(trimmed) \(data == nil ? "✗" : "✅")"
      return data
    } catch {
      status = "subredditInfo failed: \(describeError(error))"
      return nil
    }
  }
}

// MARK: - Multireddits (custom feeds)

extension RedditWire {
  /// Sync the signed-in user's multireddits into the CachedMulti CoreData
  /// store. Replaces REST `fetchMyMultis`.
  func fetchMyMultis() async {
    guard let currentCredentialID = Defaults[.GeneralDefSettings].redditCredentialSelectedID else { return }
    do {
      let resp = try await client.myAuthoredMultiredditsResponse()
      let multis = (resp.data?.rawData).map(Self.multiDatas(from:)) ?? []
      status = "multis → \(multis.count)"
      let context = PersistenceController.shared.container.newBackgroundContext()
      let multisFetchRequest = NSFetchRequest<CachedMulti>(entityName: "CachedMulti")
      multisFetchRequest.predicate = NSPredicate(format: "winstonCredentialID == %@", currentCredentialID as CVarArg)
      let multisResults = (context.performAndWait { try? context.fetch(multisFetchRequest) }) ?? []
      context.performAndWait {
        multisResults.forEach { cached in
          if !multis.contains(where: { cached.uuid == $0.id }) { context.delete(cached) }
        }
      }
      multis.forEach { data in
        context.performAndWait {
          if let found = multisResults.first(where: { $0.uuid == data.id }) {
            found.update(data, credentialID: currentCredentialID)
          } else {
            _ = CachedMulti(data: data, context: context, credentialID: currentCredentialID)
          }
        }
      }
      await context.perform(schedule: .enqueued) { try? context.save() }
    } catch {
      status = "multis failed: \(describeError(error))"
    }
  }

  /// Load one page of a multireddit (custom feed): CustomFeedSdui → post ids →
  /// PostsByIds hydration.
  func multiPosts(path: String, sort: SubListingSortOption = .hot, after: String? = nil) async -> ([PostData], String?) {
    do {
      let resp = try await client.customFeedSduiResponse(path: path, sort: feedSort(from: sort), after: after)
      let raw = resp.data?.rawData
      let ids = raw?.feedPostIDs ?? []
      let pageInfo = raw.flatMap(Self.firstPageInfoObject(in:))
      let nextAfter = (pageInfo?.hasNextPage == false) ? nil : pageInfo?.endCursor
      status = "multi \(path) → \(ids.count) ids"
      guard !ids.isEmpty else { return ([], nextAfter) }
      return (await postData(forIDs: ids), nextAfter)
    } catch {
      status = "multi feed failed: \(describeError(error))"
      return ([], nil)
    }
  }

  /// Delete one of our multireddits. The GraphQL mutation takes the multi's
  /// label (the last path component), not the full path.
  func deleteMulti(path: String) async -> Bool {
    let label = path.split(separator: "/").last.map(String.init) ?? path
    do {
      _ = try await client.deleteMultireddit(label: label, allowSideEffects: true)
      status = "delete multi \(label) ✅"
      return true
    } catch {
      status = "delete multi failed: \(describeError(error))"
      return false
    }
  }

  /// Distill MyAuthoredMultireddits' raw payload into winston's MultiData.
  static func multiDatas(from raw: JSONValue) -> [MultiData] {
    var objects: [[String: JSONValue]] = []
    raw.collectObjects(named: "multireddit", typeName: nil, into: &objects)
    if objects.isEmpty {
      raw.collectObjects(named: "node", typeName: "Multireddit", into: &objects)
    }
    var seen = Set<String>()
    return objects.compactMap { obj -> MultiData? in
      guard let path = obj["path"]?.stringValue, !path.isEmpty, seen.insert(path).inserted else { return nil }
      return MultiData(graphQL: obj, path: path)
    }
  }
}

extension MultiData {
  /// Adapt one multireddit object from the MyAuthoredMultireddits raw payload.
  init(graphQL obj: [String: JSONValue], path: String) {
    let displayName = obj["displayName"]?.stringValue ?? obj["name"]?.stringValue ?? path
    self.display_name = displayName
    self.name = obj["name"]?.stringValue ?? displayName
    self.visibility = (obj["visibility"]?.stringValue?.lowercased()).flatMap(MultiVisibility.init(rawValue:))
    self.path = path
    self.description_md = obj["descriptionMd"]?.stringValue
    self.icon_url = obj["icon"]?.stringValue ?? obj["icon"]?.objectValue?["url"]?.stringValue
    self.over_18 = obj["isNsfw"]?.boolValue
    self.owner = obj["ownerInfo"]?.objectValue?["name"]?.stringValue
    self.subreddits = obj["subreddits"].map { subsValue in
      var subObjects: [[String: JSONValue]] = []
      subsValue.collectObjects(named: "subreddit", typeName: nil, into: &subObjects)
      if subObjects.isEmpty { subObjects = subsValue.arrayOfObjects }
      return subObjects.compactMap { subObj in
        guard let name = subObj["name"]?.stringValue ?? subObj["prefixedName"]?.stringValue?.replacingOccurrences(of: "r/", with: "") else { return nil }
        return MultiSub(name: name, data: SubredditData(graphQLSearchObject: subObj))
      }
    }
  }
}

// MARK: - Inbox (notifications)

extension RedditWire {
  /// Load one page of Reddit's current notification inbox. This feed includes
  /// comment/post replies plus activity notifications such as chat, achievements,
  /// recommendations, and community prompts.
  func inboxNotifications(after: String? = nil) async -> ([InboxNotification], String?) {
    do {
      let resp = try await client.getInboxNotificationFeedResponse(pageSize: 25, after: after)
      guard let raw = resp.data?.rawData else { return ([], nil) }
      var seen = Set<String>()
      let notifications = Self.inboxNotificationNodes(in: raw).compactMap { obj -> InboxNotification? in
        Self.inboxNotification(from: obj, dedup: &seen)
      }
      let pageInfo = Self.firstPageInfoObject(in: raw)
      let nextAfter = (pageInfo?.hasNextPage == false) ? nil : pageInfo?.endCursor
      status = "inbox → \(notifications.count) notifications"
      return (notifications, nextAfter)
    } catch {
      status = "inbox failed: \(describeError(error))"
      return ([], nil)
    }
  }
  
  /// Back-compat adapter for older callers that still expect REST-shaped
  /// MessageData. New UI should use `inboxNotifications(after:)`.
  func inbox(after: String? = nil) async -> ([MessageData], String?) {
    let (notifications, nextAfter) = await inboxNotifications(after: after)
    return (notifications.map(Self.messageData), nextAfter)
  }

  /// Mark the whole inbox as seen up to `lastSentAt` (ISO8601 from the newest
  /// notification). The GraphQL inbox has no per-message read/unread toggle
  /// like the REST one did.
  @discardableResult
  func markInboxSeen(lastSentAt: String) async -> Bool {
    do {
      _ = try await client.updateInboxActivitySeenState(lastSentAt: lastSentAt, allowSideEffects: true)
      return true
    } catch {
      status = "inbox seen failed: \(describeError(error))"
      return false
    }
  }

  private static func inboxNotificationNodes(in raw: JSONValue) -> [[String: JSONValue]] {
    if
      let root = raw.objectValue,
      let inbox = root["notificationInbox"]?.objectValue,
      let elements = inbox["elements"]?.objectValue,
      let edges = elements["edges"]?.arrayValue {
      return edges.compactMap { edge in
        edge.objectValue?["node"]?.objectValue
      }
    }
    
    var nodes: [[String: JSONValue]] = []
    raw.collectObjects(named: "node", typeName: "InboxNotification", into: &nodes)
    if nodes.isEmpty {
      nodes = raw.objectsContainingKeys(["sentAt", "deeplinkUrl"])
    }
    return nodes
  }

  private static func inboxNotification(from obj: [String: JSONValue], dedup: inout Set<String>) -> InboxNotification? {
    guard let id = obj["id"]?.stringValue, dedup.insert(id).inserted else { return nil }
    let sentAtStr = obj["sentAt"]?.stringValue
    let context = obj["context"]?.objectValue
    let deeplink = obj["deeplinkUrl"]?.stringValue
    let title = obj["title"]?.stringValue
    let body = obj["body"]?.stringValue ?? obj["bodyText"]?.stringValue
    let relativePermalink = deeplink.flatMap(Self.relativePermalink(from:))
    let postID = context?["post"]?.objectValue?["id"]?.stringValue
      ?? relativePermalink.flatMap(Self.postFullname(fromPermalink:))
    let commentID = relativePermalink.flatMap(Self.commentFullname(fromPermalink:))
    let parentCommentID = context?["comment"]?.objectValue?["parent"]?.objectValue?["id"]?.stringValue
    let subreddit = obj["subredditName"]?.stringValue
      ?? relativePermalink.flatMap(Self.subredditName(fromPermalink:))
      ?? title.flatMap(Self.subredditName(fromTitle:))
    return InboxNotification(
      id: id,
      title: title ?? body ?? "Notification",
      body: body,
      authorName: obj["authorInfo"]?.objectValue?["name"]?.stringValue ?? Self.authorName(fromTitle: title),
      subredditName: subreddit,
      avatarURL: obj["avatar"]?.objectValue?["url"]?.stringValue,
      deeplinkURL: deeplink,
      sentAt: sentAtStr.flatMap(Self.isoDate(from:)),
      sentAtRaw: sentAtStr,
      readAt: obj["readAt"]?.stringValue,
      messageType: context?["messageType"]?.stringValue,
      contextType: context?["__typename"]?.stringValue,
      postID: postID,
      commentID: commentID,
      parentCommentID: parentCommentID,
      postTitle: context?["post"]?.objectValue?["title"]?.stringValue
    )
  }
  
  private static func messageData(from notification: InboxNotification) -> MessageData {
    let sentAt = notification.sentAt?.timeIntervalSince1970
    let isReply = notification.messageType == "POST_REPLY" || notification.messageType == "COMMENT_REPLY"
    return MessageData(
      subreddit: notification.subredditName,
      author_fullname: nil,
      id: notification.id,
      subject: notification.title,
      author: notification.authorName,
      author_flair_text: nil,
      parent_id: notification.commentFullname ?? notification.postID,
      subreddit_name_prefixed: notification.subredditName.map { "r/\($0)" },
      new: notification.isUnread,
      type: notification.messageType == "POST_REPLY" ? "post_reply" : (isReply ? "comment_reply" : "unknown"),
      body: notification.body,
      link_title: notification.postTitle ?? notification.title,
      dest: nil,
      was_comment: isReply,
      body_html: nil,
      name: notification.commentFullname ?? notification.id,
      created: sentAt,
      created_utc: sentAt,
      context: notification.deeplinkURL.flatMap(Self.relativePermalink(from:))
    )
  }

  private static func subredditName(fromPermalink link: String) -> String? {
    guard let range = link.range(of: "/r/") else { return nil }
    return link[range.upperBound...].split(separator: "/").first.map(String.init)
  }

  private static func postFullname(fromPermalink link: String) -> String? {
    guard let id = postID(fromPermalink: link) else { return nil }
    return id.hasPrefix("t3_") ? id : "t3_\(id)"
  }

  private static func commentFullname(fromPermalink link: String) -> String? {
    guard let id = commentID(fromPermalink: link) else { return nil }
    return id.hasPrefix("t1_") ? id : "t1_\(id)"
  }

  private static func postID(fromPermalink link: String) -> String? {
    let parts = link.split(separator: "/").map(String.init)
    guard let commentsIndex = parts.firstIndex(of: "comments"), parts.indices.contains(commentsIndex + 1) else { return nil }
    return parts[commentsIndex + 1]
  }

  private static func commentID(fromPermalink link: String) -> String? {
    let parts = link.split(separator: "/").map(String.init)
    guard let commentsIndex = parts.firstIndex(of: "comments"), parts.indices.contains(commentsIndex + 3) else { return nil }
    return parts[commentsIndex + 3]
  }
  
  private static func authorName(fromTitle title: String?) -> String? {
    guard let title else { return nil }
    guard let range = title.range(of: #"u/[A-Za-z0-9_-]+"#, options: .regularExpression) else { return nil }
    return String(title[range]).replacingOccurrences(of: "u/", with: "")
  }
  
  private static func subredditName(fromTitle title: String?) -> String? {
    guard let title else { return nil }
    guard let range = title.range(of: #"r/[A-Za-z0-9_]+"#, options: .regularExpression) else { return nil }
    return String(title[range]).replacingOccurrences(of: "r/", with: "")
  }

  private static func relativePermalink(from link: String) -> String? {
    guard let url = URL(string: link) else { return nil }
    let path = url.path
    return path.isEmpty ? nil : path
  }

  private static func isoDate(from str: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = fractional.date(from: str) { return d }
    let plain = ISO8601DateFormatter()
    if let d = plain.date(from: str) { return d }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ"
    if let d = formatter.date(from: str) { return d }
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    return formatter.date(from: str)
  }
}

// MARK: - Shared raw-payload helpers

extension RedditWire {
  func describeError(_ error: Error) -> String {
    if case .cloudflareChallenge(let operation, _) = error as? RedditPOCError {
      return "Reddit is asking for a browser challenge before \(operation). Open Reddit login again and complete the challenge."
    }
    return (error as? RedditPOCError).map { "\($0)" } ?? error.localizedDescription
  }

  func feedSort(from sort: SubListingSortOption) -> RedditFeedSort {
    switch sort {
    case .best: return .best
    case .hot: return .hot
    case .new: return .newest
    case .controversial: return .controversial
    case .top: return .top
    }
  }

  struct RawPageInfo {
    let hasNextPage: Bool?
    let endCursor: String?
  }

  static func firstPageInfoObject(in raw: JSONValue) -> RawPageInfo? {
    var objects: [[String: JSONValue]] = []
    raw.collectObjects(named: "pageInfo", typeName: nil, into: &objects)
    guard let obj = objects.first else { return nil }
    return RawPageInfo(hasNextPage: obj["hasNextPage"]?.boolValue, endCursor: obj["endCursor"]?.stringValue)
  }
}

extension JSONValue {
  /// All `t3_…` ids in feed order (SDUI feeds reference posts by group id).
  var feedPostIDs: [String] {
    var ids: [String] = []
    var seen = Set<String>()
    collectFeedPostIDs(into: &ids, seen: &seen)
    return ids
  }

  private func collectFeedPostIDs(into ids: inout [String], seen: inout Set<String>) {
    switch self {
    case .object(let object):
      for key in ["groupId", "postId", "id"] {
        if let id = object[key]?.stringValue, id.hasPrefix("t3_"), seen.insert(id).inserted {
          ids.append(id)
          break
        }
      }
      for value in object.values { value.collectFeedPostIDs(into: &ids, seen: &seen) }
    case .array(let array):
      for value in array { value.collectFeedPostIDs(into: &ids, seen: &seen) }
    case .null, .bool, .number, .string:
      break
    }
  }

  var arrayOfObjects: [[String: JSONValue]] {
    guard case .array(let arr) = self else { return [] }
    return arr.compactMap { $0.objectValue }
  }

  func objectsContainingKeys(_ keys: [String]) -> [[String: JSONValue]] {
    var result: [[String: JSONValue]] = []
    collectObjectsContainingKeys(Set(keys), into: &result)
    return result
  }

  private func collectObjectsContainingKeys(_ keys: Set<String>, into result: inout [[String: JSONValue]]) {
    switch self {
    case .object(let object):
      if keys.allSatisfy({ object[$0] != nil }) { result.append(object) }
      for value in object.values { value.collectObjectsContainingKeys(keys, into: &result) }
    case .array(let array):
      for value in array { value.collectObjectsContainingKeys(keys, into: &result) }
    case .null, .bool, .number, .string:
      break
    }
  }
}
