//
//  SavedListsStore.swift
//  winston
//
//  Local, account-scoped saved lists. These are intentionally separate from
//  Reddit's online saved state.
//

import CoreData
import Foundation
import SwiftUI

extension Notification.Name {
  static let savedListsDidChange = Notification.Name("savedListsDidChange")
}

enum SavedListItemKind: String {
  case post
  case comment
}

struct SavedListItemSnapshot {
  let kind: SavedListItemKind
  let fullname: String
  let postID: String?
  let commentID: String?
  let subreddit: String?
  let author: String?
  let title: String?
  let body: String?
  let permalink: String?
  let mediaURL: String?
  let score: Int?
  let commentsCount: Int?
  let redditCreatedAt: Date?
}

struct SavedListSummary: Identifiable, Equatable {
  let id: UUID
  let name: String
  let count: Int
  let lastUsedAt: Date?
  let favorited: Bool
}

struct SavedListItemSummary: Identifiable, Equatable {
  let id: UUID
  let kind: SavedListItemKind
  let fullname: String
  let postID: String?
  let commentID: String?
  let subreddit: String?
  let author: String?
  let title: String
  let body: String?
  let permalink: String?
  let mediaURL: String?
  let score: Int
  let commentsCount: Int
  let redditCreatedAt: Date?
  let createdAt: Date?
}

@MainActor
final class SavedListsStore {
  static let shared = SavedListsStore()

  private let context: NSManagedObjectContext

