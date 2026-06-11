//
//  mediaExtractor.swift
//  winston
//
//  Created by Igor Marcossi on 21/08/23.
//

import Foundation
import SwiftUI
import NukeUI
import Nuke
import YouTubePlayerKit
import Alamofire

struct ImgExtracted: Equatable, Identifiable {
  static func == (lhs: ImgExtracted, rhs: ImgExtracted) -> Bool {
    lhs.id == rhs.id && lhs.size == rhs.size
  }
  
  let url: URL
  let size: CGSize
  let request: ImageRequest
  var id: String { self.url.absoluteString }
}

struct YTMediaExtracted: Equatable, Identifiable {
  static func == (lhs: YTMediaExtracted, rhs: YTMediaExtracted) -> Bool {
    lhs.id == rhs.id
  }
  
  let videoID: String
  let size: CGSize
  let thumbnailURL: URL
  let thumbnailRequest: ImageRequest
  let player: YouTubePlayer
  let author: String
  let authorURL: URL
  var id: String { self.videoID }
}

struct EntityExtracted<T: GenericRedditEntityDataType, B: Hashable>: Equatable {
  static func == (lhs: EntityExtracted, rhs: EntityExtracted) -> Bool {
    lhs.entity == rhs.entity
  }
  var subredditID: String? = nil
  var postID: String? = nil
  var commentID: String? = nil
  var userID: String? = nil
  let entity: GenericRedditEntity<T, B>
}

struct StreamableExtracted: Equatable {
  static func == (lhs: StreamableExtracted, rhs: StreamableExtracted) -> Bool {
    lhs.shortCode == rhs.shortCode
  }
  
  let shortCode: String
  init(url: String) {
    self.shortCode = String(url[url.index(url.lastIndex(of: "/") ?? url.startIndex, offsetBy: 1)...])
  }
}

struct StreamableCached: Equatable {
  static func == (lhs: StreamableCached, rhs: StreamableCached) -> Bool {
    lhs.url == rhs.url && lhs.size == rhs.size
  }
  
  let url: URL
  let size: CGSize
  
  init(url: URL, size: CGSize) {
    self.url = url
    self.size = size
  }
}

enum MediaExtractedType: Equatable {
  case link(PreviewModel)
  case video(SharedVideo)
  case imgs([ImgExtracted])
  case yt(YTMediaExtracted)
  case streamable(StreamableExtracted)
  case repost(Post)
  case post(EntityExtracted<PostData, PostWinstonData>?)
  case comment(EntityExtracted<CommentData, CommentWinstonData>?)
  case subreddit(EntityExtracted<SubredditData, SubredditWinstonData>?)
  case user(EntityExtracted<UserData, AnyHashable>?)
}


