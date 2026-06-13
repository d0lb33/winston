//
//  redditURLParser.swift
//  winston
//
//  Created by Igor Marcossi on 29/07/23.
//

import Foundation

enum RedditURLType: Equatable, Hashable {
  case post(id: String, subreddit: String)
  case comment(id: String, postID: String, subreddit: String)
  case subreddit(name: String)
  case user(username: String)
  case youtube(videoId: String)
  case other(link: String)
}

func parseRedditURL(_ rawUrlString: String) -> RedditURLType {
  let urlString = rawUrlString
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .replacingOccurrences(of: "winstonapp://", with: "https://app.winston.cafe/")
  guard let urlComponents = URLComponents(string: urlString) else {
    return .other(link: urlString)
  }
  
  let pathComponents = urlComponents.path.components(separatedBy: "/").filter({ !$0.isEmpty })

  let host = urlComponents.host?.lowercased()
  let isRedditHost = host == "reddit.com" || host?.hasSuffix(".reddit.com") == true
  let isWinstonHost = host == "app.winston.cafe" || host?.hasSuffix(".app.winston.cafe") == true

  if isRedditHost || isWinstonHost || host == nil, pathComponents.count > 1 {
    switch pathComponents[0] {
    case "r":
      let subredditName = pathComponents[1]
      if pathComponents.count > 2 && pathComponents[2] == "comments" {
        let postId = pathComponents[3]
        if pathComponents.count >= 6 {
          let commentId = pathComponents[5]
          return .comment(id: commentId, postID: postId, subreddit: subredditName)
        }
        return .post(id: postId, subreddit: subredditName)
      } else if pathComponents.count > 2 && pathComponents[2] == "wiki" {
				return .other(link: urlString)
			}
				return .subreddit(name: subredditName)
      
    case "user", "u":
      let username = pathComponents[1]
      return .user(username: username)
      
    default:
      return .other(link: urlString)
    }
  } else if urlComponents.host?.contains("youtube.com") == true,
            let queryItems = urlComponents.queryItems,
            let videoId = queryItems.first(where: { $0.name == "v" })?.value {
    return .youtube(videoId: videoId)
  } else if urlComponents.host?.contains("youtu.be") == true, !pathComponents.isEmpty {
    let videoId = pathComponents[0]
    return .youtube(videoId: videoId)
  } else {
    return .other(link: urlString)
  }
}
