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

extension MediaExtractedType {
  var alwaysAllowsInlineNavigation: Bool {
    switch self {
    case .post, .comment, .subreddit, .user, .repost:
      return true
    default:
      return false
    }
  }

  /// True for inline AVPlayer-backed media that participates in single-active-video
  /// scroll gating. (.streamable resolves to .video once its URL is fetched.)
  /// A crosspost reports inline-video when the embedded original post has one, so the
  /// feed registers the outer row for center election (the embedded player keys off the
  /// outer post id — see PostLinkNormal's inlineVideoKeyOverride).
  var isInlineVideo: Bool {
    switch self {
    case .video, .streamable:
      return true
    case .repost(let post):
      return post.winstonData?.extractedMedia?.isInlineVideo == true
    default:
      return false
    }
  }
}

func isDirectMediaURL(_ rawURL: URL) -> Bool {
  let url = rootURL(rawURL) ?? rawURL
  let ext = url.pathExtension.lowercased()
  let extWithDot = ext.isEmpty ? "" : ".\(ext)"
  return IMAGES_FORMATS.contains(extWithDot)
    || VIDEOS_FORMATS.contains(extWithDot)
    || redditHostedVideoURL(from: url.absoluteString) != nil
}

func mediaExtractor(url rawURL: URL, compact: Bool, contentWidth: Double = Double(defaultContentWidth), diagnosticContext: String? = nil) -> MediaExtractedType? {
  let typeURL = rootURL(rawURL) ?? rawURL
  let url = loadableMediaURL(rawURL)
  let ext = typeURL.pathExtension.lowercased()
  let extWithDot = ext.isEmpty ? "" : ".\(ext)"

  if IMAGES_FORMATS.contains(where: { $0 == extWithDot }) {
    let size = compact ? scaledCompactModeThumbSize(compact: compact) : contentWidth
    let processors: [ImageProcessing] = contentWidth == 0 ? [] : [ImageProcessors.Resize(size: CGSize(width: size, height: size), unit: .points, contentMode: .aspectFill, crop: false, upscale: true)]
    let thumbnail = compact && extWithDot != ".gif"
      ? ImageRequest.ThumbnailOptions(size: .init(width: scaledCompactModeThumbSize(compact: compact), height: scaledCompactModeThumbSize(compact: compact)), unit: .points, contentMode: .aspectFill)
      : nil
    let imgExtracted = ImgExtracted(url: url, size: .zero, request: winstonImageRequest(url: url, processors: processors + [ImageProcessors.ScaleFixer()], priority: .high, thumbnail: thumbnail))
    recordURLMediaExtraction(kind: "direct_image", compact: compact, contentWidth: contentWidth, playbackURL: url, size: .zero, diagnosticContext: diagnosticContext)
    return .imgs([imgExtracted])
  }

  if let hostedVideo = redditHostedVideoURL(from: url.absoluteString) {
    recordURLMediaExtraction(kind: "hosted_video", compact: compact, contentWidth: contentWidth, playbackURL: hostedVideo.playbackURL, downloadURL: hostedVideo.downloadURL, size: .zero, diagnosticContext: diagnosticContext)
    let video = SharedVideo.get(url: hostedVideo.playbackURL, size: .zero, downloadURL: hostedVideo.downloadURL, posterURL: nil)
    return .video(video)
  }

  if VIDEOS_FORMATS.contains(where: { $0 == extWithDot }) {
    recordURLMediaExtraction(kind: "direct_video", compact: compact, contentWidth: contentWidth, playbackURL: url, downloadURL: url, size: .zero, diagnosticContext: diagnosticContext)
    let video = SharedVideo.get(url: url, size: .zero, downloadURL: url, posterURL: nil)
    return .video(video)
  }

  return nil
}