// ORDER MATTERS!
func mediaExtractor(compact: Bool, contentWidth: Double = .screenW, _ data: PostData, theme: WinstonTheme? = nil) -> MediaExtractedType? {
  guard !data.is_self else { return nil }

  let contentWidth = contentWidth - ((theme?.postLinks.theme.innerPadding.horizontal ?? 0) * 2) - ((theme?.postLinks.theme.outerHPadding ?? 0) * 2)
  
  if let is_gallery = data.is_gallery, is_gallery, let galleryData = data.gallery_data?.items, let metadata = data.media_metadata {
    
    let halfWidth = (contentWidth - ImageMediaPost.gallerySpacing) / 2
    let sizes = [
      1: [0: contentWidth],
      2: [0: halfWidth, 1: halfWidth],
      3: [0: halfWidth, 1: halfWidth, 2: contentWidth]
    ]
    
    let galleryArr = Array(galleryData.enumerated()).compactMap { indexedItem -> ImgExtracted? in
      let (i, item) = indexedItem
      let id = item.media_id
      if let itemMeta = metadata[String(id)], let extArr = itemMeta?.m?.split(separator: "/"), let size = itemMeta?.s {
        let sourceURL = size.u.flatMap { rootURL($0) }
        let fallbackURL = URL(string: "https://i.redd.it/\(id).\(extArr[extArr.count - 1])")
        guard let imgURL = sourceURL ?? fallbackURL else { return nil }
        
        var actualWidth = contentWidth
        if let sizeInstructions = sizes[galleryData.count], let mySize = sizeInstructions[i] { actualWidth = mySize } else { actualWidth = halfWidth }
        
        let sizeSimple = compact ? scaledCompactModeThumbSize() : actualWidth
        let processors: [ImageProcessing] = contentWidth == 0 ? [] : [ImageProcessors.Resize(size: .init(width: sizeSimple, height: sizeSimple), unit: .points, contentMode: .aspectFill, crop: false, upscale: true)]
        var userInfo: [ImageRequest.UserInfoKey : Any] = [:]
        if compact && !imgURL.absoluteString.hasSuffix(".gif") {
          userInfo[.thumbnailKey] = ImageRequest.ThumbnailOptions(size: .init(width: scaledCompactModeThumbSize(), height: scaledCompactModeThumbSize()), unit: .points, contentMode: .aspectFill)
        }
        return ImgExtracted(url: imgURL, size: CGSize(width: size.x, height: size.y), request: ImageRequest(url: imgURL, processors: processors + [ImageProcessors.ScaleFixer()], userInfo: userInfo))
      }
      return nil
    }
    return .imgs(galleryArr)
  }
  
  if let videoPreview = data.preview?.reddit_video_preview, let url = videoPreview.hls_url, let videoURL = URL(string: url) {
    let downloadURL = videoPreview.fallback_url.flatMap(URL.init(string:))
    let size = videoSize(from: data, width: cgFloat(videoPreview.width), height: cgFloat(videoPreview.height))
    let posterURL = videoPosterURL(from: data)
    let video = SharedVideo.get(url: videoURL, size: size, downloadURL: downloadURL, posterURL: posterURL)
    return .video(video)
  }
  
  if let redditVideo = data.media?.reddit_video, let url = redditVideo.hls_url, let videoURL = URL(string: url) {
    let downloadURL = redditVideo.fallback_url.flatMap(URL.init(string:))
    let size = videoSize(from: data, width: cgFloat(redditVideo.width), height: cgFloat(redditVideo.height))
    let posterURL = videoPosterURL(from: data)
    let video = SharedVideo.get(url: videoURL, size: size, downloadURL: downloadURL, posterURL: posterURL)
    return .video(video)
  }

  if let hostedVideo = redditHostedVideoURL(from: data.url) {
    let source = data.preview?.images?.first?.source
    let size = CGSize(width: source?.width ?? 0, height: source?.height ?? 0)
    let posterURL = videoPosterURL(from: data)
    let video = SharedVideo.get(url: hostedVideo.playbackURL, size: size, downloadURL: hostedVideo.downloadURL, posterURL: posterURL)
    return .video(video)
  }
  
  if data.media?.type == "youtube.com", let oembed = data.media?.oembed, let html = oembed.html, let ytID = extractYoutubeIdFromOEmbed(html), let width = oembed.width, let height = oembed.height, let author_name = oembed.author_name, let author_url = oembed.author_url, let authorURL = URL(string: author_url), let thumb = oembed.thumbnail_url, let thumbURL = URL(string: thumb) {
    let thumbReq = ImageRequest(url: thumbURL, processors: [.resize(width: getPostContentWidth(contentWidth: contentWidth, theme: theme))], priority: .normal)
    Post.prefetcher.startPrefetching(with: [thumbReq])
    let size = CGSize(width: CGFloat(width), height: CGFloat(height))
    let newExtracted = YTMediaExtracted(videoID: ytID, size: size, thumbnailURL: thumbURL, thumbnailRequest: thumbReq, player: YouTubePlayer(source: .video(id: ytID)), author: author_name, authorURL: authorURL)
    return .yt(newExtracted)
  }
  
  if let postEmbed = data.crosspost_parent_list?.first {
    return .repost(Post(data: postEmbed, contentWidth: contentWidth, secondary: true, theme: theme))
  }
  
  if IMAGES_FORMATS.contains(where: { data.url.hasSuffix($0) }), let url = rootURL(data.url) {
    var actualWidth = 0
    var actualHeight = 0
    if let images = data.preview?.images, images.count > 0, let image = images[0].source, let width = image.width, let height = image.height {
      actualWidth = width
      actualHeight = height
    }
    
    let size = compact ? scaledCompactModeThumbSize() : contentWidth
    let processors: [ImageProcessing] = contentWidth == 0 ? [] : [ImageProcessors.Resize(size: CGSize(width: size, height: size), unit: .points, contentMode: .aspectFill, crop: false, upscale: true)]
    var userInfo: [ImageRequest.UserInfoKey : Any] = [:]
    if compact && !url.absoluteString.hasSuffix(".gif") {
      userInfo[.thumbnailKey] = ImageRequest.ThumbnailOptions(size: .init(width: scaledCompactModeThumbSize(), height: scaledCompactModeThumbSize()), unit: .points, contentMode: .aspectFill)
    }
    let imgExtracted = ImgExtracted(url: url, size: CGSize(width: actualWidth, height: actualHeight), request: ImageRequest(url: url, processors: processors + [ImageProcessors.ScaleFixer()], userInfo: userInfo))
    return .imgs([imgExtracted])
  }
  
  if let images = data.preview?.images, images.count > 0, let image = images[0].source, let src = image.url?.replacing("/preview.", with: "/i."), !src.contains("external-preview"), let imgURL = rootURL(src.escape), let width = image.width, let height = image.height {
    
    let size = compact ? scaledCompactModeThumbSize() : contentWidth
    let processors: [ImageProcessing] = contentWidth == 0 ? [] : [ImageProcessors.Resize(size: CGSize(width: size, height: size), unit: .points, contentMode: .aspectFill, crop: false, upscale: true)]
    var userInfo: [ImageRequest.UserInfoKey : Any] = [:]
    if compact {
      userInfo[.thumbnailKey] = ImageRequest.ThumbnailOptions(size: .init(width: scaledCompactModeThumbSize(), height: scaledCompactModeThumbSize()), unit: .points, contentMode: .aspectFill)
    }
    let imgExtracted = ImgExtracted(url: imgURL, size: CGSize(width: width, height: height), request: ImageRequest(url: imgURL, processors: processors + [ImageProcessors.ScaleFixer()], userInfo: userInfo))
    return .imgs([imgExtracted])
  }
  
  if VIDEOS_FORMATS.contains(where: { data.url.hasSuffix($0) }), let url = URL(string: data.url) {
    let posterURL = videoPosterURL(from: data)
    let video = SharedVideo.get(url: url, size: .zero, downloadURL: url, posterURL: posterURL)
    return .video(video)
  }
  
  if data.url.contains("streamable.com") {
    return .streamable(StreamableExtracted(url: data.url))
  }
  
  let actualURL = data.url.hasPrefix("/r/") || data.url.hasPrefix("/u/") ? "https://reddit.com\(data.url)" : data.url
  guard let urlComponents = URLComponents(string: actualURL) else {
    return nil
  }
  
  let pathComponents = urlComponents.path.components(separatedBy: "/").filter({ !$0.isEmpty })
  
  if urlComponents.host?.hasSuffix("reddit.com") == true || urlComponents.host?.hasSuffix("app.winston.cafe") == true, pathComponents.count > 1 {
    switch pathComponents[0] {
    case "r":
      let subredditName = pathComponents[1]
      if pathComponents.count > 2 && pathComponents[2] == "comments" {
        let postId = pathComponents[3]
        if pathComponents.count >= 6 {
          let commentId = pathComponents[5]
          let comment = Comment(id: commentId, typePrefix: Comment.prefix)
          comment.fetchItself()
          let entityExtracted = EntityExtracted(subredditID: subredditName, postID: postId, commentID: commentId, entity: comment)
          return .comment(entityExtracted)
        }
        let post = Post(id: postId, typePrefix: Post.prefix)
        post.fetchItself()
        let entityExtracted = EntityExtracted(subredditID: subredditName, postID: postId, entity: post)
        return .post(entityExtracted)
//        return .post(id: postId, subreddit: subredditName)
      }
      let sub = Subreddit(id: subredditName)
      Task(priority: .background) {
        await sub.refreshSubreddit()
      }
      let entityExtracted = EntityExtracted(subredditID: subredditName, entity: sub)
      return .subreddit(entityExtracted)
      
    case "user", "u":
      let username = pathComponents[1]
      let user = User(id: username, typePrefix: User.prefix)
      user.fetchItself()
      let entityExtracted = EntityExtracted(userID: username, entity: user)
      return .user(entityExtracted)
//      return .user(username: username)
      
    default:
      if !data.is_self, let linkURL = URL(string: data.url) {
        return .link(PreviewModel.get(linkURL, compact: compact))
      }
    }
  }
  
  if data.post_hint == "link" || !data.domain.isEmpty, let linkURL = URL(string: data.url) {
    return .link(PreviewModel.get(linkURL, compact: compact))
  }
  
  return nil
}

