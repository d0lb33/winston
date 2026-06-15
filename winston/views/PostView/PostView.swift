//
//  Post.swift
//  winston
//
//  Created by Igor Marcossi on 28/06/23.
//

import SwiftUI
import Defaults
import AVFoundation
import AlertToast

struct PostView: View, Equatable {
  static func == (lhs: PostView, rhs: PostView) -> Bool {
    lhs.post == rhs.post && lhs.subreddit.id == rhs.subreddit.id && lhs.hideElements == rhs.hideElements && lhs.ignoreSpecificComment == rhs.ignoreSpecificComment && lhs.sort == rhs.sort
  }
  
  @ObservedObject var post: Post
  var subreddit: Subreddit
  var forceCollapse: Bool
  var highlightID: String?
  @Default(.PostPageDefSettings) private var defSettings
  @Default(.CommentsSectionDefSettings) var commentsSectionDefSettings
  @Environment(\.useTheme) private var selectedTheme
  @Environment(\.globalLoaderStart) private var globalLoaderStart
  @Environment(\.globalLoaderDismiss) private var globalLoaderDismiss
  @State private var ignoreSpecificComment = false
  @State private var hideElements = true
  @State private var sort: CommentSortOption
  @State private var isFetching = false
  @State private var loadingComments = true
  @State private var commentLoadError: String? = nil
  
  @State private var topVisibleCommentId: String? = nil
  @State private var previousScrollTarget: String? = nil
  @StateObject private var comments = ObservableArray<Comment>()

  init(post: Post, subreddit: Subreddit, forceCollapse: Bool = false, highlightID: String? = nil) {
    self.post = post
    self.subreddit = subreddit
    self.forceCollapse = forceCollapse
    self.highlightID = highlightID
    
    let defSettings = Defaults[.PostPageDefSettings]
    let commentsDefSettings = Defaults[.CommentsSectionDefSettings]
    
    _sort = State(initialValue: defSettings.perPostSort ? (defSettings.postSorts[post.id] ?? commentsDefSettings.preferredSort) : commentsDefSettings.preferredSort);
  }
  
  @MainActor
  func asyncFetch(_ full: Bool = true, proxy: ScrollViewProxy? = nil) async {
    guard !isFetching else {
      AppDiagnostics.asyncRecord(
        .debug,
        category: "ui.postDetail",
        message: "PostView fetch skipped while already loading",
        metadata: postDetailMetadata(full: full, extra: ["phase": "deduped"])
      )
      return
    }
    isFetching = true
    defer { isFetching = false }

    let startedAt = Date()
    AppDiagnostics.asyncRecord(
      .info,
      category: "ui.postDetail",
      message: "PostView fetch started",
      metadata: postDetailMetadata(full: full, extra: ["phase": "start"])
    )
    if comments.data.isEmpty {
      loadingComments = true
    }
    commentLoadError = nil

    switch await post.refreshPostResult(commentID: ignoreSpecificComment ? nil : highlightID, sort: sort, after: nil, subreddit: subreddit.data?.display_name ?? subreddit.id, full: full) {
    case .loaded(let newComments, _):
      AppDiagnostics.asyncRecord(
        .info,
        category: "ui.postDetail",
        message: "PostView fetch completed",
        metadata: postDetailMetadata(
          full: full,
          extra: [
            "phase": "success",
            "rootComments": "\(newComments.count)",
            "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
          ]
        )
      )
      Task(priority: .background) {
        await RedditWire.shared.updateCommentsWithAvatar(comments: newComments, avatarSize: selectedTheme.comments.theme.badge.avatar.size)
      }

      newComments.forEach { $0.parentWinston = comments }
      withAnimation {
        comments.data = newComments
        loadingComments = false
      }

      Task(priority: .background) {
        if let numComments = post.data?.num_comments {
          await post.saveCommentsCount(numComments: numComments)
        }
      }

      if let proxy, !ignoreSpecificComment, var specificID = highlightID {
        specificID = specificID.hasPrefix("t1_") ? String(specificID.dropFirst(3)) : specificID
        AppDiagnostics.asyncRecord(
          .debug,
          category: "ui.postDetail",
          message: "PostView scheduling highlight scroll",
          metadata: postDetailMetadata(full: full, extra: ["specificID": specificID])
        )
        // The replies section stays hidden for the first 0.5s (hideElements);
        // wait it out so the target row exists before scrolling to it.
        doThisAfter(hideElements ? 0.75 : 0.1) {
          withAnimation(spring) {
            proxy.scrollTo("\(specificID)-body", anchor: .center)
          }
        }
      }
    case .empty:
      withAnimation {
        comments.data = []
        loadingComments = false
      }
    case .transientEmpty(let message), .failed(let message):
      withAnimation {
        commentLoadError = "Pull to refresh and try loading comments again."
        loadingComments = false
      }
      AppDiagnostics.asyncRecord(
        .warning,
        category: "ui.postDetail",
        message: "PostView fetch did not load comments",
        metadata: postDetailMetadata(
          full: full,
          extra: [
            "phase": "failed",
            "error": message,
            "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
          ]
        )
      )
    }
  }