// ORDER MATTERS!
func mediaExtractor(compact: Bool, contentWidth: Double = Double(defaultContentWidth), _ data: PostData, theme: WinstonTheme? = nil) -> MediaExtractedType? {
  ScrollPerfProbe.shared.bump("mediaExtract")
  guard !data.is_self else { return nil }

  let contentWidth = contentWidth - ((theme?.postLinks.theme.innerPadding.horizontal ?? 0) * 2) - ((theme?.postLinks.theme.outerHPadding ?? 0) * 2)

  // Crossposts must be detected BEFORE url/media extraction: a crosspost's own
  // `url` is the bare v.redd.it id (its `media` is null), so extracting a video
  // from it yields an unplayable/blank player. The real media lives on the
  // embedded original post, surfaced as `.repost`.
  if let postEmbed = data.crosspost_parent_list?.first {
    AppDiagnostics.asyncRecord(
      .debug,
      category: "ui.embeddedPost",
      message: "Crosspost media extracted",
      metadata: [
        "post": data.name,
        "title": data.title,
        "embeddedPost": postEmbed.name,
        "embeddedID": postEmbed.id,
        "embeddedTitle": postEmbed.title,
        "embeddedSubreddit": postEmbed.subreddit,
        "contentWidth": "\(contentWidth)"
      ]
    )
    return .repost(Post(data: postEmbed, contentWidth: contentWidth, secondary: true, theme: theme))
  }

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
        
        let sizeSimple = compact ? scaledCompactModeThumbSize(compact: compact) : actualWidth
        let processors: [ImageProcessing] = contentWidth == 0 ? [] : [ImageProcessors.Resize(size: .init(width: sizeSimple, height: sizeSimple), unit: .points, contentMode: .aspectFill, crop: false, upscale: true)]
        var thumbnail: ImageRequest.ThumbnailOptions?
        if compact && !imgURL.absoluteString.hasSuffix(".gif") {
          thumbnail = ImageRequest.ThumbnailOptions(size: .init(width: scaledCompactModeThumbSize(compact: compact), height: scaledCompactModeThumbSize(compact: compact)), unit: .points, contentMode: .aspectFill)
        }
        return ImgExtracted(url: imgURL, size: CGSize(width: size.x, height: size.y), request: winstonImageRequest(url: imgURL, processors: processors + [ImageProcessors.ScaleFixer()], priority: .high, thumbnail: thumbnail))
      }
      return nil
    }
    if !galleryArr.isEmpty {
      recordMediaExtraction(data: data, kind: "gallery", compact: compact, contentWidth: contentWidth, size: CGSize(width: contentWidth, height: contentWidth), extra: ["items": "\(galleryArr.count)"])
      return .imgs(galleryArr)
    }
    // All gallery items failed to adapt (missing metadata) — fall through to
    // the other extractors instead of rendering an empty gallery.
    recordMediaExtraction(data: data, kind: "gallery_empty", compact: compact, contentWidth: contentWidth, size: .zero, extra: ["sourceItems": "\(galleryData.count)", "reason": "no gallery item had usable metadata"])
  }
  
  if let videoPreview = data.preview?.reddit_video_preview {
    // hls_url is preferred, but a missing one shouldn't kill the post —
    // fall back to the progressive fallback_url before giving up.
    let streamURL = videoPreview.hls_url.flatMap(URL.init(string:))
    let downloadURL = videoPreview.fallback_url.flatMap(URL.init(string:))
    if let videoURL = streamURL ?? downloadURL {
      let playbackURL = preferredInlineVideoPlaybackURL(streamURL: videoURL, downloadURL: downloadURL, postID: data.name, title: data.title)
      let size = videoSize(from: data, width: cgFloat(videoPreview.width), height: cgFloat(videoPreview.height))
      let posterURL = videoPosterURL(from: data)
      recordMediaExtraction(data: data, kind: "reddit_video_preview", compact: compact, contentWidth: contentWidth, playbackURL: playbackURL, downloadURL: downloadURL, posterURL: posterURL, size: size, extra: ["usedFallbackURL": "\(streamURL == nil)"])
      let video = SharedVideo.get(url: playbackURL, size: size, downloadURL: downloadURL, posterURL: posterURL)
      return .video(video)
    }
    recordMediaExtraction(data: data, kind: "reddit_video_preview_unusable", compact: compact, contentWidth: contentWidth, size: .zero, extra: ["reason": "no hls_url or fallback_url"])
  }

  if let redditVideo = data.media?.reddit_video {
    let streamURL = redditVideo.hls_url.flatMap(URL.init(string:))
    let downloadURL = redditVideo.fallback_url.flatMap(URL.init(string:))
    if let videoURL = streamURL ?? downloadURL {
      let playbackURL = preferredInlineVideoPlaybackURL(streamURL: videoURL, downloadURL: downloadURL, postID: data.name, title: data.title)
      let size = videoSize(from: data, width: cgFloat(redditVideo.width), height: cgFloat(redditVideo.height))
      let posterURL = videoPosterURL(from: data)
      recordMediaExtraction(data: data, kind: "reddit_video", compact: compact, contentWidth: contentWidth, playbackURL: playbackURL, downloadURL: downloadURL, posterURL: posterURL, size: size, extra: ["usedFallbackURL": "\(streamURL == nil)"])
      let video = SharedVideo.get(url: playbackURL, size: size, downloadURL: downloadURL, posterURL: posterURL)
      return .video(video)
    }
    recordMediaExtraction(data: data, kind: "reddit_video_unusable", compact: compact, contentWidth: contentWidth, size: .zero, extra: ["reason": "no hls_url or fallback_url"])
  }

  if let hostedVideo = redditHostedVideoURL(from: data.url) {
    let source = data.preview?.images?.first?.source
    let size = CGSize(width: source?.width ?? 0, height: source?.height ?? 0)
    let posterURL = videoPosterURL(from: data)
    recordMediaExtraction(data: data, kind: "hosted_video", compact: compact, contentWidth: contentWidth, playbackURL: hostedVideo.playbackURL, downloadURL: hostedVideo.downloadURL, posterURL: posterURL, size: size)
    let video = SharedVideo.get(url: hostedVideo.playbackURL, size: size, downloadURL: hostedVideo.downloadURL, posterURL: posterURL)
    return .video(video)
  }
  
  if data.media?.type == "youtube.com", let oembed = data.media?.oembed, let html = oembed.html, let ytID = extractYoutubeIdFromOEmbed(html) {
    // Only the video id is essential; everything else has sensible fallbacks.
    // Requiring the full oEmbed payload silently dropped many YouTube posts.
    let thumbURL = oembed.thumbnail_url.flatMap { URL(string: $0) } ?? URL(string: "https://i.ytimg.com/vi/\(ytID)/hqdefault.jpg")
    if let thumbURL {
      let width = oembed.width ?? 1920
      let height = oembed.height ?? 1080
      let author = oembed.author_name ?? ""
      let authorURL = oembed.author_url.flatMap { URL(string: $0) } ?? URL(string: "https://www.youtube.com/watch?v=\(ytID)") ?? thumbURL
      let thumbReq = ImageRequest(url: thumbURL, processors: [.resize(width: getPostContentWidth(contentWidth: contentWidth, theme: theme))], priority: .normal)
      Post.prefetcher.startPrefetching(with: [thumbReq])
      let size = CGSize(width: CGFloat(width), height: CGFloat(height))
      recordMediaExtraction(data: data, kind: "youtube", compact: compact, contentWidth: contentWidth, playbackURL: thumbURL, posterURL: thumbURL, size: size)
      let newExtracted = YTMediaExtracted(videoID: ytID, size: size, thumbnailURL: thumbURL, thumbnailRequest: thumbReq, player: YouTubePlayer(source: .video(id: ytID)), author: author, authorURL: authorURL)
      return .yt(newExtracted)
    }
    recordMediaExtraction(data: data, kind: "youtube_unusable", compact: compact, contentWidth: contentWidth, size: .zero, extra: ["reason": "no usable thumbnail URL", "ytID": ytID])
  }
  
  if let rawImageURL = URL(string: data.url.escape), IMAGES_FORMATS.contains(where: { ".\(rawImageURL.pathExtension.lowercased())" == $0 }) {
    let url = loadableMediaURL(rawImageURL)
    var actualWidth = 0
    var actualHeight = 0
    if let images = data.preview?.images, images.count > 0, let image = images[0].source, let width = image.width, let height = image.height {
      actualWidth = width
      actualHeight = height
    }
    
    let size = compact ? scaledCompactModeThumbSize(compact: compact) : contentWidth
    let processors: [ImageProcessing] = contentWidth == 0 ? [] : [ImageProcessors.Resize(size: CGSize(width: size, height: size), unit: .points, contentMode: .aspectFill, crop: false, upscale: true)]
    var thumbnail: ImageRequest.ThumbnailOptions?
    if compact && !url.absoluteString.hasSuffix(".gif") {
      thumbnail = ImageRequest.ThumbnailOptions(size: .init(width: scaledCompactModeThumbSize(compact: compact), height: scaledCompactModeThumbSize(compact: compact)), unit: .points, contentMode: .aspectFill)
    }
    let imgExtracted = ImgExtracted(url: url, size: CGSize(width: actualWidth, height: actualHeight), request: winstonImageRequest(url: url, processors: processors + [ImageProcessors.ScaleFixer()], priority: .high, thumbnail: thumbnail))
    recordMediaExtraction(data: data, kind: "direct_image", compact: compact, contentWidth: contentWidth, playbackURL: url, size: CGSize(width: actualWidth, height: actualHeight), extra: ["thumbnail": thumbnail == nil ? "nil" : "set"])
    return .imgs([imgExtracted])
  }
  
  // Preview images: external-preview URLs are intentionally skipped here so
  // link posts keep falling through to the link-card branch; they're used as
  // a last-resort image at the bottom of this function instead.
  if let images = data.preview?.images, images.count > 0, let image = images[0].source, let rawSrc = image.url, !rawSrc.contains("external-preview"), let width = image.width, let height = image.height {
    // Prefer the rewritten i.redd.it URL, but fall back to the raw preview
    // URL when the rewrite produces something unparsable.
    let rewritten = rawSrc.replacing("/preview.", with: "/i.")
    if let imgURL = loadableMediaURL(rewritten.escape) ?? loadableMediaURL(rawSrc.escape) {
      let size = compact ? scaledCompactModeThumbSize(compact: compact) : contentWidth
      let processors: [ImageProcessing] = contentWidth == 0 ? [] : [ImageProcessors.Resize(size: CGSize(width: size, height: size), unit: .points, contentMode: .aspectFill, crop: false, upscale: true)]
      var thumbnail: ImageRequest.ThumbnailOptions?
      if compact {
        thumbnail = ImageRequest.ThumbnailOptions(size: .init(width: scaledCompactModeThumbSize(compact: compact), height: scaledCompactModeThumbSize(compact: compact)), unit: .points, contentMode: .aspectFill)
      }
      let imgExtracted = ImgExtracted(url: imgURL, size: CGSize(width: width, height: height), request: winstonImageRequest(url: imgURL, processors: processors + [ImageProcessors.ScaleFixer()], priority: .high, thumbnail: thumbnail))
      recordMediaExtraction(data: data, kind: "preview_image", compact: compact, contentWidth: contentWidth, playbackURL: imgURL, size: CGSize(width: width, height: height), extra: ["thumbnail": thumbnail == nil ? "nil" : "set"])
      return .imgs([imgExtracted])
    }
    recordMediaExtraction(data: data, kind: "preview_image_unusable", compact: compact, contentWidth: contentWidth, size: .zero, extra: ["reason": "preview URL unparsable", "rawSrc": rawSrc])
  }
  
  if VIDEOS_FORMATS.contains(where: { data.url.hasSuffix($0) }), let url = URL(string: data.url) {
    let posterURL = videoPosterURL(from: data)
    recordMediaExtraction(data: data, kind: "direct_video", compact: compact, contentWidth: contentWidth, playbackURL: url, downloadURL: url, posterURL: posterURL, size: .zero)
    let video = SharedVideo.get(url: url, size: .zero, downloadURL: url, posterURL: posterURL)
    return .video(video)
  }
  
  if data.url.contains("streamable.com") {
    return .streamable(StreamableExtracted(url: data.url))
  }
  
  let actualURL = data.url.hasPrefix("/r/") || data.url.hasPrefix("/u/") ? "https://reddit.com\(data.url)" : data.url
  guard let urlComponents = URLComponents(string: actualURL) else {
    AppDiagnostics.asyncRecord(
      .warning,
      category: "ui.embeddedPost",
      message: "Reddit media URL could not be parsed",
      metadata: [
        "post": data.name,
        "title": data.title,
        "url": data.url,
        "actualURL": actualURL
      ]
    )
    return nil
  }
  
  let pathComponents = urlComponents.path.components(separatedBy: "/").filter({ !$0.isEmpty })
  
  if urlComponents.host?.hasSuffix("reddit.com") == true || urlComponents.host?.hasSuffix("app.winston.cafe") == true, pathComponents.count > 1 {
    switch pathComponents[0] {
    case "r":
      let subredditName = pathComponents[1]
      if pathComponents.count > 2 && pathComponents[2] == "comments" {
        let postId = pathComponents[3]
        // Entities are returned with bare ids only; RedditMediaPost owns
        // hydrating them (this function runs in the synchronous render path,
        // so it must not kick off fetches).
        if pathComponents.count >= 6 {
          let commentId = pathComponents[5]
          let comment = Comment(id: commentId, typePrefix: Comment.prefix)
          let entityExtracted = EntityExtracted(subredditID: subredditName, postID: postId, commentID: commentId, entity: comment)
          recordEmbeddedRedditEntity(data: data, kind: "comment", actualURL: actualURL, subredditID: subredditName, postID: postId, commentID: commentId)
          return .comment(entityExtracted)
        }
        let post = Post(id: postId, subID: subredditName)
        let entityExtracted = EntityExtracted(subredditID: subredditName, postID: postId, entity: post)
        recordEmbeddedRedditEntity(data: data, kind: "post", actualURL: actualURL, subredditID: subredditName, postID: postId, commentID: nil)
        return .post(entityExtracted)
      }
      let sub = Subreddit(id: subredditName)
      let entityExtracted = EntityExtracted(subredditID: subredditName, entity: sub)
      recordEmbeddedRedditEntity(data: data, kind: "subreddit", actualURL: actualURL, subredditID: subredditName, postID: nil, commentID: nil)
      return .subreddit(entityExtracted)

    case "user", "u":
      let username = pathComponents[1]
      let user = User(id: username, typePrefix: User.prefix)
      let entityExtracted = EntityExtracted(userID: username, entity: user)
      recordEmbeddedRedditEntity(data: data, kind: "user", actualURL: actualURL, subredditID: nil, postID: nil, commentID: nil, userID: username)
      return .user(entityExtracted)
      
    default:
      if !data.is_self, let linkURL = URL(string: data.url) {
        return .link(PreviewModel.get(linkURL, compact: compact))
      }
    }
  }
  
  if data.post_hint == "link" || !data.domain.isEmpty, let linkURL = URL(string: data.url) {
    recordMediaExtraction(data: data, kind: "link", compact: compact, contentWidth: contentWidth, playbackURL: linkURL, size: .zero)
    return .link(PreviewModel.get(linkURL, compact: compact))
  }

  // Last resort: every dedicated branch passed on this post, but if Reddit
  // gave us any preview image at all (including external-preview), showing it
  // beats rendering nothing.
  if let image = data.preview?.images?.first?.source, let rawSrc = image.url, let imgURL = loadableMediaURL(rawSrc.escape) {
    let size = compact ? scaledCompactModeThumbSize(compact: compact) : contentWidth
    let processors: [ImageProcessing] = contentWidth == 0 ? [] : [ImageProcessors.Resize(size: CGSize(width: size, height: size), unit: .points, contentMode: .aspectFill, crop: false, upscale: true)]
    let imgExtracted = ImgExtracted(url: imgURL, size: CGSize(width: image.width ?? 0, height: image.height ?? 0), request: winstonImageRequest(url: imgURL, processors: processors + [ImageProcessors.ScaleFixer()], priority: .high, thumbnail: nil))
    recordMediaExtraction(data: data, kind: "preview_image_fallback", compact: compact, contentWidth: contentWidth, playbackURL: imgURL, size: CGSize(width: image.width ?? 0, height: image.height ?? 0))
    return .imgs([imgExtracted])
  }

  recordMediaExtraction(data: data, kind: "none", compact: compact, contentWidth: contentWidth, size: .zero)
  return nil
}

