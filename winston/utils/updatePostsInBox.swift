//
//  updatePostsInBox.swift
//  winston
//
//  Created by Igor Marcossi on 25/07/23.
//

import Foundation
import Defaults
import SwiftUI
@preconcurrency import CoreData

func updatePostsInBox(force: Bool = false) async {
  let postsInBox = Defaults[.postsInBox]
  let postsInBoxNames: [String] = postsInBox.compactMap { post in
    if let lastRefresh = post.lastUpdatedAt, !force, Date().timeIntervalSince1970 - lastRefresh < 120 {
      return nil
    }
    return post.fullname
  }
  if !postsInBoxNames.isEmpty {
    let posts = await RedditWire.shared.postData(forIDs: postsInBoxNames)
    var postsDict: [String:PostData] = [:]
    posts.forEach { data in
      postsDict[data.name] = data
    }
    
    var newPostsInBox = postsInBox.map({ post in
      var newPost = post
      if let newData = postsDict[post.fullname] {
        newPost.score = newData.ups
        newPost.commentsCount = newData.num_comments
      }
      return newPost
    })
    
    let context = PersistenceController.shared.container.newBackgroundContext()
    let seenCommentCounts = await Post.seenCommentCounts(for: Set(newPostsInBox.map(\.id)), context: context)

    newPostsInBox = newPostsInBox.map { post in
      var newPost = post
      if let seenCount = seenCommentCounts[post.id], let numComments = post.commentsCount {
        newPost.newCommentsCount = numComments - Int(seenCount)
      }
      return newPost
    }
    
    await MainActor.run { [newPostsInBox] in
      withAnimation {
        Defaults[.postsInBox] = newPostsInBox
      }
    }
  }
}
