//
//  PostReplies.swift
//  winston
//
//  Created by Igor Marcossi on 31/07/23.
//

import SwiftUI
import Defaults

struct PostReplies: View {
  var loading: Bool
  var errorMessage: String?
  @ObservedObject var post: Post
  @ObservedObject var subreddit: Subreddit
  var ignoreSpecificComment: Bool
  var highlightID: String?
  var sort: CommentSortOption
  /// Fetch is owned by PostView (deduplicated there); this view only requests it.
  var fetch: (_ full: Bool) async -> Void
  @Environment(\.useTheme) private var selectedTheme

  @State private var seenComments : String?

  @ObservedObject var comments: ObservableArray<Comment>

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
    #if DEBUG
    let _ = RenderDiagnostics.logIfEnabled { Self._printChanges() }
    #endif
    let theme = selectedTheme.comments
    let horPad = theme.theme.outerHPadding
    Group {
      let postFullname = post.data?.name ?? ""
      Group {
        ForEach(Array(comments.data.enumerated()), id: \.element.id) { i, comment in
          // Each element below is its own List row: CommentLink's recursion flattens
          // into one row per comment, so large threads stay virtualized. The rounded
          // card look comes from the cap rows + per-row backgrounds in the rows
          // themselves (CommentLinkContent/CommentLinkMore).
          Section {
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
                .anchorPreference(
                  key: CommentUtils.AnchorsKey.self,
                  value: .center
                ) { [comment.id: $0] }
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
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets(top: 0, leading: horPad, bottom: 0, trailing: horPad))
        }
        Section {
          Spacer()
            .frame(height: 1)
            .listRowBackground(Color.clear)
            .onAppear {
              withAnimation { seenComments = post.winstonData?.seenComments }
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
            // Safety net: PostView.onAppear normally starts the fetch; this only
            // fires if the replies section appears with nothing loaded.
            if comments.data.count == 0 || post.data == nil {
              Task {
                await fetch(post.data == nil)
              }
            }
          }
          .id("loading-comments")
      } else if let errorMessage, comments.data.count == 0 {
        ContentUnavailableView(
          "Couldn't Load Comments",
          systemImage: "exclamationmark.bubble",
          description: Text(errorMessage)
        )
        .frame(maxWidth: .infinity, minHeight: 300)
        .listRowBackground(Color.clear)
        .id("comments-load-error")
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