private func loadableMediaURL(_ rawURL: URL) -> URL {
  if preservesRedditMediaQuery(rawURL) {
    return rawURL
  }
  return rootURL(rawURL) ?? rawURL
}

private func loadableMediaURL(_ rawURLString: String) -> URL? {
  guard let rawURL = URL(string: rawURLString) else { return nil }
  return loadableMediaURL(rawURL)
}

private func preservesRedditMediaQuery(_ url: URL) -> Bool {
  guard url.query?.isEmpty == false, let host = url.host?.lowercased() else { return false }
  return host == "external-preview.redd.it"
    || host == "preview.redd.it"
    || host.hasSuffix(".thumbs.redditmedia.com")
    || host.hasSuffix(".redditmedia.com")
}

private func recordEmbeddedRedditEntity(
  data: PostData,
  kind: String,
  actualURL: String,
  subredditID: String?,
  postID: String?,
  commentID: String?,
  userID: String? = nil
) {
  AppDiagnostics.asyncRecord(
    .debug,
    category: "ui.embeddedPost",
    message: "Reddit media entity extracted",
    metadata: [
      "kind": kind,
      "post": data.name,
      "title": data.title,
      "sourceURL": data.url,
      "actualURL": actualURL,
      "subredditID": subredditID ?? "nil",
      "postID": postID ?? "nil",
      "commentID": commentID ?? "nil",
      "userID": userID ?? "nil"
    ]
  )
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
      AppDiagnostics.asyncRecord(
        .debug,
        category: "ui.media.extract",
        message: "Video poster candidate selected",
        metadata: mediaExtractionMetadata(data: data, kind: "poster-candidate", compact: false, contentWidth: 0, playbackURL: url, posterURL: url, size: .zero, extra: ["candidate": candidate])
      )
      return url
    } else {
      AppDiagnostics.asyncRecord(
        .warning,
        category: "ui.media.extract",
        message: "Video poster candidate rejected",
        metadata: mediaExtractionMetadata(data: data, kind: "poster-candidate-rejected", compact: false, contentWidth: 0, size: .zero, extra: ["candidate": candidate])
      )
    }
  }

  AppDiagnostics.asyncRecord(
    .warning,
    category: "ui.media.extract",
    message: "Video poster URL missing",
    metadata: mediaExtractionMetadata(data: data, kind: "poster-missing", compact: false, contentWidth: 0, size: .zero)
  )
  return nil
}

