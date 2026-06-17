//
//  PostData.swift
//  winston
//
//  Created by Igor Marcossi on 26/06/23.
//

import Foundation
import Defaults
import SwiftUI
import Nuke
@preconcurrency import CoreData
import YouTubePlayerKit
import Alamofire

typealias Post = GenericRedditEntity<PostData, PostWinstonData>

enum PostRefreshResult {
  case loaded(comments: [Comment], next: String?)
  case empty
  case transientEmpty(String)
  case failed(String)
}

private struct SeenPostSnapshot {
  let count: Int
  let comments: String?
}

@MainActor
private final class PostRefreshCoordinator {
  static let shared = PostRefreshCoordinator()

  private var inFlight: [String: Task<PostRefreshResult, Never>] = [:]

  func load(key: String, operation: @MainActor @escaping () async -> PostRefreshResult) async -> PostRefreshResult {
    if let task = inFlight[key] {
      return await task.value
    }

    let task = Task { @MainActor in
      await operation()
    }
    inFlight[key] = task
    let result = await task.value
    inFlight[key] = nil
    return result
  }
}

extension Post {
  static var prefetcher = ImagePrefetcher(pipeline: ImagePipeline.shared, destination: .memoryCache, maxConcurrentRequestCount: 10)
  static var prefix = "t3"
  var selfPrefix: String { Self.prefix }

  static func normalizedBareID(_ rawID: String) -> String {
    var id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
    if id.hasPrefix("\(Post.prefix)_") {
      id.removeFirst(Post.prefix.count + 1)
    }
    while id.hasPrefix("_") {
      id.removeFirst()
    }
    return id
  }
  
  convenience init(data: T, sub: Subreddit? = nil, contentWidth: Double = Double(defaultContentWidth), secondary: Bool = false, imgPriority: ImageRequest.Priority = .low, theme: WinstonTheme? = nil, fetchAvatar: Bool = true) {
    let theme = theme ?? getEnabledTheme()
    self.init(data: data, typePrefix: "\(Post.prefix)_")
    setupWinstonData(data: data, contentWidth: contentWidth, secondary: secondary, theme: theme, sub: sub, fetchAvatar: fetchAvatar)
  }
  
  convenience init(id: String, sub: Subreddit? = nil) {
    self.init(id: Post.normalizedBareID(id), typePrefix: "\(Post.prefix)_")
    let newWinstonData = PostWinstonData()
    newWinstonData.subreddit = sub
    self.winstonData = newWinstonData
  }
  
  convenience init(id: String, subID: String) {
    self.init(id: Post.normalizedBareID(id), typePrefix: "\(Post.prefix)_")
    let newWinstonData = PostWinstonData()
    newWinstonData._strongSubreddit = Subreddit(id: subID)
    self.winstonData = newWinstonData
  }
  