private func videoPosterURL(from data: PostData) -> URL? {
  let candidates = [
    data.preview?.images?.first?.source?.url,
    data.preview?.images?.first?.resolutions?.last?.url,
    data.thumbnail
  ]

  for candidate in candidates {
    guard let candidate, !candidate.isEmpty else { continue }
    let escaped = candidate.escape
    if let url = URL(string: escaped), ["http", "https"].contains(url.scheme?.lowercased()) {
      return url
    }
  }

  return nil
}

private func videoSize(from data: PostData, width: CGFloat?, height: CGFloat?) -> CGSize {
  if let width, let height, width > 0, height > 0 {
    return CGSize(width: width, height: height)
  }

  if let source = data.preview?.images?.first?.source {
    return CGSize(width: source.width ?? 0, height: source.height ?? 0)
  }

  return .zero
}

private func cgFloat(_ value: Double?) -> CGFloat? {
  guard let value else { return nil }
  return CGFloat(value)
}

private func cgFloat(_ value: Int?) -> CGFloat? {
  guard let value else { return nil }
  return CGFloat(value)
}

private func extractYoutubeIdFromOEmbed(_ text: String) -> String? {
  let pattern = "(?<=www\\.youtube\\.com/embed/)[^?]*"
  let regex = try? NSRegularExpression(pattern: pattern)
  return regex?.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.count)).map {
    String(text[Range($0.range, in: text)!])
  }
}