private func recordMediaExtraction(
  data: PostData,
  kind: String,
  compact: Bool,
  contentWidth: Double,
  playbackURL: URL? = nil,
  downloadURL: URL? = nil,
  posterURL: URL? = nil,
  size: CGSize,
  extra: [String: String] = [:]
) {
  AppDiagnostics.asyncRecord(
    .debug,
    category: "ui.media.extract",
    message: "Media extracted",
    metadata: mediaExtractionMetadata(data: data, kind: kind, compact: compact, contentWidth: contentWidth, playbackURL: playbackURL, downloadURL: downloadURL, posterURL: posterURL, size: size, extra: extra)
  )
}

private func recordURLMediaExtraction(
  kind: String,
  compact: Bool,
  contentWidth: Double,
  playbackURL: URL? = nil,
  downloadURL: URL? = nil,
  size: CGSize,
  diagnosticContext: String?
) {
  AppDiagnostics.asyncRecord(
    .debug,
    category: "ui.media.extract",
    message: "URL media extracted",
    metadata: [
      "kind": kind,
      "compact": "\(compact)",
      "contentWidth": "\(contentWidth)",
      "playbackURL": playbackURL?.absoluteString ?? "nil",
      "downloadURL": downloadURL?.absoluteString ?? "nil",
      "size": "\(size.width)x\(size.height)",
      "context": diagnosticContext ?? "nil"
    ]
  )
}