  func setupWinstonData(data: PostData? = nil, winstonData: PostWinstonData? = nil, contentWidth: Double = Double(defaultContentWidth), secondary: Bool = false, theme: WinstonTheme, sub: Subreddit? = nil, styleKey: String? = nil, fetchAvatar: Bool = true) {
    if let data = data ?? self.data {
      let feedStyleKey = styleKey ?? sub?.id ?? data.subreddit
      let feedDefSettings = Defaults[.SubredditFeedDefSettings]
      let compactOverride = feedDefSettings.compactPerSubreddit[feedStyleKey]
      let styleOverride = feedDefSettings.postStylePerSubreddit[feedStyleKey]
      let compact = Defaults[.PostLinkDefSettings].resolvedPostStyle(styleOverride: styleOverride, compactOverride: compactOverride) == .compact
      if self.winstonData == nil { self.winstonData = .init() }

      self.winstonData?.permaURL = URL(string: "https://reddit.com\(data.permalink.escape.urlEncoded)")

      if FeedMediaDiagnostics.isAuroraFeedMediaDisabled {
        self.winstonData?.extractedMedia = nil
        self.winstonData?.extractedMediaForcedNormal = nil
        self.winstonData?.postDimensions = .zero
        self.winstonData?.postDimensionsForcedNormal = .zero
      } else {
        var extractedMedia = mediaExtractor(compact: compact, contentWidth: contentWidth, data, theme: theme)
        var extractedMediaForcedNormal = compact ? mediaExtractor(compact: false, contentWidth: contentWidth, data, theme: theme) : extractedMedia
        if AppDiagnostics.isEnabled(.debug, category: "ui.media.setup") {
          AppDiagnostics.asyncRecord(
            .debug,
            category: "ui.media.setup",
            message: "Post media setup extracted",
            metadata: [
              "post": data.name,
              "title": data.title,
              "subreddit": data.subreddit,
              "compact": "\(compact)",
              "contentWidth": "\(contentWidth)",
              "media": Post.diagnosticsMediaKind(extractedMedia),
              "forcedNormalMedia": Post.diagnosticsMediaKind(extractedMediaForcedNormal),
              "postHint": data.post_hint ?? "nil",
              "domain": data.domain,
              "url": data.url
            ]
          )
        }

        switch extractedMedia {
        case .streamable(let streamable):
          if let streamableCached = Caches.streamable.get(key: streamable.shortCode) {
            let sharedVideo = SharedVideo.get(url: streamableCached.url, size: streamableCached.size, downloadURL: streamableCached.url)

            extractedMedia = .video(sharedVideo)
            extractedMediaForcedNormal = .video(sharedVideo)
          } else {
            let shortCode = streamable.shortCode
            Task { @MainActor in
              if let streamableCached = await Self.loadStreamableMedia(shortCode: shortCode) {
                Caches.streamable.addKeyValue(key: shortCode, data: { streamableCached }, expires: Date().dateByAdding(1, .day).date)

                let video = SharedVideo.get(url: streamableCached.url, size: streamableCached.size, downloadURL: streamableCached.url)
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                  self.winstonData?.extractedMedia = .video(video)
                  self.winstonData?.extractedMediaForcedNormal = .video(video)

                  self.winstonData?.postDimensions = getPostDimensions(post: self, winstonData: self.winstonData, columnWidth: contentWidth, secondary: secondary, rawTheme: theme, subId: feedStyleKey)
                  self.winstonData?.postDimensionsForcedNormal = getPostDimensions(post: self, winstonData: self.winstonData, columnWidth: contentWidth, secondary: secondary, rawTheme: theme, compact: false)
                }
              }
            }
          }
        default:
          break
        }

        self.winstonData?.extractedMedia = extractedMedia
        self.winstonData?.extractedMediaForcedNormal = extractedMediaForcedNormal

        self.winstonData?.postDimensions = getPostDimensions(post: self, winstonData: self.winstonData, columnWidth: contentWidth, secondary: secondary, rawTheme: theme, subId: feedStyleKey)
        self.winstonData?.postDimensionsForcedNormal = getPostDimensions(post: self, winstonData: self.winstonData, columnWidth: contentWidth, secondary: secondary, rawTheme: theme, compact: false)
      }

      self.winstonData?.titleAttr = createTitleTagsAttrString(titleTheme: theme.postLinks.theme.titleText, postData: data, textColor: theme.postLinks.theme.titleText.color.uiColor())
      
      let hydratedSubredditData = SubredditMetadataRegistry.shared.data(forName: data.subreddit, id: data.subreddit_id)
      if let sub {
        if let hydratedSubredditData, shouldUseHydratedSubredditData(hydratedSubredditData, insteadOf: sub, for: data) {
          var mergedSubredditData = hydratedSubredditData
          if let existingSubredditData = sub.data {
            mergedSubredditData.preserveDisplayMetadata(from: existingSubredditData)
          }
          self.winstonData?._weakSubreddit = nil
          self.winstonData?._strongSubreddit = Subreddit(data: mergedSubredditData)
        } else {
          self.winstonData?.subreddit = sub
        }
      } else {
        self.winstonData?._weakSubreddit = nil
        if let subredditData = hydratedSubredditData {
          self.winstonData?._strongSubreddit = Subreddit(data: subredditData)
        } else {
          self.winstonData?._strongSubreddit = Subreddit(id: data.subreddit)
        }
      }
      
      if fetchAvatar {
        RedditWire.shared.applyAvatars(toPosts: [self], avatarSize: theme.postLinks.theme.badge.avatar.size)
      }
    }
  }

  private func shouldUseHydratedSubredditData(_ data: SubredditData, insteadOf sub: Subreddit, for postData: PostData) -> Bool {
    let aggregateFeeds: Set<String> = ["home", "popular", "all", "saved"]
    let feedID = sub.id.lowercased()
    let feedName = sub.feedName.lowercased()
    if aggregateFeeds.contains(feedID) || aggregateFeeds.contains(feedName) {
      return true
    }

    let postSubreddit = postData.subreddit.lowercased()
    let subDisplayName = sub.data?.display_name?.lowercased()
    let isSameSubreddit = feedID == postSubreddit || feedName == postSubreddit || subDisplayName == postSubreddit
    let currentIconURL = sub.data?.subredditIconKit.url
    let hydratedIconURL = data.subredditIconKit.url
    return isSameSubreddit && currentIconURL?.isEmpty != false && hydratedIconURL?.isEmpty == false
  }
  
  nonisolated static func extractFlairData(data: PostData, checkDefaultsForColor: Bool = false) -> FilterData? {
    if let flair = data.link_flair_text, let cleansed = flairWithoutEmojis(str: flair), !cleansed.joined().isEmpty {
      let hasBackground = data.link_flair_background_color != nil && !data.link_flair_background_color!.isEmpty
      var textColor = hasBackground && data.link_flair_text_color != nil ? (data.link_flair_text_color! == "light" ? "FFFFFF" : "000000") : "000000"
      var bgColor = hasBackground ? data.link_flair_background_color! : "D5D7D9"
      
      if bgColor == "D5D7D9" && checkDefaultsForColor {
        if let subId = data.subreddit_id, let flairText = data.link_flair_text {
          let context = PersistenceController.shared.container.newBackgroundContext()
          let fetchRequest = NSFetchRequest<CachedFilter>(entityName: "CachedFilter")
          fetchRequest.predicate = NSPredicate(format: "subreddit_id == %@ && text == %@ && type == 'flair'", subId, flairText)
          
          context.performAndWait {
            if let prevFlair = (try? context.fetch(fetchRequest))?.first {
              bgColor = prevFlair.background_color ?? bgColor
              textColor = prevFlair.text_color ?? textColor
            }
          }
        }
      }
      
      return FilterData(text: cleansed.joined(separator: " "), text_color: textColor, background_color: bgColor)
    }
    
    return nil
  }
  
  static func initMultiple(datas: [T], sub: Subreddit? = nil, contentWidth: CGFloat = 0) -> [Post] {
    let context = PersistenceController.shared.container.newBackgroundContext()
    let theme = getEnabledTheme()
    let postIDs = Set(datas.map(\.id))

    let seenPosts = seenPostSnapshots(for: postIDs, context: context)

    let posts = Array(datas.enumerated()).map { i, data in
      let seenPost = seenPosts[data.id]
      let priorityIMap: [Int:ImageRequest.Priority] = [
        4: .veryHigh,
        9: .high,
        14: .normal,
        19: .low
      ]
      let priority = i > 19 ? .veryLow : priorityIMap[priorityIMap.keys.first { $0 > i } ?? 19]!
      let newPost = Post(data: data, sub: sub, contentWidth: contentWidth, imgPriority: i > 7 ? .veryLow : priority, theme: theme, fetchAvatar: false)
      newPost.data?.winstonSeen = seenPost != nil

      if let seenPost {
        newPost.winstonData?.seenCommentsCount = seenPost.count
        newPost.winstonData?.seenComments = seenPost.comments
      }

      return newPost
    }

    if let sub {
      saveFlairsFromPosts(sub: sub, posts: posts)
    }

    let repostsAvatars = posts.compactMap { post in
      if case .repost(let repost) = post.winstonData?.extractedMedia {
        return repost
      }
      return nil
    }

    RedditWire.shared.applyAvatars(toPosts: repostsAvatars, avatarSize: getEnabledTheme().postLinks.theme.badge.avatar.size)

    var imgRequests: [ImageRequest] = posts.reduce(into: []) { prev, curr in
      if case .imgs(let imgsExtracted) = curr.winstonData?.extractedMedia {
        let reqs = imgsExtracted.map { $0.request }
        prev = prev + reqs
      }
    }
    let videoPosterRequests: [ImageRequest] = posts.compactMap { post in
      guard case .video(let sharedVideo) = post.winstonData?.extractedMedia,
            let posterURL = sharedVideo.posterURL else { return nil }
      return winstonImageRequest(
        url: posterURL,
        processors: [ImageProcessors.ScaleFixer()],
        priority: .high,
        thumbnail: nil
      )
    }
    imgRequests.append(contentsOf: videoPosterRequests)
    let mediaKinds = posts.prefix(8).map { post in
      "\(post.id):\(Post.diagnosticsMediaKind(post.winstonData?.extractedMedia))"
    }.joined(separator: ",")
    let videoPosterURLs = posts.compactMap { post -> String? in
      if case .video(let sharedVideo) = post.winstonData?.extractedMedia {
        return sharedVideo.posterURL?.absoluteString
      }
      return nil
    }
    AppDiagnostics.asyncRecord(
      .info,
      category: "ui.media.prefetch",
      message: "Starting feed media prefetch",
      metadata: [
        "posts": "\(posts.count)",
        "requests": "\(imgRequests.count)",
        "videoPosterRequests": "\(videoPosterRequests.count)",
        "firstMediaKinds": mediaKinds,
        "videoPosters": "\(videoPosterURLs.count)",
        "firstVideoPosters": videoPosterURLs.prefix(5).joined(separator: ",")
      ]
    )
    Post.prefetcher.startPrefetching(with: imgRequests)
    return posts
  }

  private static func seenPostSnapshots(for postIDs: Set<String>, context: NSManagedObjectContext) -> [String: SeenPostSnapshot] {
    let fetchRequest = seenPostRequest(for: postIDs)
    guard fetchRequest.predicate != nil else { return [:] }

    return context.performAndWait {
      fetchSeenPosts(using: fetchRequest, in: context).reduce(into: [String: SeenPostSnapshot]()) { seenPosts, seenPost in
        guard let postID = seenPost.postID else { return }
        seenPosts[postID] = SeenPostSnapshot(count: Int(seenPost.numComments), comments: seenPost.seenComments)
      }
    }
  }

  private static func seenPostRequest(for postIDs: Set<String>) -> NSFetchRequest<SeenPost> {
    let fetchRequest = NSFetchRequest<SeenPost>(entityName: "SeenPost")
    let postIDs = postIDs.filter { !$0.isEmpty }

    if !postIDs.isEmpty {
      fetchRequest.predicate = NSPredicate(format: "postID IN %@", Array(postIDs))
    }

    return fetchRequest
  }

  private static func fetchSeenPosts(for postIDs: Set<String>, in context: NSManagedObjectContext) -> [SeenPost] {
    fetchSeenPosts(using: seenPostRequest(for: postIDs), in: context)
  }

  private static func fetchSeenPosts(using fetchRequest: NSFetchRequest<SeenPost>, in context: NSManagedObjectContext) -> [SeenPost] {
    guard fetchRequest.predicate != nil else { return [] }
    return (try? context.fetch(fetchRequest)) ?? []
  }

  private static func upsertSeenPost(postID: String, in context: NSManagedObjectContext) -> (seenPost: SeenPost, didCreate: Bool)? {
    guard !postID.isEmpty else { return nil }

    if let seenPost = fetchSeenPosts(for: [postID], in: context).first {
      return (seenPost, false)
    }

    let newSeenPost = SeenPost(context: context)
    newSeenPost.postID = postID
    return (newSeenPost, true)
  }

  private static func appendSeenCommentIDs(_ ids: [String], to seenPost: SeenPost) -> String {
    var seenComments = seenPost.seenComments ?? ""

    ids.filter { !$0.isEmpty }.forEach { id in
      if !seenComments.contains(id) {
        seenComments += "\(seenComments.isEmpty ? "" : ",")\(id)"
      }
    }

    seenPost.seenComments = seenComments
    return seenComments
  }

  static func seenCommentCounts(for postIDs: Set<String>, context: NSManagedObjectContext) async -> [String: Int32] {
    let postIDs = postIDs.filter { !$0.isEmpty }
    guard !postIDs.isEmpty else { return [:] }

    return await context.perform(schedule: .enqueued) {
      fetchSeenPosts(for: Set(postIDs), in: context).reduce(into: [String: Int32]()) { counts, seenPost in
        guard let postID = seenPost.postID else { return }
        counts[postID] = seenPost.numComments
      }
    }
  }
  
  static func saveFlairsFromPosts(sub: Subreddit, posts: [Post]) {
    let context = PersistenceController.shared.container.newBackgroundContext()
    let fetchRequest = NSFetchRequest<CachedFilter>(entityName: "CachedFilter")
    fetchRequest.predicate = NSPredicate(format: "subreddit_id == %@", sub.id)
    let subID = sub.id
    let postDatas = posts.compactMap(\.data)

    context.performAndWait {
      var prevSubFlairs = (try? context.fetch(fetchRequest)) ?? []

      postDatas.forEach { data in
        if let flairText = data.link_flair_text {
          guard let flairData = Post.extractFlairData(data: data) else { return }
          
          if let prev = prevSubFlairs.first(where: { $0.text == flairText }) {
            prev.occurences = prev.occurences + 1
            
            if flairData.background_color != "D5D7D9" && flairData.background_color != prev.background_color {
              prev.background_color = flairData.background_color
              prev.text_color = flairData.text_color
            }
          } else {
            let newFilter = CachedFilter(context: context)
            
            newFilter.subreddit_id = subID
            newFilter.type = "flair"
            newFilter.text = flairData.text
            newFilter.text_color = flairData.text_color
            newFilter.background_color = flairData.background_color
            newFilter.occurences = 1
            
            prevSubFlairs.append(newFilter)
          }
        }
      }
      
      try? context.save()
      
      let flairFilters = prevSubFlairs.map({ FilterData.from($0) })
      DispatchQueue.main.async {
        withAnimation {
          sub.winstonData?.flairs = flairFilters
        }
      }
    }
  }
  
  static func loadStreamableMedia(shortCode: String) async -> StreamableCached? {
    let response = await AF.request(
      "https://api.streamable.com/videos/\(shortCode)"
    ).serializingDecodable(StreamableAPIResponse.self).response
    
    switch response.result {
    case .success(let data):
      if let mp4 = data.files?.mp4Mobile ?? data.files?.mp4 {
        if let videoURL = URL(string: mp4.url) {
          let size =  CGSize(width: mp4.width, height: mp4.height)
          return StreamableCached(url: videoURL, size: size)
        }
      }
    case .failure:
      return nil
    }
    
    return nil
  }

  @MainActor
  func setLocalSeenState(_ seen: Bool) {
    guard (data?.winstonSeen ?? false) != seen else { return }

    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      ScrollPerfProbe.shared.bump("postSeenOptimistic")
      var newData = data
      newData?.winstonSeen = seen
      data = newData
    }
  }
  
  func toggleSeen(_ seen: Bool? = nil, optimistic: Bool = false) async -> Void {
    let previous = self.data?.winstonSeen ?? false
    let next = seen ?? !previous

    if previous == next {
      if next {
        await Self.persistSeenPostIDs([id])
      }
      return
    }

    if optimistic {
      await setLocalSeenState(next)
    }

    if next {
      await Self.persistSeenPostIDs([id])
    } else {
      await Self.deleteSeenPostID(id)
    }

    if !optimistic {
      await setLocalSeenState(next)
    }
  }

  static func deleteSeenPostID(_ id: String) async {
    guard !id.isEmpty else { return }

    let context = PersistenceController.shared.primaryBGContext
    await context.perform(schedule: .enqueued) {
      let fetchRequest = NSFetchRequest<SeenPost>(entityName: "SeenPost")
      fetchRequest.predicate = NSPredicate(format: "postID == %@", id as CVarArg)

      guard let results = try? context.fetch(fetchRequest), !results.isEmpty else { return }
      results.forEach { context.delete($0) }
      try? context.save()
    }
  }

  @discardableResult
  static func clearReadHistory() async -> Int {
    let context = PersistenceController.shared.primaryBGContext
    let viewContext = PersistenceController.shared.container.viewContext

    return await context.perform(schedule: .enqueued) {
      let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "SeenPost")
      let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
      deleteRequest.resultType = .resultTypeObjectIDs

      guard let result = try? context.execute(deleteRequest) as? NSBatchDeleteResult,
            let deletedObjectIDs = result.result as? [NSManagedObjectID],
            !deletedObjectIDs.isEmpty else {
        return 0
      }

      let changes: [AnyHashable: Any] = [NSDeletedObjectsKey: deletedObjectIDs]
      NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context, viewContext])
      try? context.save()
      return deletedObjectIDs.count
    }
  }

  static func persistSeenPostIDs(_ ids: Set<String>) async {
    let ids = ids.filter { !$0.isEmpty }
    guard !ids.isEmpty else { return }

    let context = PersistenceController.shared.primaryBGContext
    await context.perform(schedule: .enqueued) {
      let existingIDs = Set(fetchSeenPosts(for: Set(ids), in: context).compactMap(\.postID))
      let missingIDs = Set(ids).subtracting(existingIDs)
      guard !missingIDs.isEmpty else { return }

      missingIDs.forEach { id in
        let newSeenPost = SeenPost(context: context)
        newSeenPost.postID = id
      }
      try? context.save()
    }
  }
  
  func toggleFilterSubreddit(_ subreddit: String) async -> Void {
    var filteredSubreddits = Defaults[.filteredSubreddits]
    
    if let index = filteredSubreddits.firstIndex(of: subreddit) {
      // Subreddit exists in the array, remove it
      filteredSubreddits.remove(at: index)
    } else {
      // Subreddit doesn't exist in the array, add it
      filteredSubreddits.append(subreddit)
    }
    
    // Update the Defaults value with the modified array
    Defaults[.filteredSubreddits] = filteredSubreddits
  }
  
  func saveCommentsCount(numComments: Int) async -> Void {
    let context = PersistenceController.shared.primaryBGContext
    let postID = self.id
    let didCreateSeenPost = await context.perform(schedule: .enqueued) {
      guard let result = Self.upsertSeenPost(postID: postID, in: context) else { return false }
      result.seenPost.numComments = Int32(numComments)
      try? context.save()
      return result.didCreate
    }
    
    DispatchQueue.main.async {
      withAnimation {
        if didCreateSeenPost {
          self.data?.winstonSeen = true
        }
        self.winstonData?.seenCommentsCount = numComments
      }
    }
  }
  
  func saveSeenComments(comments: ListingData<CommentData>?) async -> Void {
    let context = PersistenceController.shared.primaryBGContext
    let postID = self.id
    let newComments = self.getCommentIds(comments: comments)
    let finalSeen = await context.perform(schedule: .enqueued) {
      guard let seenPost = Self.fetchSeenPosts(for: [postID], in: context).first else { return nil as String? }
      let seenComments = Self.appendSeenCommentIDs(newComments, to: seenPost)
      try? context.save()
      return seenComments
    }
    
    if let finalSeen {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        withAnimation {
          self.winstonData?.seenComments = finalSeen
        }
      }
    }
  }
  
  func saveMoreComments(comments: [Comment]) async -> Void {
    let context = PersistenceController.shared.primaryBGContext
    let postID = self.id
    let newComments: [String] = comments.map { $0.data?.id ?? "" }
    let finalSeen = await context.perform(schedule: .enqueued) {
      guard let seenPost = Self.fetchSeenPosts(for: [postID], in: context).first else { return nil as String? }
      let seenComments = Self.appendSeenCommentIDs(newComments, to: seenPost)
      try? context.save()
      return seenComments
    }
    
    if let finalSeen {
      DispatchQueue.main.async {
        withAnimation {
          self.winstonData?.seenComments = finalSeen
        }
      }
    }
  }
  
  
  func getCommentIds(comments: ListingData<CommentData>?) -> Array<String> {
    var ids = Array<String>()
    
    if let children = comments?.children {
      for child in children {
        if (child.kind == "more") { continue }
        
        if let commentId = child.data?.id {
          ids.append(commentId)
        }
        
        if let replies = child.data?.replies  {
          switch replies {
          case .first(_):
            break
          case .second(let actualData):
            ids += getCommentIds(comments: actualData.data)
          }
        }
      }
    }
    
    return ids
  }
  
  func reply(_ text: String, updateComments: ((Comment) -> ())? = nil) async -> Bool {
    if let fullname = data?.name {
      let result = await RedditWire.shared.newReply(text, to: fullname)
      if result {
        let comment = await optimisticReplyComment(text)
        if let updateComments = updateComments {
          await MainActor.run {
            withAnimation {
              updateComments(comment)
            }
          }
        }
      }
      return result
    }
    return false
  }

  private func optimisticReplyComment(_ text: String) async -> Comment {
    let meData = await RedditWire.shared.me?.data
    let now = Double(Int(Date().timeIntervalSince1970))
    var newComment = CommentData(id: UUID().uuidString)
    newComment.subreddit_id = data?.subreddit_id
    newComment.subreddit = data?.subreddit
    newComment.likes = true
    newComment.saved = false
    newComment.archived = false
    newComment.count = 0
    newComment.author = meData?.name ?? ""
    newComment.created_utc = now
    newComment.send_replies = nil
    newComment.parent_id = data?.name
    newComment.score = nil
    newComment.author_fullname = "t2_\(meData?.id ?? "")"
    newComment.approved_by = nil
    newComment.mod_note = nil
    newComment.collapsed = false
    newComment.body = text
    newComment.top_awarded_type = nil
    newComment.name = nil
    newComment.is_submitter = true
    newComment.downs = 0
    newComment.children = nil
    newComment.body_html = nil
    newComment.permalink = nil
    newComment.created = now
    newComment.link_id = data?.name
    newComment.link_title = data?.title
    newComment.subreddit_name_prefixed = data?.subreddit_name_prefixed
    newComment.depth = 0
    newComment.author_flair_background_color = nil
    newComment.collapsed_because_crowd_control = nil
    newComment.mod_reports = nil
    newComment.num_reports = nil
    newComment.ups = 1
    return Comment(data: newComment)
  }
  
  func refreshPostResult(commentID: String? = nil, sort: CommentSortOption = .confidence, after: String? = nil, subreddit: String? = nil, full: Bool = true, subId: String? = nil) async -> PostRefreshResult {
    let refreshKey = [
      id,
      commentID ?? "root",
      sort.rawVal.value,
      full ? "full" : "partial"
    ].joined(separator: "|")

    return await PostRefreshCoordinator.shared.load(key: refreshKey) {
      await self.performRefreshPostResult(commentID: commentID, sort: sort, after: after, subreddit: subreddit, full: full, subId: subId)
    }
  }

  private func performRefreshPostResult(commentID: String? = nil, sort: CommentSortOption = .confidence, after: String? = nil, subreddit: String? = nil, full: Bool = true, subId: String? = nil) async -> PostRefreshResult {
    // Post + comment forest over GraphQL. The flat forest is assembled into
    // the reply tree by nestComments; continuation nodes surface as "more"
    // stubs. Comment-listing pagination doesn't exist on this surface, so the
    // returned cursor is always nil.
    let startedAt = Date()
    AppDiagnostics.asyncRecord(
      .info,
      category: "ui.commentTree",
      message: "Post.refreshPost started",
      metadata: refreshPostDiagnosticsMetadata(
        commentID: commentID,
        sort: sort,
        full: full,
        extra: ["phase": "start"]
      )
    )
    let fetchResult = await RedditWire.shared.postWithComments(postID: id, commentID: commentID, sort: sort)
    let newData: PostData?
    let children: [ListingChild<CommentData>]
    let terminalResult: PostRefreshResult?
    switch fetchResult {
    case .success(let postData, let fetchedChildren):
      newData = postData
      children = fetchedChildren
      terminalResult = nil
    case .empty(let postData):
      newData = postData
      children = []
      terminalResult = .empty
    case .transientEmpty(let postData, let message):
      newData = postData
      children = []
      terminalResult = .transientEmpty(message)
    case .failure(let message):
      AppDiagnostics.asyncRecord(
        .warning,
        category: "ui.commentTree",
        message: "Post.refreshPost failed",
        metadata: refreshPostDiagnosticsMetadata(
          commentID: commentID,
          sort: sort,
          full: full,
          extra: [
            "phase": "failed",
            "error": message,
            "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
          ]
        )
      )
      return .failed(message)
    }
    AppDiagnostics.asyncRecord(
      .info,
      category: "ui.commentTree",
      message: "Post.refreshPost GraphQL returned",
      metadata: refreshPostDiagnosticsMetadata(
        commentID: commentID,
        sort: sort,
        full: full,
        extra: [
          "phase": "graphql-returned",
          "hasPostData": "\(newData != nil)",
          "flatChildren": "\(children.count)",
          "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
        ]
      )
    )
    var postData = newData
    let postFullnameFromComment = newData?.name ?? (id.hasPrefix("\(Post.prefix)_") ? id : "\(Post.prefix)_\(id)")
    // The postComments query omits crosspostRoot/media. When we don't already
    // have a fully-hydrated post (deep-links, or any first load without feed
    // data), fetch the complete post via postsByIds so crossposts and their
    // media survive. Feed-navigated posts already carry it, so skip the extra call.
    if full, commentID != nil || self.data == nil {
      let hydrationStartedAt = Date()
      AppDiagnostics.asyncRecord(
        .info,
        category: "ui.postDetail",
        message: "Hydrating highlighted comment parent post",
        metadata: refreshPostDiagnosticsMetadata(
          commentID: commentID,
          sort: sort,
          full: full,
          extra: [
            "phase": "hydrate-parent-start",
            "postFullname": postFullnameFromComment,
            "hadCommentPostData": "\(newData != nil)",
            "commentPostDataMedia": Post.diagnosticsPostDataMedia(newData)
          ]
        )
      )
      if let hydratedData = await RedditWire.shared.postData(forID: postFullnameFromComment) {
        postData = hydratedData
        AppDiagnostics.asyncRecord(
          .info,
          category: "ui.postDetail",
          message: "Hydrated highlighted comment parent post",
          metadata: refreshPostDiagnosticsMetadata(
            commentID: commentID,
            sort: sort,
            full: full,
            extra: [
              "phase": "hydrate-parent-success",
              "postFullname": hydratedData.name,
              "hydratedPostID": hydratedData.id,
              "hydratedTitle": hydratedData.title,
              "hydratedMedia": Post.diagnosticsPostDataMedia(hydratedData),
              "elapsedMs": "\(Int(Date().timeIntervalSince(hydrationStartedAt) * 1000))"
            ]
          )
        )
      } else {
        AppDiagnostics.asyncRecord(
          .warning,
          category: "ui.postDetail",
          message: "Highlighted comment parent post hydration returned no post",
          metadata: refreshPostDiagnosticsMetadata(
            commentID: commentID,
            sort: sort,
            full: full,
            extra: [
              "phase": "hydrate-parent-empty",
              "postFullname": postFullnameFromComment,
              "elapsedMs": "\(Int(Date().timeIntervalSince(hydrationStartedAt) * 1000))"
            ]
          )
        )
      }
    }
    if full, let postData {
      // Don't clobber a good post with a degraded stub: the comments query can
      // return a placeholder post (author "[deleted]", score 0, epoch date) that
      // would flash garbage into a header that already shows real data.
      let incomingIsStub = postData.author.isEmpty || postData.author == "[deleted]"
      let haveRealData = (self.data?.author.isEmpty == false) && self.data?.author != "[deleted]"
      // The postComments query does NOT return crosspostRoot, so its post lacks
      // the crosspost source (and its media). Don't replace data that already has
      // the crosspost (from the feed / postsByIds hydration) with that lesser one.
      let existingHasCrosspost = !(self.data?.crosspost_parent_list?.isEmpty ?? true)
      let incomingHasCrosspost = !(postData.crosspost_parent_list?.isEmpty ?? true)
      let wouldLoseCrosspost = existingHasCrosspost && !incomingHasCrosspost
      let shouldReplace = (self.data == nil || commentID != nil || !incomingIsStub || !haveRealData) && !wouldLoseCrosspost
      await MainActor.run {
        if shouldReplace {
          self.data = postData
          setupWinstonData(data: postData, secondary: false, theme: getEnabledTheme())
        } else if self.winstonData == nil, let existing = self.data {
          setupWinstonData(data: existing, secondary: false, theme: getEnabledTheme())
        }
      }
    }
    let postFullname = postData?.name ?? postFullnameFromComment
    if case .transientEmpty(let message) = terminalResult {
      AppDiagnostics.asyncRecord(
        .warning,
        category: "ui.commentTree",
        message: "Post.refreshPost completed with transient empty comments",
        metadata: refreshPostDiagnosticsMetadata(
          commentID: commentID,
          sort: sort,
          full: full,
          extra: [
            "phase": "transient-empty",
            "postFullname": postFullname,
            "error": message,
            "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
          ]
        )
      )
      return .transientEmpty(message)
    }
    await saveSeenComments(comments: ListingData(after: nil, dist: nil, modhash: nil, geo_filter: nil, children: children))
    let comments = nestComments(children, parentID: postFullname)
    let missingBodies = comments.compactMap { comment -> String? in
      guard comment.data?.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return nil }
      return comment.data?.name ?? comment.id
    }
    AppDiagnostics.asyncRecord(
      missingBodies.isEmpty ? .info : .warning,
      category: "ui.comments",
      message: "Comment tree nested",
      metadata: [
        "postID": postFullname,
        "highlightID": commentID ?? "nil",
        "flatChildren": "\(children.count)",
        "rootComments": "\(comments.count)",
        "missingRootBodies": "\(missingBodies.count)",
        "missingRootBodyIDs": missingBodies.prefix(8).joined(separator: ",")
      ]
    )
    AppDiagnostics.asyncRecord(
      missingBodies.isEmpty ? .info : .warning,
      category: "ui.commentTree",
      message: "Post.refreshPost completed",
      metadata: refreshPostDiagnosticsMetadata(
        commentID: commentID,
        sort: sort,
        full: full,
        extra: [
          "phase": "complete",
          "postFullname": postFullname,
          "flatChildren": "\(children.count)",
          "rootComments": "\(comments.count)",
          "missingRootBodies": "\(missingBodies.count)",
          "missingRootBodyIDs": missingBodies.prefix(8).joined(separator: ","),
          "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
        ]
      )
    )
    if case .empty = terminalResult {
      return .empty
    }
    return .loaded(comments: comments, next: nil)
  }

  func refreshPost(commentID: String? = nil, sort: CommentSortOption = .confidence, after: String? = nil, subreddit: String? = nil, full: Bool = true, subId: String? = nil) async -> ([Comment]?, String?)? {
    switch await refreshPostResult(commentID: commentID, sort: sort, after: after, subreddit: subreddit, full: full, subId: subId) {
    case .loaded(let comments, let next):
      return (comments, next)
    case .empty:
      return ([], nil)
    case .transientEmpty, .failed:
      return nil
    }
  }

  func refreshPostDiagnosticsMetadata(commentID: String?, sort: CommentSortOption, full: Bool, extra: [String: String] = [:]) -> [String: String] {
    [
      "postID": id,
      "postFullname": data?.name ?? "nil",
      "title": data?.title ?? "nil",
      "commentID": commentID ?? "nil",
      "sort": sort.rawVal.value,
      "full": "\(full)"
    ].merging(extra) { _, new in new }
  }
  
  func saveToggle() async -> Bool {
    if let data = data {
      await markInteractedAsRead()
      let prev = data.saved
      await MainActor.run {
        withAnimation {
          self.data?.saved = !prev
        }
      }
      let success: Bool? = await RedditWire.shared.save(fullname: data.name, saved: !prev)
      if !(success ?? false) {
        await MainActor.run {
          withAnimation {
            self.data?.saved = prev
          }
        }
        return false
      }
      return true
    }
    return false
  }
  
  func vote(_ action: VoteAction) async -> Bool? {
    await markInteractedAsRead()
    let oldLikes = data?.likes
    let oldUps = data?.ups ?? 0
    var newAction = action
    newAction = action.boolVersion() == oldLikes ? .none : action
    await MainActor.run { [newAction] in
      withAnimation(.spring()) {
        data?.likes = newAction.boolVersion()
        data?.ups = oldUps + (action.boolVersion() == oldLikes ? oldLikes == nil ? 0 : -(Int(action.rawValue) ?? 0) : (Int(action.rawValue) ?? 1) * (oldLikes == nil ? 1 : 2))
      }
    }
    let fullname = "\(typePrefix ?? "")\(id)"
    let result: Bool? = await RedditWire.shared.vote(fullname: fullname, action: newAction)
    if result == nil || !result! {
      await MainActor.run {
        withAnimation(.spring()) {
          data?.likes = oldLikes
          data?.ups = oldUps
        }
      }
    }
    return result
  }

  func markInteractedAsRead() async {
    guard data?.winstonSeen != true else { return }
    await toggleSeen(true, optimistic: true)
  }
  
  func hide(_ hide: Bool) async -> () {
    if data?.winstonHidden == hide { return }
    await MainActor.run {
      withAnimation {
        data?.winstonHidden = hide
      }
    }
  }

  static func diagnosticsMediaKind(_ media: MediaExtractedType?) -> String {
    switch media {
    case .link:
      return "link"
    case .video(let sharedVideo):
      return "video(poster:\(sharedVideo.posterURL == nil ? "nil" : "set"),download:\(sharedVideo.downloadURL == nil ? "nil" : "set"))"
    case .imgs(let imgs):
      return "imgs(\(imgs.count))"
    case .yt:
      return "youtube"
    case .streamable:
      return "streamable"
    case .repost:
      return "repost"
    case .post:
      return "post"
    case .comment:
      return "comment"
    case .subreddit:
      return "subreddit"
    case .user:
      return "user"
    case nil:
      return "nil"
    }
  }

  static func diagnosticsPostDataMedia(_ data: PostData?) -> String {
    guard let data else { return "nil" }
    let previewCount = data.preview?.images?.count ?? 0
    let galleryCount = data.gallery_data?.items?.count ?? 0
    let metadataCount = data.media_metadata?.count ?? 0
    return [
      "hint:\(data.post_hint ?? "nil")",
      "preview:\(previewCount)",
      "gallery:\(galleryCount)",
      "metadata:\(metadataCount)",
      "isVideo:\(data.is_video == true)",
      "isGallery:\(data.is_gallery == true)",
      "hasMedia:\(data.media != nil)",
      "urlEmpty:\(data.url.isEmpty)"
    ].joined(separator: ",")
  }
}