  init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
    self.context = context
  }

  var accountID: UUID? {
    RedditWire.shared.accountScopeID
  }

  func summaries(limit: Int? = nil) -> [SavedListSummary] {
    guard let accountID else { return [] }
    let request = SavedList.fetchRequest()
    request.sortDescriptors = [
      NSSortDescriptor(key: "lastUsedAt", ascending: false),
      NSSortDescriptor(key: "updatedAt", ascending: false),
      NSSortDescriptor(key: "name", ascending: true)
    ]
    request.predicate = NSPredicate(format: "winstonCredentialID == %@", accountID as CVarArg)
    if let limit {
      request.fetchLimit = limit
    }
    return (try? context.fetch(request))?.compactMap(Self.summary) ?? []
  }

  func listSummary(id: UUID) -> SavedListSummary? {
    fetchList(id: id).flatMap(Self.summary)
  }

  func recentLists(limit: Int = 3) -> [SavedListSummary] {
    summaries(limit: limit)
  }

  func favoriteLists(limit: Int? = nil) -> [SavedListSummary] {
    guard let accountID else { return [] }
    let request = SavedList.fetchRequest()
    request.sortDescriptors = [
      NSSortDescriptor(key: "sortOrder", ascending: true),
      NSSortDescriptor(key: "lastUsedAt", ascending: false),
      NSSortDescriptor(key: "name", ascending: true)
    ]
    request.predicate = NSPredicate(
      format: "winstonCredentialID == %@ AND favorited == YES",
      accountID as CVarArg
    )
    if let limit {
      request.fetchLimit = limit
    }
    return (try? context.fetch(request))?.compactMap(Self.summary) ?? []
  }

  func createList(named rawName: String) -> SavedListSummary? {
    guard let accountID else { return nil }
    let name = normalizedName(rawName)
    guard !name.isEmpty else { return nil }

    if let existing = fetchList(named: name, accountID: accountID) {
      existing.lastUsedAt = Date()
      existing.updatedAt = Date()
      save()
      return Self.summary(existing)
    }

    let now = Date()
    let list = SavedList(context: context)
    list.uuid = UUID()
    list.winstonCredentialID = accountID
    list.name = name
    list.createdAt = now
    list.updatedAt = now
    list.lastUsedAt = now
    list.favorited = false
    list.sortOrder = now.timeIntervalSince1970
    save()
    return Self.summary(list)
  }

  func renameList(id: UUID, name rawName: String) {
    let name = normalizedName(rawName)
    guard !name.isEmpty, let list = fetchList(id: id) else { return }
    list.name = name
    list.updatedAt = Date()
    save()
  }

  func setFavorite(_ favorited: Bool, listID: UUID) {
    guard let list = fetchList(id: listID) else { return }
    list.favorited = favorited
    list.updatedAt = Date()
    if favorited {
      list.lastUsedAt = list.lastUsedAt ?? Date()
    }
    save()
  }

  func deleteList(id: UUID) {
    guard let list = fetchList(id: id) else { return }
    context.delete(list)
    save()
  }

  func items(in listID: UUID) -> [SavedListItemSummary] {
    guard let accountID else { return [] }
    let request = SavedListItem.fetchRequest()
    request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
    request.predicate = NSPredicate(
      format: "winstonCredentialID == %@ AND list.uuid == %@",
      accountID as CVarArg,
      listID as CVarArg
    )
    return (try? context.fetch(request))?.compactMap(Self.itemSummary) ?? []
  }

  func contains(fullname: String, in listID: UUID) -> Bool {
    guard let accountID else { return false }
    let request = SavedListItem.fetchRequest()
    request.fetchLimit = 1
    request.predicate = NSPredicate(
      format: "winstonCredentialID == %@ AND list.uuid == %@ AND fullname == %@",
      accountID as CVarArg,
      listID as CVarArg,
      fullname
    )
    return ((try? context.count(for: request)) ?? 0) > 0
  }

  func listsContaining(fullname: String) -> Set<UUID> {
    guard let accountID else { return [] }
    let request = SavedListItem.fetchRequest()
    request.predicate = NSPredicate(
      format: "winstonCredentialID == %@ AND fullname == %@",
      accountID as CVarArg,
      fullname
    )
    let items = (try? context.fetch(request)) ?? []
    return Set(items.compactMap { $0.list?.uuid })
  }

  func toggle(snapshot: SavedListItemSnapshot, in listID: UUID) -> Bool {
    if let existing = fetchItem(fullname: snapshot.fullname, listID: listID) {
      context.delete(existing)
      touchList(id: listID)
      save()
      return false
    }
    _ = add(snapshot: snapshot, to: listID)
    return true
  }

  @discardableResult
  func add(snapshot: SavedListItemSnapshot, to listID: UUID) -> Bool {
    guard let accountID, let list = fetchList(id: listID) else { return false }
    if fetchItem(fullname: snapshot.fullname, listID: listID) != nil {
      touchList(list)
      save()
      return false
    }

    let item = SavedListItem(context: context)
    item.uuid = UUID()
    item.winstonCredentialID = accountID
    item.kind = snapshot.kind.rawValue
    item.fullname = snapshot.fullname
    item.postID = snapshot.postID
    item.commentID = snapshot.commentID
    item.subreddit = snapshot.subreddit
    item.author = snapshot.author
    item.title = snapshot.title
    item.body = snapshot.body
    item.permalink = snapshot.permalink
    item.mediaURL = snapshot.mediaURL
    item.score = Int32(snapshot.score ?? 0)
    item.commentsCount = Int32(snapshot.commentsCount ?? 0)
    item.redditCreatedAt = snapshot.redditCreatedAt
    item.createdAt = Date()
    item.list = list
    touchList(list)
    save()
    return true
  }

  func remove(itemID: UUID) {
    guard let item = fetchItem(id: itemID) else { return }
    let list = item.list
    context.delete(item)
    if let list {
      touchList(list)
    }
    save()
  }

  func openPost(from item: SavedListItemSummary) -> Post? {
    guard let postID = item.postID else { return nil }
    return Post(id: postID, subID: item.subreddit ?? "")
  }

  func snapshotPost(from item: SavedListItemSummary, contentWidth: CGFloat) -> Post? {
    guard item.kind == .post else { return nil }
    return Post(data: postData(from: item), contentWidth: contentWidth)
  }

  func openComment(from item: SavedListItemSummary) -> Comment? {
    guard item.kind == .comment, let commentID = item.commentID else { return nil }
    var data = CommentData(id: commentID)
    data.name = item.fullname
    data.subreddit = item.subreddit
    data.author = item.author
    data.body = item.body
    data.link_id = item.postID.map { "t3_\($0)" }
    data.link_title = item.title
    data.permalink = item.permalink
    data.score = item.score
    data.ups = item.score
    data.created = item.redditCreatedAt?.timeIntervalSince1970
    data.created_utc = item.redditCreatedAt?.timeIntervalSince1970
    data.saved = false
    return Comment(data: data)
  }

  func snapshot(for post: Post) -> SavedListItemSnapshot? {
    guard let data = post.data else { return nil }
    return SavedListItemSnapshot(
      kind: .post,
      fullname: data.name,
      postID: data.id,
      commentID: nil,
      subreddit: data.subreddit,
      author: data.author,
      title: data.title,
      body: data.selftext,
      permalink: data.permalink,
      mediaURL: postMediaURL(data),
      score: data.ups,
      commentsCount: data.num_comments,
      redditCreatedAt: Date(timeIntervalSince1970: data.created)
    )
  }

  func snapshot(for comment: Comment) -> SavedListItemSnapshot? {
    guard let data = comment.data else { return nil }
    let fullname = data.name ?? "t1_\(data.id)"
    return SavedListItemSnapshot(
      kind: .comment,
      fullname: fullname,
      postID: data.link_id.map(Self.bareID),
      commentID: data.id,
      subreddit: data.subreddit,
      author: data.author,
      title: data.link_title,
      body: data.body,
      permalink: data.permalink,
      mediaURL: nil,
      score: data.ups ?? data.score,
      commentsCount: nil,
      redditCreatedAt: Date(timeIntervalSince1970: data.created ?? data.created_utc ?? 0)
    )
  }

  private func fetchList(id: UUID) -> SavedList? {
    guard let accountID else { return nil }
    let request = SavedList.fetchRequest()
    request.fetchLimit = 1
    request.predicate = NSPredicate(
      format: "winstonCredentialID == %@ AND uuid == %@",
      accountID as CVarArg,
      id as CVarArg
    )
    return (try? context.fetch(request))?.first
  }

  private func fetchList(named name: String, accountID: UUID) -> SavedList? {
    let request = SavedList.fetchRequest()
    request.fetchLimit = 1
    request.predicate = NSPredicate(
      format: "winstonCredentialID == %@ AND name =[c] %@",
      accountID as CVarArg,
      name
    )
    return (try? context.fetch(request))?.first
  }

  private func fetchItem(id: UUID) -> SavedListItem? {
    guard let accountID else { return nil }
    let request = SavedListItem.fetchRequest()
    request.fetchLimit = 1
    request.predicate = NSPredicate(
      format: "winstonCredentialID == %@ AND uuid == %@",
      accountID as CVarArg,
      id as CVarArg
    )
    return (try? context.fetch(request))?.first
  }

  private func fetchItem(fullname: String, listID: UUID) -> SavedListItem? {
    guard let accountID else { return nil }
    let request = SavedListItem.fetchRequest()
    request.fetchLimit = 1
    request.predicate = NSPredicate(
      format: "winstonCredentialID == %@ AND list.uuid == %@ AND fullname == %@",
      accountID as CVarArg,
      listID as CVarArg,
      fullname
    )
    return (try? context.fetch(request))?.first
  }

  private func touchList(id: UUID) {
    guard let list = fetchList(id: id) else { return }
    touchList(list)
  }

  private func touchList(_ list: SavedList) {
    let now = Date()
    list.lastUsedAt = now
    list.updatedAt = now
  }

  private func save() {
    guard context.hasChanges else { return }
    try? context.save()
    NotificationCenter.default.post(name: .savedListsDidChange, object: nil)
  }

  private func normalizedName(_ rawName: String) -> String {
    rawName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func postMediaURL(_ data: PostData) -> String? {
    if let thumbnail = data.thumbnail,
       !thumbnail.isEmpty,
       thumbnail != "self",
       thumbnail != "default",
       thumbnail != "nsfw",
       thumbnail.hasPrefix("http") {
      return thumbnail
    }
    return data.url.hasPrefix("http") ? data.url : nil
  }

  private func postData(from item: SavedListItemSummary) -> PostData {
    let postID = item.postID ?? Self.bareID(item.fullname)
    let subreddit = item.subreddit ?? ""
    return PostData(
      subreddit: subreddit,
      selftext: item.body ?? "",
      author_fullname: nil,
      saved: false,
      gilded: 0,
      clicked: false,
      title: item.title,
      subreddit_name_prefixed: subreddit.isEmpty ? "" : "r/\(subreddit)",
      hidden: false,
      ups: item.score,
      downs: 0,
      hide_score: false,
      name: item.fullname,
      quarantine: false,
      upvote_ratio: 1,
      subreddit_type: "public",
      total_awards_received: 0,
      is_self: item.mediaURL == nil,
      created: item.redditCreatedAt?.timeIntervalSince1970 ?? 0,
      domain: "",
      allow_live_comments: false,
      id: postID,
      is_robot_indexable: false,
      author: item.author ?? "",
      num_comments: item.commentsCount,
      send_replies: false,
      contest_mode: false,
      permalink: item.permalink ?? "",
      url: item.mediaURL ?? "",
      subreddit_subscribers: 0,
      num_crossposts: 0
    )
  }

  private static func summary(_ list: SavedList) -> SavedListSummary? {
    guard let id = list.uuid else { return nil }
    return SavedListSummary(
      id: id,
      name: list.name ?? "Untitled List",
      count: list.items?.count ?? 0,
      lastUsedAt: list.lastUsedAt,
      favorited: list.favorited
    )
  }

  private static func itemSummary(_ item: SavedListItem) -> SavedListItemSummary? {
    guard let id = item.uuid,
          let rawKind = item.kind,
          let kind = SavedListItemKind(rawValue: rawKind),
          let fullname = item.fullname
    else { return nil }
    return SavedListItemSummary(
      id: id,
      kind: kind,
      fullname: fullname,
      postID: item.postID,
      commentID: item.commentID,
      subreddit: item.subreddit,
      author: item.author,
      title: item.title ?? item.body ?? "Saved Item",
      body: item.body,
      permalink: item.permalink,
      mediaURL: item.mediaURL,
      score: Int(item.score),
      commentsCount: Int(item.commentsCount),
      redditCreatedAt: item.redditCreatedAt,
      createdAt: item.createdAt
    )
  }

  private static func bareID(_ rawID: String) -> String {
    rawID
      .replacingOccurrences(of: "t1_", with: "")
      .replacingOccurrences(of: "t3_", with: "")
  }
}
