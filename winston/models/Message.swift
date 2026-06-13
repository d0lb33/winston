//
//  Message.swift
//  winston
//
//  Created by Igor Marcossi on 10/07/23.
//

import Foundation
import SwiftUI

struct InboxNotification: Identifiable, Equatable {
  let id: String
  let title: String
  let body: String?
  let authorName: String?
  let subredditName: String?
  let avatarURL: String?
  let deeplinkURL: String?
  let sentAt: Date?
  let sentAtRaw: String?
  let readAt: String?
  let messageType: String?
  let contextType: String?
  let postID: String?
  let commentID: String?
  let parentCommentID: String?
  let postTitle: String?
  
  var isUnread: Bool { readAt == nil }
  
  var postBareID: String? {
    guard let postID else { return nil }
    return postID.hasPrefix("t3_") ? String(postID.dropFirst(3)) : postID
  }
  
  var commentFullname: String? {
    guard let commentID else { return nil }
    return commentID.hasPrefix("t1_") ? commentID : "t1_\(commentID)"
  }
  
  var displaySource: String? {
    if let subredditName, !subredditName.isEmpty { return "r/\(subredditName)" }
    return messageType?.replacingOccurrences(of: "_", with: " ").capitalized
  }
}

typealias Message = GenericRedditEntity<MessageData, AnyHashable>

extension Message {
  convenience init(data: T) {
    self.init(data: data, typePrefix: "t1_")
  }
  convenience init(id: String) {
    self.init(id: id, typePrefix: "t1_")
  }
  
  func toggleRead() async -> Bool {
    // TODO(graphql): the GraphQL inbox only supports marking the whole feed
    // seen up to a timestamp (UpdateInboxActivitySeenStateV2); there is no
    // per-message read/unread mutation. Flip locally and best-effort mark the
    // feed seen when marking as read.
    guard data != nil else { return false }
    let old = data?.new ?? false
    await MainActor.run {
      withAnimation {
        data?.new = !old
      }
    }
    if old, let created = data?.created_utc ?? data?.created {
      let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: created))
      await RedditWire.shared.markInboxSeen(lastSentAt: iso)
    }
    return true
  }
}

struct MessageData: GenericRedditEntityDataType {
//    let first_message: String?
//    let first_message_name: String?
    let subreddit: String?
//    let likes: Bool?
//    let replies: Either<String, Listing<CommentData>>?
    let author_fullname: String?
    let id: String
    let subject: String?
//    let associated_awarding_id: String?
//    let score: Int?
    let author: String?
    let author_flair_text: String?
//    let num_comments: Int?
    let parent_id: String?
    let subreddit_name_prefixed: String?
    var new: Bool?
    let type: String?
    let body: String?
    let link_title: String?
    let dest: String?
    let was_comment: Bool?
    let body_html: String?
    let name: String?
    let created: Double?
    let created_utc: Double?
    let context: String?
//    let distinguished: String?
}

func getPostId(from urlString: String) -> String? {
  let pathComponents = urlString.split(separator: "/").map(String.init)
  guard let commentsIndex = pathComponents.firstIndex(of: "comments"), pathComponents.indices.contains(commentsIndex + 1) else { return nil }
  return pathComponents[commentsIndex + 1]
}