enum PostWinstonDataMedia {
  case link(PreviewModel)
  case video(SharedVideo)
  case imgs([ImageRequest])
  case yt(YTMediaExtracted)
  case repost(Post)
  case post(id: String, subreddit: String)
  case comment(id: String, postID: String, subreddit: String)
  case subreddit(name: String)
  case user(username: String)
}

@MainActor
class PostWinstonData: Hashable, ObservableObject {
  nonisolated static func == (lhs: PostWinstonData, rhs: PostWinstonData) -> Bool { lhs === rhs }
  
  var permaURL: URL? = nil
  @Published var extractedMedia: MediaExtractedType? = nil
  @Published var extractedMediaForcedNormal: MediaExtractedType? = nil
  @Published var _strongSubreddit: Subreddit?
  weak var _weakSubreddit: Subreddit?
  var subreddit: Subreddit? {
    get { _weakSubreddit ?? _strongSubreddit }
    set { _weakSubreddit = newValue }
  }
  @Published var mediaImageRequest: [ImageRequest] = []
  @Published var avatarImageRequest: ImageRequest? = nil
  @Published var postDimensions: PostDimensions = .zero
  @Published var postDimensionsForcedNormal: PostDimensions = .zero
  @Published var titleAttr: NSAttributedString?
  @Published var linkMedia: PreviewModel?
  @Published var videoMedia: SharedVideo?
  @Published var postBodyAttr: NSAttributedString?
  @Published var media: PostWinstonDataMedia?
  @Published var seenCommentsCount: Int? = nil
  @Published var seenComments: String? = nil
  
  nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
}

struct PostData: GenericRedditEntityDataType {
  let subreddit: String
  var selftext: String
  var author_fullname: String? = nil
  var saved: Bool
  let gilded: Int
  let clicked: Bool
  let title: String
  let subreddit_name_prefixed: String
  let hidden: Bool
  var ups: Int
  var downs: Int
  let hide_score: Bool
  var post_hint: String? = nil
  let name: String
  let quarantine: Bool
  var link_flair_text_color: String? = nil
  let upvote_ratio: Double
  let subreddit_type: String
  let total_awards_received: Int
  let is_self: Bool
  let created: Double
  let domain: String
  let allow_live_comments: Bool
  var selftext_html: String? = nil
  let id: String
  let is_robot_indexable: Bool
  let author: String
  let num_comments: Int
  let send_replies: Bool
  var whitelist_status: String? = nil
  let contest_mode: Bool
  let permalink: String
  let url: String
  let subreddit_subscribers: Int
  var created_utc: Double? = nil
  let num_crossposts: Int
  var is_video: Bool? = nil
  var is_gallery: Bool? = nil
  var gallery_data: GalleryData? = nil
  var crosspost_parent_list: [PostData]? = nil
  var media_metadata: [String:MediaMetadataItem?]? = nil
  // Optional properties
  var wls: Int? = nil
  var pwls: Int? = nil
  var link_flair_text: String? = nil
  var thumbnail: String? = nil
  //  let edited: Edited?
  var link_flair_template_id: String? = nil
  var author_flair_text: String? = nil
  var media: Media? = nil
  var approved_at_utc: Int? = nil
  var mod_reason_title: String? = nil
  var top_awarded_type: String? = nil
  var author_flair_background_color: String? = nil
  var approved_by: String? = nil
  var is_created_from_ads_ui: Bool? = nil
  var author_premium: Bool? = nil
  var author_flair_css_class: String? = nil
  var gildings: [String: Int]? = nil
  var content_categories: [String]? = nil
  var mod_note: String? = nil
  var link_flair_type: String? = nil
  var removed_by_category: String? = nil
  var banned_by: String? = nil
  var author_flair_type: String? = nil
  var likes: Bool? = nil
  var stickied: Bool? = nil
  var suggested_sort: String? = nil
  var banned_at_utc: String? = nil
  var view_count: String? = nil
  var archived: Bool? = nil
  var no_follow: Bool? = nil
  var is_crosspostable: Bool? = nil
  var pinned: Bool? = nil
  var over_18: Bool? = nil
  //  let all_awardings: [Awarding]?
  var awarders: [String]? = nil
  var media_only: Bool? = nil
  var can_gild: Bool? = nil
  var spoiler: Bool? = nil
  var locked: Bool? = nil
  var treatment_tags: [String]? = nil
  var visited: Bool? = nil
  var removed_by: String? = nil
  var num_reports: Int? = nil
  var distinguished: String? = nil
  var subreddit_id: String? = nil
  var author_is_blocked: Bool? = nil
  var mod_reason_by: String? = nil
  var removal_reason: String? = nil
  var link_flair_background_color: String? = nil
  var report_reasons: [String]? = nil
  var discussion_type: String? = nil
  var secure_media: Media? = nil
  var secure_media_embed: SecureMediaEmbed? = nil
  var preview: Preview? = nil
  var winstonSeen: Bool? = nil
  var winstonHidden: Bool? = nil
  