private func mediaExtractionMetadata(
  data: PostData,
  kind: String,
  compact: Bool,
  contentWidth: Double,
  playbackURL: URL? = nil,
  downloadURL: URL? = nil,
  posterURL: URL? = nil,
  size: CGSize,
  extra: [String: String] = [:]
) -> [String: String] {
  [
    "kind": kind,
    "post": data.name,
    "title": data.title,
    "subreddit": data.subreddit,
    "domain": data.domain,
    "postHint": data.post_hint ?? "nil",
    "isSelf": "\(data.is_self)",
    "compact": "\(compact)",
    "contentWidth": "\(contentWidth)",
    "playbackURL": playbackURL?.absoluteString ?? "nil",
    "downloadURL": downloadURL?.absoluteString ?? "nil",
    "posterURL": posterURL?.absoluteString ?? "nil",
    "size": "\(size.width)x\(size.height)",
    "previewImageCount": "\(data.preview?.images?.count ?? 0)",
    "thumbnail": data.thumbnail ?? "nil",
    "url": data.url
  ].merging(extra) { _, new in new }
}

private func preferredInlineVideoPlaybackURL(streamURL: URL, downloadURL: URL?, postID: String, title: String) -> URL {
  guard let downloadURL, isFreshPackagedRedditMediaURL(downloadURL) else {
    return streamURL
  }

  AppDiagnostics.asyncRecord(
    .debug,
    category: "ui.video",
    message: "Using packaged Reddit MP4 for inline playback",
    metadata: [
      "post": postID,
      "title": title,
      "streamHost": streamURL.host ?? "nil",
      "downloadHost": downloadURL.host ?? "nil",
      "downloadPath": downloadURL.path
    ]
  )
  return downloadURL
}

private func isFreshPackagedRedditMediaURL(_ url: URL) -> Bool {
  let host = url.host?.lowercased()
  guard host == "packaged-media.redd.it" || host == "external-packaged-media.redd.it" else {
    return false
  }

  guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        let expiryRaw = components.queryItems?.first(where: { $0.name == "e" })?.value,
        let expiry = TimeInterval(expiryRaw) else {
    return true
  }

  return Date(timeIntervalSince1970: expiry) > Date().addingTimeInterval(15 * 60)
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