  func postDetailMetadata(full: Bool, extra: [String: String] = [:]) -> [String: String] {
    [
      "postID": post.id,
      "postFullname": post.data?.name ?? "nil",
      "title": post.data?.title ?? "nil",
      "subreddit": subreddit.data?.display_name ?? subreddit.id,
      "full": "\(full)",
      "highlightID": highlightID ?? "nil",
      "ignoreSpecificComment": "\(ignoreSpecificComment)",
      "sort": sort.rawVal.value
    ].merging(extra) { _, new in new }
  }
  
  func updatePost(proxy: ScrollViewProxy? = nil) {
    Task { await asyncFetch(true, proxy: proxy) }
  }

  func ensurePostPresentationData() {
    if let data = post.data, post.winstonData == nil || post.winstonData?.titleAttr == nil {
      post.setupWinstonData(data: data, theme: selectedTheme, sub: subreddit)
    }
  }
  
  var body: some View {
    #if DEBUG
    let _ = RenderDiagnostics.logIfEnabled { Self._printChanges() }
    #endif
    let navtitle: String = post.data?.title.escape ?? "no title"
    let subnavtitle: String = "r/\(post.data?.subreddit ?? "no sub") \u{2022} " + String(localized:"\(post.data?.num_comments ?? 0) comments")
    let commentsHPad = selectedTheme.comments.theme.outerHPadding > 0 ? selectedTheme.comments.theme.outerHPadding : selectedTheme.comments.theme.innerPadding.horizontal
    GeometryReader { geometryReader in
      ScrollViewReader { proxy in
        List {
          Group {
            Section {
              if let winstonData = post.winstonData {
                PostContent(post: post, winstonData: winstonData, sub: subreddit, forceCollapse: forceCollapse)
              }
              //              .equatable()
              
              if selectedTheme.posts.inlineFloatingPill {
                PostFloatingPill(post: post, subreddit: subreddit, updateComments: appendReplyComment, showUpVoteRatio: defSettings.showUpVoteRatio)
                  .padding(-10)
              }
              
              Text("Comments")
                .fontSize(20, .bold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id("comments-header")
                .listRowInsets(EdgeInsets(top: selectedTheme.posts.commentsDistance / 2, leading:commentsHPad, bottom: 8, trailing: commentsHPad))
            }
            .listRowBackground(Color.clear)
            
            if !hideElements {
              PostReplies(loading: loadingComments, errorMessage: commentLoadError, post: post, subreddit: subreddit, ignoreSpecificComment: ignoreSpecificComment, highlightID: highlightID, sort: sort, fetch: { full in await asyncFetch(full, proxy: proxy) }, comments: comments)
            }
            
            if !ignoreSpecificComment && highlightID != nil {
              Section {
                Button {
                  globalLoaderStart("Loading full post...")
                  withAnimation {
                    ignoreSpecificComment = true
                  }
                } label: {
                  HStack {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                    Text("View full conversation")
                  }
                }
              }
              .listRowBackground(Color.primary.opacity(0.1))
            }
            
            Section {
              Spacer()
                .frame(maxWidth: .infinity, minHeight: 72)
                .listRowBackground(Color.clear)
                .id("end-spacer")
            }
          }
          .listRowSeparator(.hidden)
        }
        .scrollIndicators(.never)
        .themedListBG(selectedTheme.posts.bg)
        .transition(.opacity)
        .environment(\.defaultMinListRowHeight, 1)
        .listStyle(.plain)
        .refreshable {
          await asyncFetch(true)
        }
        .overlay(alignment: .bottomTrailing) {
          if !selectedTheme.posts.inlineFloatingPill {
            PostFloatingPill(post: post, subreddit: subreddit, updateComments: appendReplyComment, showUpVoteRatio: defSettings.showUpVoteRatio)
          }
        }
        .navigationBarTitle("\(navtitle)", displayMode: .inline)
        .toolbar { Toolbar(title: navtitle, subtitle: subnavtitle, hideElements: hideElements, subreddit: subreddit, post: post, sort: $sort) }
        .onChange(of: sort) { val in
          AppDiagnostics.asyncRecord(
            .info,
            category: "ui.postDetail",
            message: "PostView sort changed",
            metadata: postDetailMetadata(full: true, extra: ["newSort": val.rawVal.value])
          )
          updatePost()
        }
        .onChange(of: ignoreSpecificComment) { val in
          AppDiagnostics.asyncRecord(
            .info,
            category: "ui.postDetail",
            message: "PostView ignoreSpecificComment changed",
            metadata: postDetailMetadata(full: post.data == nil, extra: ["newValue": "\(val)"])
          )
          Task {
            await asyncFetch(post.data == nil)
            globalLoaderDismiss()
          }
          if val {
            withAnimation(spring) {
              proxy.scrollTo("post-content", anchor: .bottom)
            }
          }
        }
        .onAppear {
          ensurePostPresentationData()
          AppDiagnostics.asyncRecord(
            .debug,
            category: "ui.postDetail",
            message: "PostView appeared",
            metadata: postDetailMetadata(full: post.data == nil, extra: ["forceCollapse": "\(forceCollapse)", "hideElements": "\(hideElements)"])
          )
          doThisAfter(0.5) {
            hideElements = false
            AppDiagnostics.asyncRecord(
              .debug,
              category: "ui.postDetail",
              message: "PostView revealed comments section",
              metadata: postDetailMetadata(full: post.data == nil, extra: ["hideElements": "\(hideElements)"])
            )
            doThisAfter(0.1) {
              if highlightID != nil { withAnimation { proxy.scrollTo("loading-comments") } }
            }
          }
          if comments.data.count == 0 || post.data == nil {
            Task { await asyncFetch(post.data == nil, proxy: proxy) }
          }


          Task(priority: .background) {
            if let numComments = post.data?.num_comments {
              await post.saveCommentsCount(numComments: numComments)
            }
          }
          
          Task(priority: .background) {
            if subreddit.data == nil && subreddit.id != "home" {
              await subreddit.refreshSubreddit()
            }
          }
        }
        .onPreferenceChange(CommentUtils.AnchorsKey.self) { anchors in
          DispatchQueue.main.async {
            topVisibleCommentId = CommentUtils.shared.topCommentRow(of: anchors, in: geometryReader)
          }
        }
        .commentSkipper(showJumpToNextCommentButton: $commentsSectionDefSettings.commentSkipper,
                        topVisibleCommentId: $topVisibleCommentId,
                        previousScrollTarget: $previousScrollTarget,
                        comments: comments,
                        reader: proxy)
      }
    }
  }

  private func appendReplyComment(_ comment: Comment) {
    guard !comments.data.contains(where: { $0.id == comment.id }) else { return }
    comment.parentWinston = comments
    withAnimation {
      comments.data.append(comment)
      loadingComments = false
    }
  }
}

private struct Toolbar: ToolbarContent {
  var title: String
  var subtitle: String
  var hideElements: Bool
  var subreddit: Subreddit
  var post: Post
  @Binding var sort: CommentSortOption
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin

  var body: some ToolbarContent {
    if !IPAD {
      ToolbarItem(id: "postview-title", placement: .principal) {
        VStack {
          Text(title)
            .font(.headline)
          Text(subtitle)
            .font(.subheadline)
        }
      }
    }

    ToolbarItem(id: "postview-sortandsub", placement: .navigationBarTrailing) {
      HStack {
        CommentSortMenu(selection: $sort, isEnabled: !hideElements, accented: true) { option in
          Defaults[.PostPageDefSettings].postSorts[post.id] = option
        }

        if let data = subreddit.data, !feedsAndSuch.contains(subreddit.id) {
          SubredditIcon(subredditIconKit: data.subredditIconKit)
            .onTapGesture {
              navigateRedditDestination(.reddit(.subInfo(subreddit)), model: redditNavigationModel, origin: redditNavigationOrigin)
            }
        }
      }
      .animation(nil, value: sort)
    }
  }
}