  var badgeKit: BadgeKit {
    BadgeKit(
      numComments: num_comments,
      ups: ups,
      saved: saved,
      author: author,
      authorFullname: author_fullname ?? "",
      userFlair: author_flair_text ?? "",
      created: created
    )
  }
  
  var votesKit: VotesKit { VotesKit(ups: ups, ratio: upvote_ratio, likes: likes, id: id) }
}

struct GalleryData: Codable, Hashable {
  let items: [GalleryDataItem]?
}

struct GalleryDataItem: Codable, Hashable, Identifiable {
  let media_id: String
  let id: Double
}

struct MediaMetadataItem: Codable, Hashable, Identifiable {
  let status: String
  let e: String?
  let m: String?
  let p: [MediaMetadataItemSize]?
  let s: MediaMetadataItemSize?
  let id: String?
}

struct MediaMetadataItemSize: Codable, Hashable {
  let x: Int
  let y: Int
  let u: String?
}

struct PreviewImg: Codable, Hashable {
  let url: String?
  let width: Int?
  let height: Int?
  let id: String?
}

struct PreviewImgCollection: Codable, Hashable {
  let source: PreviewImg?
  let resolutions: [PreviewImg]?
  //  let variants: Oembed?
  let id: String?
}

struct RedditVideoPreview: Codable, Hashable {
  let bitrate_kbps: Double?
  let fallback_url: String?
  let height: Double?
  let width: Double?
  let scrubber_media_url: String?
  let dash_url: String?
  let duration: Double?
  let hls_url: String?
  let is_gif: Bool?
  let transcoding_status: String?
}

