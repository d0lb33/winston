//
//  PostReplies.swift
//  winston
//
//  Created by Igor Marcossi on 31/07/23.
//

import SwiftUI
import Defaults

struct PostReplies: View {
  var update: Bool
  @ObservedObject var post: Post
  @ObservedObject var subreddit: Subreddit
  var ignoreSpecificComment: Bool
  var highlightID: String?
  var sort: CommentSortOption
  var proxy: ScrollViewProxy
  var geometryReader: GeometryProxy
  @Environment(\.useTheme) private var selectedTheme

  @State private var loading = true
  @State var seenComments : String?

  // MARK: Properties related to comment skipper
  @Binding var topVisibleCommentId: String?
  @Binding var previousScrollTarget: String?
  @ObservedObject var comments: ObservableArray<Comment>

  @Environment(\.globalLoaderDismiss) private var globalLoaderDismiss

  func asyncFetch(_ full: Bool, _ altIgnoreSpecificComment: Bool? = nil) async {
    let startedAt = Date()
    let effectiveIgnoreSpecificComment = altIgnoreSpecificComment ?? ignoreSpecificComment
    AppDiagnostics.asyncRecord(
      .info,
      category: "ui.commentTree",
      message: "PostReplies fetch started",
      metadata: commentTreeMetadata(
        full: full,
        ignoreSpecificComment: effectiveIgnoreSpecificComment,
        extra: ["phase": "start"]
      )
    )
    if let result = await post.refreshPost(commentID: (altIgnoreSpecificComment ?? ignoreSpecificComment) ? nil : highlightID, sort: sort, after: nil, subreddit: subreddit.data?.display_name ?? subreddit.id, full: full), let newComments = result.0 {
      AppDiagnostics.asyncRecord(
        .info,
        category: "ui.commentTree",
        message: "PostReplies fetch completed",
        metadata: commentTreeMetadata(
          full: full,
          ignoreSpecificComment: effectiveIgnoreSpecificComment,
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
      await MainActor.run {
        withAnimation {
          comments.data = newComments
          loading = false
        }

        if var specificID = highlightID {
          specificID = specificID.hasPrefix("t1_") ? String(specificID.dropFirst(3)) : specificID
          AppDiagnostics.asyncRecord(
            .debug,
            category: "ui.commentTree",
            message: "PostReplies scheduling highlight scroll",
            metadata: commentTreeMetadata(
              full: full,
              ignoreSpecificComment: effectiveIgnoreSpecificComment,
              extra: ["specificID": specificID]
            )
          )
          doThisAfter(0.1) {
            withAnimation(spring) {
              proxy.scrollTo("\(specificID)-body", anchor: .center)
            }
          }
        }
      }
    } else {
      await MainActor.run {
        withAnimation {
          loading = false
        }
      }
      AppDiagnostics.asyncRecord(
        .warning,
        category: "ui.commentTree",
        message: "PostReplies fetch returned no comments",
        metadata: commentTreeMetadata(
          full: full,
          ignoreSpecificComment: effectiveIgnoreSpecificComment,
          extra: [
            "phase": "empty",
            "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
          ]
        )
      )
    }
  }

  func commentTreeMetadata(full: Bool, ignoreSpecificComment: Bool, extra: [String: String] = [:]) -> [String: String] {
    [
      "postID": post.id,
      "postFullname": post.data?.name ?? "nil",
      "subreddit": subreddit.data?.display_name ?? subreddit.id,
      "full": "\(full)",
      "highlightID": highlightID ?? "nil",
      "ignoreSpecificComment": "\(ignoreSpecificComment)",
      "sort": sort.rawVal.value,
      "currentRootComments": "\(comments.data.count)",
      "loading": "\(loading)"
    ].merging(extra) { _, new in new }
  }

  var body: some View {
    let theme = selectedTheme.comments
    let horPad = theme.theme.outerHPadding
    Group {
      let postFullname = post.data?.name ?? ""
      Group {
        ForEach(Array(comments.data.enumerated()), id: \.element.id) { i, comment in
          Section {
            VStack(spacing: 0) {
              Color.clear
                .frame(maxWidth: .infinity, minHeight: theme.spacing / 2, maxHeight: theme.spacing / 2)
                .id("\(comment.id)-top-spacer")

              Color.clear
                .frame(maxWidth: .infinity, minHeight: theme.theme.cornerRadius * 2, maxHeight: theme.theme.cornerRadius * 2, alignment: .top)
                .background(CommentBG(cornerRadius: theme.theme.cornerRadius, pos: .top).fill(theme.theme.bg()))
                .frame(maxWidth: .infinity, minHeight: theme.theme.cornerRadius, maxHeight: theme.theme.cornerRadius, alignment: .top)
                .clipped()
                .id("\(comment.id)-top-decoration")

              if let commentWinstonData = comment.winstonData {
                CommentLink(highlightID: ignoreSpecificComment ? nil : highlightID, post: post, subreddit: subreddit, postFullname: postFullname, seenComments: seenComments, parentElement: .post(comments), comment: comment, commentWinstonData: commentWinstonData, children: comment.childrenWinston)
                  .if(comments.data.firstIndex(of: comment) != nil) { view in
                    view.anchorPreference(
                      key: CommentUtils.AnchorsKey.self,
                      value: .center
                    ) { [comment.id: $0] }
                  }
              }

              Color.clear
                .frame(maxWidth: .infinity, minHeight: theme.theme.cornerRadius * 2, maxHeight: theme.theme.cornerRadius * 2, alignment: .top)
                .background(CommentBG(cornerRadius: theme.theme.cornerRadius, pos: .bottom).fill(theme.theme.bg()))
                .frame(maxWidth: .infinity, minHeight: theme.theme.cornerRadius, maxHeight: theme.theme.cornerRadius, alignment: .bottom)
                .clipped()
                .id("\(comment.id)-bot-decoration")

              Color.clear
                .frame(maxWidth: .infinity, minHeight: theme.spacing / 2, maxHeight: theme.spacing / 2)
                .id("\(comment.id)-bot-spacer")

              if comments.data.count - 1 != i {
                NiceDivider(divider: theme.divider)
                  .id("\(comment.id)-bot-divider")
              }
            }
          }
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets(top: 0, leading: horPad, bottom: 0, trailing: horPad))
        }
        Section {
          Spacer()
            .frame(height: 1)
            .listRowBackground(Color.clear)
            .onChange(of: update) { _ in
              AppDiagnostics.asyncRecord(
                .debug,
                category: "ui.commentTree",
                message: "PostReplies update token changed",
                metadata: commentTreeMetadata(full: true, ignoreSpecificComment: ignoreSpecificComment)
              )
              Task(priority: .background) {
                await asyncFetch(true)
              }
            }
            .onChange(of: ignoreSpecificComment) { val in
              AppDiagnostics.asyncRecord(
                .info,
                category: "ui.commentTree",
                message: "PostReplies ignoreSpecificComment changed",
                metadata: commentTreeMetadata(full: post.data == nil, ignoreSpecificComment: val)
              )
              Task(priority: .background) {
                await asyncFetch(post.data == nil, val)
                globalLoaderDismiss()
              }
              if val {
                withAnimation(spring) {
                  proxy.scrollTo("post-content", anchor: .bottom)
                }
              }
            }
            .id("on-change-spacer")
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
      }

      if loading {
        ProgressView()
          .progressViewStyle(.circular)
          .frame(maxWidth: .infinity, minHeight: 100 )
          .listRowBackground(Color.clear)
          .onAppear {
            AppDiagnostics.asyncRecord(
              .debug,
              category: "ui.commentTree",
              message: "PostReplies loading indicator appeared",
              metadata: commentTreeMetadata(full: post.data == nil, ignoreSpecificComment: ignoreSpecificComment)
            )
            if comments.data.count == 0 || post.data == nil {
              Task(priority: .background) {
                await asyncFetch(post.data == nil)
              }
            }
            withAnimation { seenComments = post.winstonData?.seenComments }
          }
          .id("loading-comments")
      } else if comments.data.count == 0 {
        Text(QuirkyMessageUtil.noCommentsFoundMessage())
          .frame(maxWidth: .infinity, minHeight: 300)
          .opacity(0.25)
          .listRowBackground(Color.clear)
          .id("no-comments-placeholder")
      }
    }
  }
}