private struct RedditHostedVideoURL {
  let playbackURL: URL
  let downloadURL: URL?
}

private func redditHostedVideoURL(from urlString: String) -> RedditHostedVideoURL? {
  let normalized = urlString.hasPrefix("//") ? "https:\(urlString)" : urlString
  guard let url = rootURL(normalized), url.host?.lowercased() == "v.redd.it" else { return nil }

  let ext = url.pathExtension.lowercased()
  if VIDEOS_FORMATS.contains(where: { ".\(ext)" == $0 }) {
    return RedditHostedVideoURL(playbackURL: url, downloadURL: url)
  }
  if ext == "m3u8" {
    return RedditHostedVideoURL(playbackURL: url, downloadURL: nil)
  }

  let pathComponents = url.path.components(separatedBy: "/").filter { !$0.isEmpty }
  guard let videoID = pathComponents.first else { return nil }
  guard let hlsURL = URL(string: "https://v.redd.it/\(videoID)/HLSPlaylist.m3u8") else { return nil }
  return RedditHostedVideoURL(playbackURL: hlsURL, downloadURL: nil)
}

struct StreamableAPIParams: Codable {}
          
struct StreamableAPIResponse: Codable {
  let files: StreamableAPIFiles?
}

struct StreamableAPIFiles: Codable {
  let mp4 : StreamableAPIFile?
  let mp4Mobile:  StreamableAPIFile?

  enum CodingKeys : String, CodingKey {
    case mp4 = "mp4"
    case mp4Mobile = "mp4-mobile"
  }
}

struct StreamableAPIFile: Codable {
  let url: String
  let width: Int
  let height: Int
}