struct Preview: Codable, Hashable {
  let images: [PreviewImgCollection]?
  let reddit_video_preview: RedditVideoPreview?
  let enabled: Bool?
}

struct Media: Codable, Hashable {
  let type: String?
  let oembed: Oembed?
  let reddit_video: RedditVideo?
}

struct Oembed: Codable, Hashable {
  let provider_url: String?
  let version: String?
  let title: String?
  let type: String?
  let thumbnail_width: Int?
  let height: Int?
  let width: Int?
  let html: String?
  let author_name: String?
  let provider_name: String?
  let thumbnail_url: String?
  let thumbnail_height: Int?
  let author_url: String?
}

struct RedditVideo: Codable, Hashable {
  let bitrate_kbps: Int?
  let fallback_url: String?
  let has_audio: Bool?
  let height: Int?
  let width: Int?
  let scrubber_media_url: String?
  let dash_url: String?
  let duration: Int?
  let hls_url: String?
  let is_gif: Bool?
  let transcoding_status: String?
}

struct SecureMediaEmbed: Codable, Hashable {
  let content: String?
  let width: Int?
  let scrolling: Bool?
  let media_domain_url: String?
  let height: Int?
}

struct Awarding: Codable, Hashable {
  let id: String
  let name: String
  let description: String
  let coin_price: Int
  let coin_reward: Int
  let icon_url: String
  let is_enabled: Bool
  let count: Int
  
  // Optional properties
  let days_of_premium: Int?
  let award_sub_type: String?
  let days_of_drip_extension: Int?
  let icon_height: Int?
  let icon_width: Int?
  let is_new: Bool?
  let subreddit_coin_reward: Int?
  let tier_by_required_awardings: [String: Int]?
  let award_type: String?
  let awardings_required_to_grant_benefits: Int?
  let start_date: Double?
  let end_date: Double?
  let static_icon_height: Int?
  let static_icon_url: String?
  let static_icon_width: Int?
  let subreddit_id: String?
}

enum Edited: Codable {
  case bool(Bool)
  case double(Double)
  
  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let boolValue = try? container.decode(Bool.self) {
      self = .bool(boolValue)
    } else if let doubleValue = try? container.decode(Double.self) {
      self = .double(doubleValue)
    } else {
      throw DecodingError.typeMismatch(Edited.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected value of type Bool or Double"))
    }
  }
  
  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .bool(let boolValue):
      try container.encode(boolValue)
    case .double(let doubleValue):
      try container.encode(doubleValue)
    }
  }
}
